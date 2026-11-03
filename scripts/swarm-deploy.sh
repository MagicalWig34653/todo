#!/usr/bin/env bash
# Run from a manager. A Swarm config provides a cross-host deployment mutex.
set -euo pipefail
cd "$(dirname "$0")/../deploy/swarm"
STACK=${STACK:-todo}
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || exit 2
lock="${STACK}_deployment-lock"
printf 'deployment in progress\n' | docker config create "$lock" - >/dev/null
migration_running=0
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/${STACK}-deploy.XXXXXX")
placement_overlay="$work_dir/placement.yaml"
cleanup() {
  rm -rf "$work_dir"
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
# Placement helpers must be known before the feature overlays: they decide whether overlays may mention backend-pinned.
# shellcheck source=../deploy/swarm/placement.sh
. ./placement.sh
# Feature overlays are used through a copy without backend-pinned lines unless PINNED_NODE is set (placement_overlay_copy).
add_overlay() { placement_overlay_copy "$1" "$work_dir/$1"; compose_args+=(-c "$work_dir/$1"); }
# Optional S3 attachment storage: only when S3_ENDPOINT is set (needs the S3 secrets, see stack.s3.yaml).
if [[ -n "${S3_ENDPOINT:-}" ]]; then add_overlay stack.s3.yaml; fi
# Optional APNs push: only when APNS_ENABLED=true (needs the apns_key secret, see stack.push.yaml).
if [[ "${APNS_ENABLED:-false}" == true ]]; then add_overlay stack.push.yaml; fi
# Optional outgoing mail: only when MAIL_ENABLED=true (needs the smtp_password secret, see stack.mail.yaml).
if [[ "${MAIL_ENABLED:-false}" == true ]]; then add_overlay stack.mail.yaml; fi
# Optional key for secrets stored in the PWA (ADR 0025): only when SETTINGS_KEY_ENABLED=true (secret settings_key, see stack.settings.yaml).
if [[ "${SETTINGS_KEY_ENABLED:-false}" == true ]]; then add_overlay stack.settings.yaml; fi
# During a key rotation the previous key stays readable (stack.settings-previous.yaml).
if [[ -n "${SETTINGS_KEY_PREVIOUS_SECRET:-}" ]]; then add_overlay stack.settings-previous.yaml; fi
# Optional placement (PLACEMENT_CONSTRAINTS, PLACEMENT_PREFERENCES, EXCLUDE_LABEL, PINNED_NODE ...): see placement.sh.
# Also exports BACKEND_PINNED_EFFECTIVE_REPLICAS / BACKEND_PINNED_CONSTRAINT for the backend-pinned service (stack.pinned.yaml).
rc=0; placement_prepare "$placement_overlay" || rc=$?
case $rc in 0) compose_args+=(-c "$placement_overlay") ;; 1) ;; *) exit 2 ;; esac
# backend-pinned exists in the stack only with PINNED_NODE. Without it an old empty service is removed after the deploy;
# one that still has replicas stops the deploy now, before anything has been changed.
if [[ -n "${PINNED_NODE:-}" ]]; then compose_args+=(-c stack.pinned.yaml); else placement_pinned_guard "$STACK" || exit 2; fi
pinned_replicas=$BACKEND_PINNED_EFFECTIVE_REPLICAS
for f in ${STACK_EXTRA_FILES:-}; do compose_args+=(-c "$f"); done
# The DB is external: the one-shot migration below fails (without retry) if the DB is unreachable.
# Required: DB_HOST and the external secrets (see deploy/swarm/stack.env.example). S3 is optional.
replicas=${BACKEND_REPLICAS:-3}
if ! docker service inspect "${STACK}_backend" >/dev/null 2>&1; then
  # backend-pinned also starts only after the migration (final deploy below).
  BACKEND_REPLICAS=0 BACKEND_PINNED_EFFECTIVE_REPLICAS=0 docker stack deploy --resolve-image never "${compose_args[@]}" "$STACK"
elif ! docker service inspect "${STACK}_migrate" >/dev/null 2>&1; then
  # Backend runs but the one-shot migrate service is missing (removed by hand): recreate it
  # without touching the running backend replica count.
  current=$(docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "${STACK}_backend")
  running_image=$(docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "${STACK}_backend")
  running_tag=${running_image%%@*}; running_tag=${running_tag##*:}
  # backend-pinned (only with PINNED_NODE) keeps its replica count as well.
  current_pinned=$(docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "${STACK}_backend-pinned" 2>/dev/null || echo 0)
  # Keep the backend on the image it runs now; it is updated only after the migration succeeded.
  TODO_IMAGE_TAG=$running_tag BACKEND_REPLICAS=$current BACKEND_PINNED_EFFECTIVE_REPLICAS=$current_pinned docker stack deploy --resolve-image never "${compose_args[@]}" "$STACK"
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
BACKEND_REPLICAS=$replicas BACKEND_PINNED_EFFECTIVE_REPLICAS=$pinned_replicas docker stack deploy --resolve-image never "${compose_args[@]}" "$STACK"
# PINNED_NODE removed: drop the now empty backend-pinned service (stack deploy does not prune).
placement_pinned_cleanup "$STACK" || exit 2
echo "Migration complete; rollout started for $replicas replicas${PINNED_NODE:+ (+ $pinned_replicas pinned on $PINNED_NODE)}. Check health before accepting rollout."
