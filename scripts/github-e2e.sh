#!/bin/sh
# GitHub per person (card E51E8B8C, ADR 0042 addendum): native backend with an empty SQLite database and the operator's app,
# scripts/fake-github-hub.py as GitHub over real bare git repositories. Nothing leaves the machine.
#   scripts/github-e2e.sh api [scratch-dir]   REST: two people connect, map and (with Docker and rclone) open pull requests from
#                                             a real SFTP server. Without Docker the pull request part is left out (CI).
#   scripts/github-e2e.sh pwa [scratch-dir]   Browser: web/e2e/github-connect.spec.ts (Chromium, Vite dev server); E2E_SHOTS = folder
#                                             for the light/dark screenshots.
# E2E_NATIVE  App binary (default .build/debug/App)   E2E_PORT  PWA/RP port (default 25187)   BACKEND_PORT (28987)
# E2E_GITHUB_PORT (28988)   E2E_SFTP_PORT (24877; own container todo-github-e2e-sftp-<pid>, removed afterwards)   E2E_NO_SFTP=1
set -eu
cd "$(dirname "$0")/.."
mode="${1:-api}"
scratch="${2:-${TMPDIR:-/tmp}/github-e2e-$mode}"
native="${E2E_NATIVE:-.build/debug/App}"
port="${E2E_PORT:-25187}"
backend_port="${BACKEND_PORT:-28987}"
github_port="${E2E_GITHUB_PORT:-28988}"
sftp_port="${E2E_SFTP_PORT:-24877}"
container="todo-github-e2e-sftp-$$"
case "$mode" in api) origin="http://localhost:$backend_port" ;; pwa) origin="http://localhost:$port" ;; *) echo "usage: $0 api|pwa [scratch]" >&2; exit 2 ;; esac
export RP_ID=localhost RP_ORIGIN="$origin" BOOTSTRAP_TOKEN=dev-bootstrap-only DEPLOY_ALLOW_PRIVATE_HOSTS=1
SETTINGS_ENCRYPTION_KEY="$(openssl rand -base64 32)"; export SETTINGS_ENCRYPTION_KEY
cleanup() {
  [ -n "${backend_pid:-}" ] && kill "$backend_pid" 2>/dev/null || true
  [ -n "${github_pid:-}" ] && kill "$github_pid" 2>/dev/null || true
  [ -n "${sftp_started:-}" ] && docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM
rm -rf "$scratch"; mkdir -p "$scratch"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/e2e.sqlite"

openssl genrsa -out "$scratch/app.pem" 2048 2>/dev/null
openssl rsa -in "$scratch/app.pem" -pubout -out "$scratch/app.pub" 2>/dev/null
for r in alice bob; do git init -q --bare -b main "$scratch/$r.git"; done
client_secret="cs-E2E-$(openssl rand -hex 16)"
python3 - "$scratch" "$origin" "http://127.0.0.1:$github_port" "$client_secret" <<'EOF'
import json, os, sys
scratch, origin, github, secret = sys.argv[1:5]
repo = lambda i, name, perms: {"id": i, "private": True, "bare": os.path.join(scratch, name + ".git"), "permissions": perms}
json.dump({"appID": "424242", "slug": "todolino-e2e", "clientID": "Iv23liE2ECLIENT", "clientSecret": secret, "githubURL": github,
           "publicKey": os.path.join(scratch, "app.pub"), "callback": origin + "/github/callback",
           "users": {"alice": 1001, "bob": 1002},
           "installations": {"111": {"account": "alice", "accountID": 1001, "type": "User", "repositories": ["alice/site"]},
                             "222": {"account": "bob", "accountID": 1002, "type": "User", "repositories": ["bob/site"]}},
           "repositories": {"alice/site": repo(5001, "alice", {"alice": "admin"}), "bob/site": repo(5003, "bob", {"bob": "admin"})}},
          open(os.path.join(scratch, "config.json"), "w"))
EOF
# Repositories need a first commit for the browser run too (the REST run pushes its own on top of an empty repository).
if [ "$mode" = pwa ]; then
  for r in alice bob; do
    git init -q -b main "$scratch/seed-$r" && echo hi >"$scratch/seed-$r/index.php"
    git -C "$scratch/seed-$r" add -A && git -C "$scratch/seed-$r" -c user.name=E2E -c user.email=e2e@example.invalid commit -q -m seed
    git -C "$scratch/seed-$r" push -q "$scratch/$r.git" main
  done
fi
python3 scripts/fake-github-hub.py "$github_port" "$scratch/config.json" "$scratch/github-journal.jsonl" >>"$scratch/github.log" 2>&1 & github_pid=$!

export GITHUB_APP_ID=424242 GITHUB_APP_PRIVATE_KEY_FILE="$scratch/app.pem" GITHUB_APP_SLUG=todolino-e2e
export GITHUB_APP_CLIENT_ID=Iv23liE2ECLIENT GITHUB_APP_CLIENT_SECRET="$client_secret"
export GITHUB_API_URL="http://127.0.0.1:$github_port" GITHUB_WEB_URL="http://127.0.0.1:$github_port"

"$native" migrate --yes >/dev/null
"$native" serve --hostname 127.0.0.1 --port "$backend_port" >>"$scratch/backend.log" 2>&1 & backend_pid=$!
ready=0
for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$backend_port/health/ready" >/dev/null 2>&1 && { ready=1; break; }; sleep 1; done
[ "$ready" = 1 ] || { echo "FAIL backend not ready"; cat "$scratch/backend.log"; exit 1; }

status=0
if [ "$mode" = api ]; then
  if [ -z "${E2E_NO_SFTP:-}" ] && command -v docker >/dev/null 2>&1 && command -v rclone >/dev/null 2>&1; then
    docker run -d --name "$container" -p "127.0.0.1:$sftp_port:22" atmoz/sftp:alpine \
      "alice:sftp-Geheim-41d9:1001::site" "bob:sftp-Geheim-41d9:1002::site" >/dev/null
    sftp_started=1
    # OpenSSH 10 penalises a source after connections without a login (ssh-keyscan): off in this throwaway server.
    for _ in $(seq 1 30); do docker exec "$container" test -d /home/bob/site 2>/dev/null && break; sleep 1; done
    docker exec "$container" sh -c 'echo "PerSourcePenalties no" >> /etc/ssh/sshd_config && kill -HUP 1'
    sleep 1
    ready=0
    for _ in $(seq 1 30); do ssh-keyscan -T 2 -p "$sftp_port" 127.0.0.1 2>/dev/null | grep -q ssh- && { ready=1; break; }; sleep 1; done
    [ "$ready" = 1 ] || { echo "FAIL SFTP server not ready"; exit 1; }
    docker exec "$container" sh -c 'for u in alice:1001 bob:1002; do S=/home/${u%:*}/site; mkdir -p $S/css; printf "hi\n" > $S/index.php;
      printf "a{}\nb{}\n" > $S/css/app.css; printf "alt\n" > $S/about.php; chown -R ${u#*:} $S; done'
    export E2E_SFTP_PORT="$sftp_port" E2E_SFTP_CONTAINER="$container"
  else
    unset E2E_SFTP_PORT
  fi
  python3 scripts/github-connect-e2e.py "$origin" "$scratch" || status=$?
else
  (cd web && E2E_PORT="$port" BACKEND_URL="http://127.0.0.1:$backend_port" E2E_GITHUB_URL="http://127.0.0.1:$github_port" \
    npx playwright test e2e/github-connect.spec.ts --project=chromium --reporter=line) || status=$?
  if grep -q -e "$client_secret" -e 'ghs_E2E' -e 'ghu_E2E' -e 'PRIVATE KEY' "$scratch/backend.log"; then echo "FAIL secret in backend log"; status=1; else echo "ok   no secret in backend log"; fi
fi
[ "$status" = 0 ] || tail -40 "$scratch/backend.log"
exit "$status"
