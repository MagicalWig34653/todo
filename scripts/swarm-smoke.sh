#!/usr/bin/env bash
# Isolated single-node smoke; only resources named with this run's random prefix are removed.
set -euo pipefail
cd "$(dirname "$0")/.."
state=$(docker info --format '{{.Swarm.LocalNodeState}}')
created_swarm=0
stack_created=0
secrets=()
STACK="todo-smoke-$(date +%s)-$$"
export STACK
export BACKEND_IMAGE=${BACKEND_IMAGE:-todo-dev-backend:local}
export BACKEND_REPLICAS=3 BACKEND_PORT=${BACKEND_PORT:-38080}
export DB_PASSWORD_SECRET="${STACK}_password" BOOTSTRAP_TOKEN_SECRET="${STACK}_bootstrap"
export S3_ACCESS_KEY_SECRET="${STACK}_s3_access" S3_SECRET_KEY_SECRET="${STACK}_s3_secret"
# The stack has no database: the smoke starts a throwaway external MariaDB on its own attachable overlay network.
EXT_NET="${STACK}_extdb" EXT_DB="${STACK}_extdb_mariadb"
export DB_HOST="$EXT_DB" DB_PORT=3306 DB_NAME=todo DB_USER=todo S3_ENDPOINT=http://s3.invalid S3_BUCKET=todo-attachments
tmpdir=$(mktemp -d)
ext_created=0
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
  fi
  docker rm -f "$EXT_DB" >/dev/null 2>&1 || true
  if [[ $ext_created == 1 ]]; then
    for ((j=0; j<45; j++)); do
      docker network rm "$EXT_NET" >/dev/null 2>&1 || true
      if ! docker network inspect "$EXT_NET" >/dev/null 2>&1; then break; fi
      sleep 2
    done
    if [[ $j == 45 ]]; then echo "Cleanup timeout: network $EXT_NET remains" >&2; result=1; fi
  fi
  rm -rf "$tmpdir"
  for secret in "${secrets[@]-}"; do [[ -z "$secret" ]] && continue; docker secret rm "$secret" >/dev/null || result=1; done
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
for secret in "$BOOTSTRAP_TOKEN_SECRET" "$S3_ACCESS_KEY_SECRET" "$S3_SECRET_KEY_SECRET"; do
  openssl rand -hex 32 | docker secret create "$secret" - >/dev/null
  secrets+=("$secret")
done
# Throwaway external MariaDB (password injected from the same random secret value via a temp file).
db_pw=$(openssl rand -hex 32)
printf '%s' "$db_pw" | docker secret create "$DB_PASSWORD_SECRET" - >/dev/null
secrets+=("$DB_PASSWORD_SECRET")
docker network create --driver overlay --attachable "$EXT_NET" >/dev/null
ext_created=1
docker run -d --name "$EXT_DB" --network "$EXT_NET" \
  -e MARIADB_DATABASE=todo -e MARIADB_USER=todo -e MARIADB_PASSWORD="$db_pw" -e MARIADB_RANDOM_ROOT_PASSWORD=1 \
  mariadb:12.3 >/dev/null
for ((i=0; i<60; i++)); do
  [[ $(docker exec "$EXT_DB" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; echo $?) == 0 ]] && break
  sleep 2
done
[[ $i -lt 60 ]] || { docker logs --tail 30 "$EXT_DB" >&2; echo 'External test DB timeout' >&2; exit 1; }
cat > "$tmpdir/extdb.yaml" <<EOF
version: '3.8'
services:
  migrate: {image: $BACKEND_IMAGE, networks: [internal, extdb]}
  backend: {image: $BACKEND_IMAGE, networks: [internal, extdb]}
networks:
  extdb: {external: true, name: $EXT_NET}
EOF
export STACK_EXTRA_FILES="$tmpdir/extdb.yaml"
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
# Probes go through the Swarm VIP (service name "backend") from a container on the overlay network.
# This does not depend on host port forwarding, which VM-based Docker hosts (Colima) may lack for ingress.
probe='for i in $(seq 24); do for path in health/live health/ready v1/capabilities; do exec 3<>/dev/tcp/backend/8080; printf "GET /$path HTTP/1.1\r\nHost: backend\r\nConnection: close\r\n\r\n" >&3; IFS= read -r st <&3; exec 3>&-; [[ "$st" == *" 200 "* ]] || { echo "FAIL $path: $st" >&2; exit 1; }; done; done'
docker run --rm --network "${STACK}_internal" --entrypoint /bin/bash "$BACKEND_IMAGE" -c "$probe"
# Best-effort check of the published ingress port from the host (informational only).
if curl --fail --silent --max-time 10 "http://localhost:$BACKEND_PORT/health/live" >/dev/null 2>&1; then
  echo "Host ingress port $BACKEND_PORT reachable."
else
  echo "Host ingress port $BACKEND_PORT NOT reachable from host (expected on Colima/VM hosts); not verified."
fi
# Existing Vapor request logs may identify each container; no identity header is assumed.
for container in "${containers[@]-}"; do
  count=$(docker logs --since "$since" "$container" 2>&1 | awk '/GET \/(health\/|v1\/capabilities)/ {n++} END {print n+0}')
  echo "Replica $container: $count matching request log lines (includes healthchecks)."
done
echo 'Three healthy replicas; 72 in-cluster HTTP probes via the service VIP passed. Counts alone do not prove even balancing.'
