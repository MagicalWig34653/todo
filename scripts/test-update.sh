#!/usr/bin/env bash
# Tests the readiness-check URL of deploy/swarm/update.sh: the env file wins over PUBLIC_BASE_URL from the caller's shell.
# No network, no Swarm: curl and docker are stubs, swarm-deploy.sh is replaced in a temp copy of the tree.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
mkdir -p "$tmp/tree/deploy" "$tmp/tree/scripts" "$tmp/bin"
cp -R "$root/deploy/swarm" "$tmp/tree/deploy/swarm"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/tree/scripts/swarm-deploy.sh"
chmod +x "$tmp/tree/scripts/swarm-deploy.sh"
printf '#!/usr/bin/env bash\necho "curl $*" >> "%s/curl.log"\necho ok\n' "$tmp" > "$tmp/bin/curl"
# docker stub: the service is converged, so the rollout waits return at once
cat > "$tmp/bin/docker" <<'DEOF'
#!/usr/bin/env bash
case "$*" in
  *"UpdateStatus.State"*) echo completed ;;
  "service ls"*) echo "todo_backend 2/2" ;;
  *"Spec.Mode.Replicated.Replicas"*) echo 0 ;;
esac
exit 0
DEOF
chmod +x "$tmp/bin/curl" "$tmp/bin/docker"

# run NAME EXPECTED_URL ("" = no readiness check) SHELL_VAR ENV_FILE_LINE...
run() {
  local name="$1" want="$2" shellvar="$3"; shift 3
  printf '%s\n' "TODO_IMAGE_TAG=sha-old" "$@" > "$tmp/stack.env"; : > "$tmp/curl.log"
  local rc=0
  if [ -n "$shellvar" ]; then
    env -i PATH="$tmp/bin:$PATH" "PUBLIC_BASE_URL=$shellvar" bash "$tmp/tree/deploy/swarm/update.sh" --env-file "$tmp/stack.env" --tag sha-new --yes >"$tmp/out" 2>&1 || rc=$?
  else
    env -i PATH="$tmp/bin:$PATH" bash "$tmp/tree/deploy/swarm/update.sh" --env-file "$tmp/stack.env" --tag sha-new --yes >"$tmp/out" 2>&1 || rc=$?
  fi
  local log; log="$(cat "$tmp/curl.log")"
  if [ "$rc" != 0 ]; then bad "$name (rc $rc): $(tail -n 3 "$tmp/out")"
  elif [ -z "$want" ]; then if [ -z "$log" ]; then ok "$name"; else bad "$name: unexpected curl: $log"; fi
  elif [[ "$log" == *"$want/health/ready"* && "$log" != *timetrack* ]]; then ok "$name"
  else bad "$name (wanted $want): $log"; fi
}
run "shell PUBLIC_BASE_URL ignored, RP_ORIGIN used" "https://todo.example" "https://timetrack.example" RP_ORIGIN=https://todo.example
run "env file PUBLIC_BASE_URL wins over shell" "https://file.example" "https://timetrack.example" RP_ORIGIN=https://todo.example PUBLIC_BASE_URL=https://file.example
run "no shell variable, RP_ORIGIN used" "https://todo.example" "" RP_ORIGIN=https://todo.example
run "shell variable only, env file without URL: no check" "" "https://timetrack.example" FOO=bar
exit $fail
