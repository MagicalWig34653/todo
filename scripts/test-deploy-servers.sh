#!/bin/bash
# Deploy targets against real servers (card 354ADE12, ADR 0039): starts atmoz/sftp and the own pure-ftpd test image on own ports,
# fills both with the same small site, then runs the Swift deploy tests with TODO_TEST_DEPLOY_SERVERS=1. Containers are removed
# afterwards (KEEP=1 keeps them). Needs docker, rclone and ssh-keyscan (OpenSSH) on the machine running the tests.
#
#   scripts/test-deploy-servers.sh                  # swift test --filter Deploy
#   scripts/test-deploy-servers.sh --filter X       # other swift test arguments
#   scripts/test-deploy-servers.sh --exec CMD ...   # any command with the servers running (scripts/deploy-e2e.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
SFTP_PORT="${TODO_TEST_DEPLOY_SFTP_PORT:-24822}"
FTP_PORT="${TODO_TEST_DEPLOY_FTP_PORT:-24821}"
PASV="${TODO_TEST_DEPLOY_PASV:-30000}"
SFTP=todo-deploy-test-sftp
FTP=todo-deploy-test-ftp
DIR="$(mktemp -d "${TMPDIR:-/tmp}/todo-deploy-test.XXXXXX")"
SWIFT="${SWIFT:-swift}"  # may be a command with arguments, e.g. "sparsam swift"

cleanup() {
  if [ "${KEEP:-0}" != 1 ]; then docker rm -f "$SFTP" "$FTP" >/dev/null 2>&1 || true; fi
  rm -rf "$DIR"
}
trap cleanup EXIT

command -v rclone >/dev/null || { echo "rclone fehlt (brew install rclone / apt-get install rclone)" >&2; exit 2; }
command -v ssh-keyscan >/dev/null || { echo "ssh-keyscan fehlt (openssh-client)" >&2; exit 2; }

docker rm -f "$SFTP" "$FTP" >/dev/null 2>&1 || true
docker build -q -t todo-deploy-pureftpd:test scripts/deploy-test-servers/pure-ftpd >/dev/null
docker run -d --name "$SFTP" -p "127.0.0.1:$SFTP_PORT:22" atmoz/sftp:alpine "deploy:sftp-Geheim-41d9:1001::site" >/dev/null
PASV_END=$((PASV + 9))
docker run -d --name "$FTP" --cap-add SYS_NICE --cap-add DAC_READ_SEARCH --cap-add SYS_RESOURCE \
  -p "127.0.0.1:$FTP_PORT:21" -p "127.0.0.1:$PASV-$PASV_END:30000-30009" \
  -e FTP_USER=deploy -e FTP_PASS=ftp-Geheim-83c2 -e TLS_MODE=1 todo-deploy-pureftpd:test >/dev/null
[ "$PASV" = 30000 ] || { echo "Passive Ports müssen 30000-30009 sein (pure-ftpd meldet diese Ports)" >&2; exit 2; }

# Same site on both servers: index.php and css/app.css (CRLF) equal to the manifest, about.php changed, designer.html only on the server,
# plus files a pull must never deliver (.env, .git/config, inc/config.php with a password: named only).
fill='set -e; S=/home/deploy/site; mkdir -p $S/css; printf "hi\n" > $S/index.php; printf "a{}\r\nb{}\r\n" > $S/css/app.css;
  printf "alt\n" > $S/about.php; printf "<p>vom Designer</p>\n" > $S/designer.html; printf "outside-secret\n" > /home/deploy/outside.txt;
  mkdir -p $S/.git $S/inc; printf "DB_PASSWORD=E2E-GEHEIM-ENV\n" > $S/.env; printf "E2E-GEHEIM-GIT\n" > $S/.git/config;
  printf "<?php return [\"password\" => \"E2E-GEHEIM-CFG\"];\n" > $S/inc/config.php'
for _ in $(seq 1 30); do docker exec "$SFTP" test -d /home/deploy/site 2>/dev/null && break; sleep 1; done
docker exec "$SFTP" sh -c "$fill; ln -sf ../outside.txt \$S/link.txt; ln -sf /etc \$S/etclink; chown -R 1001 \$S"
# OpenSSH 10 penalises a source address after failed logins (PerSourcePenalties); the tests fail logins on purpose.
docker exec "$SFTP" sh -c 'echo "PerSourcePenalties no" >> /etc/ssh/sshd_config && kill -HUP 1'
sleep 1
for _ in $(seq 1 30); do docker exec "$FTP" test -f /etc/pure-ftpd/pureftpd.pdb 2>/dev/null && break; sleep 1; done
# Pull cage over FTP (ADR 0041): symlinks out of the base path "links"; FTP lists them like files and the server follows them.
links='L=/home/deploy/links; mkdir -p $L/sub /home/deploy/elsewhere; printf "plain\n" > $L/plain.txt; printf "deep\n" > "$L/sub/deep file #1.txt";
  printf "STRENG-GEHEIM1" > /home/deploy/secret14.tx; ln -sf ../secret14.tx $L/twin.txt;
  printf "STRENG-GEHEIM-2\n" > /home/deploy/elsewhere/in-dir.txt; ln -sf ../elsewhere $L/dirlink'
docker exec "$FTP" sh -c "$fill; $links; chown -R -h ftpuser:ftpgroup /home/deploy"
docker exec "$FTP" cat /etc/ssl/private/pure-ftpd.pem | openssl x509 > "$DIR/ftp-cert.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -keyout "$DIR/other.key" -out "$DIR/other-cert.pem" 2>/dev/null
for _ in $(seq 1 30); do ssh-keyscan -T 2 -p "$SFTP_PORT" 127.0.0.1 2>/dev/null | grep -q ssh- && break; sleep 1; done

export TODO_TEST_DEPLOY_SERVERS=1 TODO_TEST_DEPLOY_DIR="$DIR" TODO_TEST_DEPLOY_SFTP_PORT="$SFTP_PORT" TODO_TEST_DEPLOY_FTP_PORT="$FTP_PORT"
if [ "${1:-}" = --exec ]; then shift; "$@"; else
  ARGS=("$@"); [ ${#ARGS[@]} -eq 0 ] && ARGS=(--filter Deploy)
  $SWIFT test "${ARGS[@]}"
fi
