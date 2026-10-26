#!/usr/bin/env bash
# Isolated single-node smoke; only resources named with this run's random prefix are removed.
set -euo pipefail
cd "$(dirname "$0")/.."
state=$(docker info --format '{{.Swarm.LocalNodeState}}')
created_swarm=0
stack_created=0
node_labeled=0
secrets=()
STACK="todo-smoke-$(date +%s)-$$"
export STACK
export BACKEND_IMAGE=${BACKEND_IMAGE:-todo-dev-backend:local}
export BACKEND_REPLICAS=3 BACKEND_PORT=${BACKEND_PORT:-38080}
export DB_PASSWORD_SECRET="${STACK}_password" DB_ROOT_PASSWORD_SECRET="${STACK}_root" BOOTSTRAP_TOKEN_SECRET="${STACK}_bootstrap"
cleanup() {
  local result=$?
  trap - EXIT
  if [[ $stack_created == 1 ]]; then
    docker stack rm "$STACK" >/dev/null || result=1
    for ((j=0; j<90; j++)); do
      if ! docker network inspect "${STACK}_internal" >/dev/null 2>&1; then break; fi
      sleep 2
    done
    if [[ $j == 90 ]]; then echo 'Cleanup timeout: overlay still exists' >&2; result=1; fi
    if docker config inspect "${STACK}_deployment-lock" >/dev/null 2>&1; then
      docker config rm "${STACK}_deployment-lock" >/dev/null || result=1
    fi
    if docker volume inspect "${STACK}_db" >/dev/null 2>&1; then
      docker volume rm "${STACK}_db" >/dev/null || result=1
    fi
  fi
  for secret in "${secrets[@]-}"; do [[ -z "$secret" ]] && continue; docker secret rm "$secret" >/dev/null || result=1; done
  if [[ $node_labeled == 1 ]]; then docker node update --label-rm todo.data self >/dev/null || result=1; fi
  if [[ $created_swarm == 1 ]]; then docker swarm leave --force >/dev/null || result=1; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$state" in
  inactive) docker swarm init >/dev/null; created_swarm=1 ;;
  active) ;;
  *) echo "Unsupported Swarm state: $state" >&2; exit 1 ;;
esac
[[ $(docker node ls -q | wc -l | tr -d ' ') == 1 ]] || { echo 'Smoke requires a single-node manager; refusing changes' >&2; exit 1; }
label=$(docker node inspect self --format '{{index .Spec.Labels "todo.data"}}')
if [[ "$label" != true ]]; then
  [[ -z "$label" || "$label" == '<no value>' ]] || { echo 'Existing todo.data label conflicts' >&2; exit 1; }
  docker node update --label-add todo.data=true self >/dev/null
  node_labeled=1
fi
for secret in "$DB_PASSWORD_SECRET" "$DB_ROOT_PASSWORD_SECRET" "$BOOTSTRAP_TOKEN_SECRET"; do
  openssl rand -hex 32 | docker secret create "$secret" - >/dev/null
  secrets+=("$secret")
done
stack_created=1
scripts/swarm-deploy.sh
for ((i=0; i<150; i++)); do
  ids=$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_backend")
  containers=()
  while IFS= read -r id; do
    [[ -z "$id" ]] || containers+=("$id")
  done <<< "$ids"
  healthy=0
  for container in "${containers[@]-}"; do
    [[ -z "$container" ]] && continue
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "$container") == healthy ]]; then healthy=$((healthy+1)); fi
  done
  [[ $healthy == 3 ]] && break
  sleep 2
done
[[ $i -lt 150 ]] || { docker stack ps "$STACK" --no-trunc; echo 'Readiness timeout' >&2; exit 1; }
for container in "${containers[@]-}"; do
  docker exec "$container" /bin/bash /healthcheck.sh
  echo "Liveness + readiness OK: $container"
done
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for ((i=0; i<24; i++)); do
  for path in health/live health/ready v1/capabilities; do
    curl --fail --silent --show-error --max-time 10 -H 'Connection: close' "http://localhost:$BACKEND_PORT/$path"
    printf '\n'
  done
done
# Existing Vapor request logs may identify each container; no identity header is assumed.
for container in "${containers[@]-}"; do
  count=$(docker logs --since "$since" "$container" 2>&1 | awk '/GET \/(health\/|v1\/capabilities)/ {n++} END {print n+0}')
  echo "Replica $container: $count matching request log lines (includes healthchecks)."
done
echo 'Three healthy replicas; 72 public HTTP probes passed. Counts alone do not prove even balancing.'
