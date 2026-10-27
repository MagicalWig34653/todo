#!/usr/bin/env bash
# Update a running Swarm stack to the newest published backend image: find the newest `sha-<commit>` tag on GHCR,
# write it into the env file (TODO_IMAGE_TAG), run the migration job with the new image (scripts/swarm-deploy.sh,
# which holds the cross-host deployment lock), then watch the rolling update and the readiness check.
#
# Usage: deploy/swarm/update.sh [options]
#   --env-file FILE   stack variables (default: ./.env, else stack.env next to this script)
#   --tag TAG         use this tag (e.g. sha-6c074f7 or 0.1.0) instead of looking up the newest sha- tag
#   --stack NAME      stack name (default: todo)
#   --dry-run         only show what would happen (no file change, no docker calls)
#   --force           also redeploy when the tag did not change
#   --yes             do not ask for confirmation
#
# How the newest tag is found: the Docker workflow pushes `edge` (newest main build) together with `sha-<commit>`
# on every push to main (and `latest`/semver tags for v* tags). The sha- tag whose digest equals `edge` is the newest
# build. It is found in constant time via the image label org.opencontainers.image.revision (verified against the
# digest of `edge`); comparing all tags is only a fallback. Needs curl and docker.
# Back up the database first (scripts/backup-db.sh, docs/BETRIEB.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK=todo
ENV_FILE=""
TAG=""
DRY=0
FORCE=0
YES=0
FOLLOW_TAG=edge
WAIT_SECONDS=600

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --tag) TAG="${2:?missing value for --tag}"; shift 2 ;;
    --stack) STACK="${2:?missing value for --stack}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid stack name: $STACK" >&2; exit 64; }

START_TIME=$(date +%s)
elapsed() { local t=$(( $(date +%s) - START_TIME )); printf '%02d:%02d' $((t / 60)) $((t % 60)); }
say() { printf '[%s] %s\n' "$(elapsed)" "$*"; }
STEP=0; STEPS=5
step() { STEP=$((STEP + 1)); printf '\n[%s] == Step %d/%d: %s\n' "$(elapsed)" "$STEP" "$STEPS" "$*"; }
die() { echo "[$(elapsed)] error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need curl
[ "$DRY" = 1 ] || need docker

if [ -z "$ENV_FILE" ]; then
  if [ -f ./.env ]; then ENV_FILE=./.env
  elif [ -f "$SCRIPT_DIR/stack.env" ]; then ENV_FILE="$SCRIPT_DIR/stack.env"
  else die "no .env or stack.env found; pass --env-file"; fi
fi
[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"

# Image repository: ghcr.io/magicalwig34653/todo-backend (the same name as in stack.yaml).
IMAGE_BASE="$(sed -n 's/^ *image: *\(ghcr\.io\/[^:$ ]*\).*/\1/p' "$SCRIPT_DIR/stack.yaml" | head -n 1)"
[ -n "$IMAGE_BASE" ] || die "cannot read the ghcr.io image name from stack.yaml"
REPO="${IMAGE_BASE#ghcr.io/}"
CURRENT_TAG="$(sed -n 's/^TODO_IMAGE_TAG=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
CURRENT_TAG="${CURRENT_TAG:-latest}"
CURRENT_IMAGE="${IMAGE_BASE}:${CURRENT_TAG}"

ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

registry_token() {
  curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${REPO}:pull" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
# Digest of a tag (empty when the tag does not exist).
digest_of() {
  curl -fsSI -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}
# Commit the image of a tag was built from (label org.opencontainers.image.revision); empty when it cannot be read.
revision_of() {
  local index manifest config
  index="$(curl -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1")" || return 1
  manifest="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"digest":"sha256:[0-9a-f]*","size":[0-9]*,"platform":{"architecture":"\(amd64\|arm64\)"' | head -1 | grep -o 'sha256:[0-9a-f]*' || true)"
  if [ -n "$manifest" ]; then
    index="$(curl -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/${manifest}")" || return 1
  fi
  config="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"config":{[^}]*}' | grep -o 'sha256:[0-9a-f]*' | head -1 || true)"
  [ -n "$config" ] || return 1
  curl -fsSL -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/blobs/${config}" \
    | grep -o '"org.opencontainers.image.revision":"[0-9a-f]*"' | head -1 | sed 's/.*:"\([0-9a-f]*\)"/\1/' || true
}

step "Find the newest image tag"
if [ -z "$TAG" ]; then
  say "Registry: ghcr.io, repository ${REPO}"
  TOKEN="$(registry_token)"; [ -n "$TOKEN" ] || die "could not get a registry token (is the package public?)"
  FOLLOW_DIGEST="$(digest_of "$FOLLOW_TAG")"; [ -n "$FOLLOW_DIGEST" ] || die "tag '${FOLLOW_TAG}' not found on ghcr.io"
  say "${FOLLOW_TAG} = ${FOLLOW_DIGEST}"
  REVISION="$(revision_of "$FOLLOW_TAG" || true)"
  if [ -n "$REVISION" ]; then
    candidate="sha-${REVISION:0:7}"
    if [ "$(digest_of "$candidate")" = "$FOLLOW_DIGEST" ]; then TAG="$candidate"; say "${FOLLOW_TAG} was built from commit ${REVISION:0:7} -> ${candidate} (verified)"; fi
  fi
  if [ -z "$TAG" ]; then
    say "Label lookup did not give a verified tag, comparing all sha- tags (slow with many images) ..."
    TAGS="$(curl -fsS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/tags/list?n=1000" | grep -o '"sha-[0-9a-f]*"' | tr -d '"' || true)"
    [ -n "$TAGS" ] || die "no sha- tags found"
    for candidate in $TAGS; do
      if [ "$(digest_of "$candidate")" = "$FOLLOW_DIGEST" ]; then TAG="$candidate"; say "  ${candidate} matches ${FOLLOW_TAG}"; break; fi
    done
  fi
  [ -n "$TAG" ] || die "no sha- tag matches ${FOLLOW_TAG} (${FOLLOW_DIGEST}); pass --tag explicitly"
else
  say "Using the tag from --tag: ${TAG}"
fi

NEW_IMAGE="${IMAGE_BASE}:${TAG}"
echo "Stack:     ${STACK}"
echo "Env file:  ${ENV_FILE}"
echo "Current:   ${CURRENT_IMAGE}"
echo "New:       ${NEW_IMAGE}"

if [ "$TAG" = "$CURRENT_TAG" ] && [ "$FORCE" = 0 ]; then
  echo "Already on the newest tag. Nothing to do (use --force to redeploy anyway)."
  exit 0
fi
if [ "$DRY" = 1 ]; then
  echo "Dry run: would set TODO_IMAGE_TAG=${TAG}, run the migration job, then roll ${STACK}_backend."
  exit 0
fi

step "Confirm"
if [ "$YES" = 0 ]; then
  printf 'Database backed up? Continue with the update? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|j|J|ja) ;; *) echo "Aborted."; exit 1 ;; esac
else
  say "Confirmation skipped (--yes)."
fi

step "Write the new tag into ${ENV_FILE}"
cp "$ENV_FILE" "${ENV_FILE}.bak"
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
awk -v tag="$TAG" 'BEGIN{done=0} /^TODO_IMAGE_TAG=/ {print "TODO_IMAGE_TAG=" tag; done=1; next} {print} END{if(!done) print "TODO_IMAGE_TAG=" tag}' "$ENV_FILE" > "$TMP"
cat "$TMP" > "$ENV_FILE"; rm -f "$TMP"
say "Wrote TODO_IMAGE_TAG=${TAG} (backup: ${ENV_FILE}.bak)."

step "Migrate and start the rolling update (scripts/swarm-deploy.sh)"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
export TODO_IMAGE_TAG="$TAG" STACK
"$SCRIPT_DIR/../../scripts/swarm-deploy.sh"

step "Watch the rollout and check the result"
BACKEND="${STACK}_backend"
waited=0; last=""
while :; do
  ustate="$(docker service inspect "$BACKEND" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
  replicas="$(docker service ls --filter "name=${BACKEND}" --format '{{.Replicas}}' | head -n 1)"
  now="update=${ustate:-none} replicas=${replicas}"
  if [ "$now" != "$last" ]; then say "$now"; last="$now"; fi
  case "$ustate" in
    completed|"") case "$replicas" in */*) [ "${replicas%%/*}" = "${replicas##*/}" ] && [ "${replicas%%/*}" != 0 ] && { say "Rollout completed."; break; } ;; esac ;;
    paused|rollback_started|rollback_completed|rollback_paused)
      docker service inspect "$BACKEND" --format '{{.UpdateStatus.Message}}' >&2 || true
      docker service ps "$BACKEND" --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}' | head -n 6 >&2 || true
      die "rollout did not succeed (${ustate}); Swarm rolls back automatically" ;;
  esac
  [ "$waited" -lt "$WAIT_SECONDS" ] || die "rollout did not finish within ${WAIT_SECONDS}s (see: docker service ps ${BACKEND})"
  sleep 3; waited=$((waited + 3))
done
docker service ps "$BACKEND" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'

BASE_URL="${PUBLIC_BASE_URL:-${RP_ORIGIN:-}}"
if [ -n "$BASE_URL" ]; then
  say "GET ${BASE_URL%/}/health/ready -> $(curl -fsS "${BASE_URL%/}/health/ready" 2>&1 || echo 'not ready yet')"
else
  say "Neither PUBLIC_BASE_URL nor RP_ORIGIN is set in the env file; skipping the readiness check."
fi
say "Done in $(elapsed)."
