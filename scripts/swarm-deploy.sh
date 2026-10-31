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
image=${BACKEND_IMAGE:-ghcr.io/magicalwig34653/todo-backend:${TODO_IMAGE_TAG:-edge}}
# BACKEND_IMAGE (full reference) only overrides the migration image and must match an override file
# if the stack image is overridden too (the smoke test does this). Extra stack files (e.g. overrides) may be passed as space-separated STACK_EXTRA_FILES.
compose_args=(-c stack.yaml)
# Optional S3 attachment storage: only when S3_ENDPOINT is set (needs the S3 secrets, see stack.s3.yaml).
if [[ -n "${S3_ENDPOINT:-}" ]]; then compose_args+=(-c stack.s3.yaml); fi
# Optional APNs push: only when APNS_ENABLED=true (needs the apns_key secret, see stack.push.yaml).
if [[ "${APNS_ENABLED:-false}" == true ]]; then compose_args+=(-c stack.push.yaml); fi
for f in ${STACK_EXTRA_FILES:-}; do compose_args+=(-c "$f"); done
# The DB is external: the one-shot migration below fails (without retry) if the DB is unreachable.
# Required: DB_HOST and the external secrets (see deploy/swarm/stack.env.example). S3 is optional.
replicas=${BACKEND_REPLICAS:-3}
if ! docker service inspect "${STACK}_backend" >/dev/null 2>&1; then
  BACKEND_REPLICAS=0 docker stack deploy --resolve-image never "${compose_args[@]}" "$STACK"
fi
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
BACKEND_REPLICAS=$replicas docker stack deploy --resolve-image never "${compose_args[@]}" "$STACK"
echo "Migration complete; rollout started for $replicas replicas. Check health before accepting rollout."
