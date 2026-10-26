#!/usr/bin/env bash
# Run from a manager. A Swarm config provides a cross-host deployment mutex.
set -euo pipefail
cd "$(dirname "$0")/../deploy/swarm"
STACK=${STACK:-todo}
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || exit 2
lock="${STACK}_deployment-lock"
printf 'deployment in progress\n' | docker config create "$lock" - >/dev/null
migration_running=0
cleanup() {
  if [[ $migration_running == 1 ]]; then
    echo "Migration state uncertain; deployment lock retained: $lock. Inspect task before manually removing lock." >&2
  else
    docker config rm "$lock" >/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
image=${BACKEND_IMAGE:-todo-dev-backend:local}
replicas=${BACKEND_REPLICAS:-3}
if ! docker service inspect "${STACK}_backend" >/dev/null 2>&1; then
  BACKEND_REPLICAS=0 docker stack deploy --resolve-image never -c stack.yaml "$STACK"
fi
# Wait for DB before creating exactly one migration task. Never retry failed migrations blindly.
for ((i=0; i<120; i++)); do
  if docker run --rm --network "${STACK}_internal" mariadb:12.3 \
    mariadb-admin --host db ping --silent >/dev/null 2>&1; then break; fi
  sleep 2
done
[[ $i -lt 120 ]] || { echo 'Database timeout' >&2; exit 1; }
old_tasks=$(docker service ps --no-trunc --format '{{.ID}}' "${STACK}_migrate")
docker service scale "${STACK}_migrate=0" >/dev/null
migration_running=1
docker service update --detach --image "$image" --force --replicas 1 "${STACK}_migrate" >/dev/null
for ((i=0; i<120; i++)); do
  task=''
  while IFS= read -r candidate; do
    if ! grep -Fxq "$candidate" <<< "$old_tasks"; then task=$candidate; break; fi
  done < <(docker service ps --no-trunc --format '{{.ID}}' "${STACK}_migrate")
  if [[ -z "$task" ]]; then sleep 2; continue; fi
  state=$(docker inspect --format '{{.Status.State}}' "$task")
  case "$state" in
    complete) migration_running=0; break ;;
    failed|rejected) migration_running=0; echo "Migration failed: $task" >&2; exit 1 ;;
  esac
  sleep 2
done
[[ $i -lt 120 ]] || { echo 'Migration timeout' >&2; exit 1; }
BACKEND_REPLICAS=$replicas docker stack deploy --resolve-image never -c stack.yaml "$STACK"
echo "Migration complete; rollout started for $replicas replicas. Check health before accepting rollout."
