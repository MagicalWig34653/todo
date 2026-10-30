#!/usr/bin/env bash
# Setup wizard for a production Docker Swarm: asks for (or reads) all settings of the todo stack, validates them,
# writes the env file (deploy/swarm/stack.env, mode 600, gitignored), creates the Swarm secrets, deploys
# (migration first, then rollout via scripts/swarm-deploy.sh) and verifies health and the AASA endpoint.
#
# Usage: deploy/swarm/setup.sh [options]
#   --env-file FILE      env file to write and, when it exists, to read as defaults (default: deploy/swarm/stack.env)
#   --answers-file FILE  KEY=VALUE answers (same names as in the env file, plus the secret values DB_PASSWORD,
#                        S3_ACCESS_KEY, S3_SECRET_KEY, BOOTSTRAP_TOKEN, optionally APPLE_TEAM_ID/APPLE_BUNDLE_IDS,
#                        PUBLIC_DOMAIN, CHECK_NETWORK, SWARM_ADVERTISE_ADDR); the file is parsed, never executed
#   --non-interactive    never prompt; take answers (file, SETUP_<KEY> env vars, existing env file, defaults)
#   --reconfigure        prompt again for every value, existing env values are the defaults
#                        (without it an existing env file is reused as is: idempotent re-run)
#   --stack NAME         stack name (default: todo)
#   --tag TAG            image tag instead of the newest sha- tag
#   --swarm-init         non-interactive: run `docker swarm init` when no swarm is active
#   --skip-checks        skip the database/S3 connectivity checks
#   --no-deploy          write env file and create secrets only
#   --dry-run            no docker calls, no secrets; shows the plan and writes the env file to a temp directory
#   --yes                do not ask for the final confirmation
# Secret values are never written to the env file and never printed (except a generated bootstrap token, once).
# TLS and the reverse proxy are external: the proxy must forward the AASA paths without a redirect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/stack.env"
ANSWERS_FILE=""
NONINTERACTIVE=0
RECONFIGURE=0
STACK_ARG=""
TAG_ARG=""
SWARM_INIT=0
SKIP_CHECKS=0
NO_DEPLOY=0
DRY=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --answers-file) ANSWERS_FILE="${2:?missing value for --answers-file}"; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --stack) STACK_ARG="${2:?missing value for --stack}"; shift 2 ;;
    --tag) TAG_ARG="${2:?missing value for --tag}"; shift 2 ;;
    --swarm-init) SWARM_INIT=1; shift ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --no-deploy) NO_DEPLOY=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done

START_TIME=$(date +%s)
elapsed() { local t=$(( $(date +%s) - START_TIME )); printf '%02d:%02d' $((t / 60)) $((t % 60)); }
say() { printf '[%s] %s\n' "$(elapsed)" "$*"; }
warn() { printf '[%s] WARNUNG: %s\n' "$(elapsed)" "$*" >&2; }
die() { echo "[$(elapsed)] Fehler: $*" >&2; exit 1; }
STEP=0
step() { STEP=$((STEP + 1)); printf '\n[%s] == Schritt %d: %s\n' "$(elapsed)" "$STEP" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 wird benötigt, ist aber nicht installiert"; }
interactive() { [ "$NONINTERACTIVE" = 0 ] && [ -t 0 ]; }
if [ "$NONINTERACTIVE" = 0 ] && [ ! -t 0 ]; then
  die "keine Terminal-Eingabe: --non-interactive mit --answers-file verwenden"
fi

# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------- answer sources
# Parsed KEY=VALUE files (never sourced): answers go to A_<KEY>, the existing env file to E_<KEY>.
parse_kv() { # file prefix
  local file="$1" prefix="$2" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
    printf -v "${prefix}${key}" '%s' "$val"
  done < "$file"
}
HAVE_ENV=0
if [ -f "$ENV_FILE" ]; then HAVE_ENV=1; parse_kv "$ENV_FILE" E_; fi
if [ -n "$ANSWERS_FILE" ]; then
  [ -f "$ANSWERS_FILE" ] || die "Antwortdatei nicht gefunden: $ANSWERS_FILE"
  parse_kv "$ANSWERS_FILE" A_
fi
REUSE=0
if [ "$HAVE_ENV" = 1 ] && [ "$RECONFIGURE" = 0 ]; then REUSE=1; fi

# Value precedence: answers file > SETUP_<KEY> environment > existing env file > default.
# Sets SRC to the origin ("answer", "env", "existing" or "default") and echoes the value.
SRC=default
LV=""
lookup() { # key default -> LV (value) and SRC; not for use inside $(...)
  local k="$1" d="$2" v
  v="A_$k"; if [ -n "${!v+x}" ]; then SRC=answer; LV="${!v}"; return 0; fi
  v="SETUP_$k"; if [ -n "${!v+x}" ]; then SRC="env"; LV="${!v}"; return 0; fi
  v="E_$k"; if [ -n "${!v+x}" ]; then SRC=existing; LV="${!v}"; return 0; fi
  SRC=default; LV="$d"
}
get() { lookup "$@"; printf '%s' "$LV"; } # value only (safe in $(...))
# valid_<name> functions return 0/1 and print a hint to stderr on failure.
ask() { # VAR "German prompt" default validator [explanation]
  local var="$1" prompt="$2" def="$3" validator="$4" help="${5:-}" cur val src
  lookup "$var" "$def"; cur="$LV"; src="$SRC"
  if [ "$NONINTERACTIVE" = 1 ] || { [ "$REUSE" = 1 ] && [ "$src" != default ]; } || [ "$src" = answer ] || [ "$src" = env ]; then
    if "$validator" "$cur" 2>/dev/null; then printf -v "$var" '%s' "$cur"; return 0; fi
    if [ "$NONINTERACTIVE" = 1 ] || [ "$src" = answer ] || [ "$src" = env ]; then
      "$validator" "$cur" || true
      die "ungültiger oder fehlender Wert für $var ('$cur', Quelle: $src)"
    fi
  fi
  [ -z "$help" ] || printf '\n%s\n' "$help"
  while :; do
    printf '%s [%s]: ' "$prompt" "$cur"
    IFS= read -r val || die "Eingabe abgebrochen"
    val="${val:-$cur}"
    if "$validator" "$val"; then printf -v "$var" '%s' "$val"; return 0; fi
  done
}
confirm() { # prompt default(y|n) -> 0 for yes
  local prompt="$1" def="$2" a hint='[j/N]'
  [ "$def" = y ] && hint='[J/n]'
  if ! interactive; then [ "$def" = y ]; return; fi
  printf '%s %s ' "$prompt" "$hint"
  IFS= read -r a || die "Eingabe abgebrochen"
  a="${a:-$def}"
  case "$a" in y|Y|j|J|ja|Ja|yes) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- validators
bad() { echo "  ungültig: $*" >&2; return 1; }
valid_stack() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || bad "Stack-Name: Kleinbuchstaben, Ziffern, '-', beginnt mit Buchstabe"; }
valid_tag() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || bad "Image-Tag (z. B. sha-abc1234, 0.1.0, edge)"; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9_]([A-Za-z0-9_.-]*[A-Za-z0-9_])?$ ]] || bad "Hostname oder IPv4-Adresse"; }
valid_domain() { { valid_host "$1" 2>/dev/null && { [[ "$1" == *.* ]] || [ "$1" = localhost ]; } && [ "$1" = "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ]; } || bad "Domain in Kleinbuchstaben, z. B. todo.example.org"; }
valid_origin() {
  local o="$1" hostport host
  [[ "$o" =~ ^https?://[a-z0-9.-]+(:[0-9]{1,5})?$ ]] || { bad "Origin wie https://todo.example.org (ohne Pfad und Schrägstrich am Ende)"; return 1; }
  hostport="${o#*://}"; host="${hostport%%:*}"
  case "$host" in
    "$RP_ID"|*."$RP_ID") ;;
    *) bad "RP_ORIGIN-Host '$host' muss RP_ID '$RP_ID' sein oder darunter liegen"; return 1 ;;
  esac
}
valid_port() { { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; } || bad "Port 1-65535"; }
valid_replicas() { { [[ "$1" =~ ^[0-9]{1,2}$ ]] && [ "$1" -ge 1 ]; } || bad "Anzahl Replikate 1-99"; }
valid_cpu() { [[ "$1" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || bad "CPU-Limit wie 1.5 (0 = unbegrenzt)"; }
valid_mem() { [[ "$1" =~ ^([0-9]+[bBkKmMgG]?)$ ]] || bad "Speicher-Limit wie 512M oder 1G (0 = unbegrenzt)"; }
valid_ident() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || bad "Name aus Buchstaben, Ziffern, _ . -"; }
valid_bool() { [[ "$1" == true || "$1" == false ]] || bad "true oder false"; }
valid_url() { [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] || bad "URL wie https://s3.example.org[:9000]"; }
valid_bucket() { [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || bad "Bucket-Name: 3-63 Zeichen, a-z 0-9 . -"; }
valid_region() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || bad "Region wie eu-central-1 oder us-east-1"; }
valid_team() { [ -z "$1" ] || [[ "$1" =~ ^[A-Z0-9]{10}$ ]] || bad "Apple Team ID: 10 Zeichen A-Z0-9 (leer = AASA aus)"; }
valid_bundles() { [[ "$1" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(,[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)*$ ]] || bad "Bundle-IDs kommagetrennt, z. B. de.example.todo,de.example.todo.mac"; }
valid_aasa() {
  local id rc=0
  [ -z "$1" ] && return 0
  local IFS=,
  for id in $1; do
    [[ "$id" =~ ^[A-Z0-9]{10}\.[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { bad "AASA_APP_IDS: '$id' ist nicht TeamID.BundleID"; rc=1; }
  done
  return "$rc"
}
valid_any() { return 0; }

# ---------------------------------------------------------------- docker helpers
docker_ok() { [ "$DRY" = 1 ] && return 1; docker "$@" >/dev/null 2>&1; }
secret_exists() { docker_ok secret inspect "$1"; }

# Returns the secret value from the answers/environment: <KEY> or <KEY>_FILE (path); empty when none.
provided_secret() {
  local key="$1" v f
  f="$(get "${key}_FILE" '')"; if [ -n "$f" ]; then [ -r "$f" ] || die "${key}_FILE nicht lesbar: $f"; tr -d '\r\n' < "$f"; return; fi
  v="A_$key"; if [ -n "${!v-}" ]; then printf '%s' "${!v}"; return; fi
  v="SETUP_$key"; if [ -n "${!v-}" ]; then printf '%s' "${!v}"; return; fi
}
# prompt_secret KEY label -> value in SECRET_VALUE (hidden input; empty = none)
prompt_secret() {
  local label="$2" a b
  SECRET_VALUE="$(provided_secret "$1")"
  [ -z "$SECRET_VALUE" ] || return 0
  [ "$NONINTERACTIVE" = 0 ] || return 0
  while :; do
    printf '%s (Eingabe wird nicht angezeigt): ' "$label"; IFS= read -rs a || die "Eingabe abgebrochen"; echo
    [ -n "$a" ] || { echo "  darf nicht leer sein" >&2; continue; }
    printf '%s (Wiederholung): ' "$label"; IFS= read -rs b || die "Eingabe abgebrochen"; echo
    [ "$a" = "$b" ] && { SECRET_VALUE="$a"; return 0; }
    echo "  Eingaben stimmen nicht überein" >&2
  done
}

# ---------------------------------------------------------------- Step 1: preflight
step "Voraussetzungen prüfen"
need curl
need openssl
[ "$DRY" = 1 ] || need docker
SWARM_CREATED=0
if [ "$DRY" = 1 ]; then
  say "Trockenlauf: keine Docker-Aufrufe (Swarm-Status, Secrets und Verbindungstests entfallen)."
else
  docker info >/dev/null 2>&1 || die "Docker-Daemon nicht erreichbar (docker info schlägt fehl)"
  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
  case "$swarm_state" in
    active)
      [ "$(docker info --format '{{.Swarm.ControlAvailable}}')" = true ] || die "dieser Knoten ist ein Swarm-Worker; das Skript muss auf einem Manager laufen"
      say "Swarm aktiv, dieser Knoten ist Manager." ;;
    inactive)
      say "Docker Swarm ist auf diesem Host nicht aktiv."
      go=0
      if [ "$NONINTERACTIVE" = 1 ]; then
        [ "$SWARM_INIT" = 1 ] || die "kein aktiver Swarm; mit --swarm-init erlauben oder manuell 'docker swarm init' ausführen"
        go=1
      else
        confirm "'docker swarm init' jetzt ausführen (macht diesen Host zum Swarm-Manager)?" n && go=1
        [ "$go" = 1 ] || die "ohne Swarm kein Stack-Deploy; abgebrochen"
      fi
      adv="$(get SWARM_ADVERTISE_ADDR '')"
      if [ -z "$adv" ] && [ "$NONINTERACTIVE" = 0 ]; then
        printf 'Advertise-Adresse für den Swarm (IP oder Interface, leer = automatisch): '; IFS= read -r adv || die "Eingabe abgebrochen"
      fi
      if [ -n "$adv" ]; then docker swarm init --advertise-addr "$adv" >/dev/null; else docker swarm init >/dev/null; fi
      SWARM_CREATED=1
      say "Swarm initialisiert." ;;
    *) die "Swarm-Status '$swarm_state' wird nicht unterstützt (erwartet: active oder inactive)" ;;
  esac
fi

# ---------------------------------------------------------------- Step 2: stack and image
step "Stack und Image"
STACK_DEFAULT="${STACK_ARG:-todo}"
ask TODO_STACK "Stack-Name" "$STACK_DEFAULT" valid_stack "Der Stack-Name bestimmt die Namen der Dienste (<name>_backend, <name>_migrate)."
[ -z "$STACK_ARG" ] || TODO_STACK="$STACK_ARG"
valid_stack "$TODO_STACK" || die "ungültiger Stack-Name"
if [ "$DRY" = 0 ] && docker_ok service inspect "${TODO_STACK}_backend"; then
  say "Stack '$TODO_STACK' läuft bereits: das Skript führt ein Update (Migration + Rolling Update) aus."
fi

IMAGE_BASE="$(stack_image_base)"; [ -n "$IMAGE_BASE" ] || die "Image-Name nicht aus stack.yaml lesbar"
REPO="${IMAGE_BASE#ghcr.io/}" # used by lib.sh
export REPO
tag_default=""
if [ -n "$TAG_ARG" ]; then
  tag_default="$TAG_ARG"
else
  lookup TODO_IMAGE_TAG ''; cur="$LV"
  if [ -n "$cur" ] && [ "$SRC" != default ] && { [ "$REUSE" = 1 ] || [ "$NONINTERACTIVE" = 1 ] || [ "$SRC" = answer ]; }; then
    tag_default="$cur"
  else
    say "Suche das neueste Image-Tag auf ghcr.io ..."
    found="$( (find_newest_sha_tag >&2 2>/dev/null; printf '%s' "$TAG") || true)"
    if [ -n "$found" ]; then
      tag_default="$found"
    else
      warn "neuestes Tag nicht ermittelbar (Registry nicht erreichbar?); Vorschlag: edge"
      tag_default="${cur:-edge}"
    fi
  fi
fi
ask TODO_IMAGE_TAG "Image-Tag (${IMAGE_BASE})" "$tag_default" valid_tag "Empfohlen: ein fest gepinntes sha-<commit>- oder Versions-Tag statt 'edge'."
[ -z "$TAG_ARG" ] || TODO_IMAGE_TAG="$TAG_ARG"
[ "$TODO_IMAGE_TAG" != edge ] || warn "'edge' folgt jedem Push auf main; für Produktion ein festes Tag wählen."

# ---------------------------------------------------------------- Step 3: public address, passkeys, login
step "Öffentliche Adresse, Passkeys und Anmeldung"
dom_default="$(get PUBLIC_DOMAIN '')"
[ -n "$dom_default" ] || dom_default="$(get RP_ID 'todo.linolaske.de')"
ask PUBLIC_DOMAIN "Öffentliche Domain" "$dom_default" valid_domain \
  "Unter dieser Domain erreichen Browser und Apps die API (TLS und Reverse Proxy liegen außerhalb dieses Stacks)."
ask RP_ID "WebAuthn RP_ID (nackte Domain)" "$PUBLIC_DOMAIN" valid_domain \
  "RP_ID bindet die Passkeys an die Domain und kann später nicht ohne Verlust der Passkeys geändert werden."
ask RP_ORIGIN "WebAuthn RP_ORIGIN (genauer Browser-Origin)" "https://$PUBLIC_DOMAIN" valid_origin
case "$RP_ORIGIN" in http://*) warn "RP_ORIGIN ohne https: Passkeys und sichere Cookies funktionieren nur auf localhost ohne TLS." ;; esac

team_default="$(get APPLE_TEAM_ID '')"
if [ -z "$team_default" ]; then
  first="$(get AASA_APP_IDS 'J2DU2P47XW.de.linolaske.todo,J2DU2P47XW.de.linolaske.todo.mac')"; team_default="${first%%.*}"
fi
bundle_default="$(get APPLE_BUNDLE_IDS '')"
if [ -z "$bundle_default" ]; then
  first="$(get AASA_APP_IDS 'J2DU2P47XW.de.linolaske.todo,J2DU2P47XW.de.linolaske.todo.mac')"
  bundle_default="$(printf '%s' "$first" | tr ',' '\n' | sed 's/^[^.]*\.//' | paste -sd, -)"
fi
lookup AASA_APP_IDS '__unset__'; direct="$LV"; direct_src="$SRC"
if [ "$direct" != __unset__ ] && { [ "$direct_src" = answer ] || [ "$direct_src" = env ] || { [ "$REUSE" = 1 ] && [ "$direct_src" = existing ]; }; } && [ -z "$(get APPLE_TEAM_ID '')" ]; then
  AASA_APP_IDS="$direct"
  valid_aasa "$AASA_APP_IDS" || die "AASA_APP_IDS ungültig"
else
  ask APPLE_TEAM_ID "Apple Team ID für Passkeys in den Apps (leer = AASA-Endpunkt aus)" "$team_default" valid_team \
    "Die Apps liegen unter <TeamID>.<BundleID>; der Server liefert sie unter /.well-known/apple-app-site-association (webcredentials)."
  AASA_APP_IDS=""
  if [ -n "$APPLE_TEAM_ID" ]; then
    ask APPLE_BUNDLE_IDS "Bundle-IDs (kommagetrennt)" "$bundle_default" valid_bundles
    AASA_APP_IDS="$(printf '%s' "$APPLE_BUNDLE_IDS" | tr ',' '\n' | sed "s/^/${APPLE_TEAM_ID}./" | paste -sd, -)"
    valid_aasa "$AASA_APP_IDS" || die "AASA_APP_IDS ungültig"
  else
    warn "ohne AASA_APP_IDS antwortet /.well-known/apple-app-site-association mit 404; Passkeys in den nativen Apps funktionieren dann nicht."
  fi
fi

ask PASSWORD_LOGIN_ENABLED "Passwort-Anmeldung zusätzlich zu Passkeys erlauben (true/false)" "false" valid_bool \
  "Passkeys sind der Standard. true schaltet serverseitig die Passwort-Anmeldung frei; für Produktion empfohlen: false."

# ---------------------------------------------------------------- Step 4: resources
step "Ingress-Port, Replikate und Ressourcen"
ask BACKEND_PORT "Veröffentlichter Port auf den Swarm-Knoten (Reverse Proxy zeigt hierauf)" "38080" valid_port
ask BACKEND_REPLICAS "Anzahl API-Replikate" "3" valid_replicas "Mindestens 2 erlauben unterbrechungsfreie Rolling Updates (start-first)."
ask BACKEND_CPU_LIMIT "CPU-Limit je Replikat (0 = unbegrenzt)" "0" valid_cpu
ask BACKEND_MEMORY_LIMIT "Speicher-Limit je Replikat, z. B. 512M (0 = unbegrenzt)" "0" valid_mem

# ---------------------------------------------------------------- Step 5: external MariaDB
step "Externe MariaDB"
echo "Die Datenbank ist extern (nicht Teil des Stacks) und muss von allen Swarm-Knoten erreichbar sein."
ask DB_HOST "DB_HOST" "$(get DB_HOST '')" valid_host
ask DB_PORT "DB_PORT" "3306" valid_port
ask DB_NAME "DB_NAME" "todo" valid_ident
ask DB_USER "DB_USER" "todo" valid_ident
ask DB_PASSWORD_SECRET "Name des Swarm-Secrets für das DB-Passwort" "${TODO_STACK}_db_password" valid_ident

# ---------------------------------------------------------------- Step 6: external S3
step "Externer S3-Speicher"
echo "Anhänge und Screenshots liegen in einem S3-kompatiblen Bucket (extern, muss existieren)."
ask S3_ENDPOINT "S3_ENDPOINT" "$(get S3_ENDPOINT '')" valid_url
ask S3_BUCKET "S3_BUCKET" "todo-attachments" valid_bucket
ask S3_REGION "S3_REGION" "us-east-1" valid_region
ask S3_ACCESS_KEY_SECRET "Name des Secrets für den S3-Access-Key" "${TODO_STACK}_s3_access_key" valid_ident
ask S3_SECRET_KEY_SECRET "Name des Secrets für den S3-Secret-Key" "${TODO_STACK}_s3_secret_key" valid_ident
ask BOOTSTRAP_TOKEN_SECRET "Name des Secrets für das Bootstrap-Token" "${TODO_STACK}_bootstrap_token" valid_ident \
  "Das Bootstrap-Token erlaubt einmalig das Anlegen des ersten Administrator-Kontos."

# ---------------------------------------------------------------- Step 7: secrets
step "Secrets"
# Per secret: status exists | create | missing; value in SV_<KEY> (never printed).
SECRET_KEYS="DB_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY BOOTSTRAP_TOKEN"
secret_name() {
  case "$1" in
    DB_PASSWORD) echo "$DB_PASSWORD_SECRET" ;; S3_ACCESS_KEY) echo "$S3_ACCESS_KEY_SECRET" ;;
    S3_SECRET_KEY) echo "$S3_SECRET_KEY_SECRET" ;; BOOTSTRAP_TOKEN) echo "$BOOTSTRAP_TOKEN_SECRET" ;;
  esac
}
secret_label() {
  case "$1" in
    DB_PASSWORD) echo "Datenbank-Passwort" ;; S3_ACCESS_KEY) echo "S3 Access Key" ;;
    S3_SECRET_KEY) echo "S3 Secret Key" ;; BOOTSTRAP_TOKEN) echo "Bootstrap-Token" ;;
  esac
}
GENERATED_TOKEN=0
for key in $SECRET_KEYS; do
  name="$(secret_name "$key")"
  if secret_exists "$name"; then
    printf -v "SS_$key" '%s' exists
    say "Secret '$name' ($(secret_label "$key")) existiert bereits und bleibt unverändert."
    prompt_val="$(provided_secret "$key")"
    # An existing secret cannot be read back; a provided value is kept only for connectivity checks.
    printf -v "SV_$key" '%s' "$prompt_val"
    continue
  fi
  printf -v "SS_$key" '%s' create
  if [ "$key" = BOOTSTRAP_TOKEN ]; then
    SECRET_VALUE="$(provided_secret "$key")"
    if [ -z "$SECRET_VALUE" ]; then SECRET_VALUE="$(openssl rand -hex 32)"; GENERATED_TOKEN=1; fi
  elif [ "$DRY" = 1 ] && [ -z "$(provided_secret "$key")" ]; then
    SECRET_VALUE="dry-run-placeholder"
  else
    prompt_secret "$key" "$(secret_label "$key") für Secret '$name'"
    [ -n "$SECRET_VALUE" ] || die "kein Wert für $key angegeben (${key} oder ${key}_FILE in der Antwortdatei)"
  fi
  printf -v "SV_$key" '%s' "$SECRET_VALUE"
done
SECRET_VALUE=""

# ---------------------------------------------------------------- Step 8: connectivity checks
step "Verbindungsprüfungen"
CHECK_NETWORK="$(get CHECK_NETWORK '')"
if [ "$SKIP_CHECKS" = 1 ] || [ "$DRY" = 1 ]; then
  say "übersprungen ($([ "$DRY" = 1 ] && echo Trockenlauf || echo --skip-checks))."
else
  net_args=()
  [ -z "$CHECK_NETWORK" ] || net_args=(--network "$CHECK_NETWORK")
  run_checks=1
  if [ "$NONINTERACTIVE" = 0 ] && ! confirm "Datenbank und S3 jetzt auf Erreichbarkeit prüfen?" y; then run_checks=0; fi
  CHECK_FAILED=0
  if [ "$run_checks" = 1 ]; then
    if [ -n "${SV_DB_PASSWORD-}" ]; then
      say "Datenbank: mariadb:12.3 Wegwerf-Container, 'select 1' gegen ${DB_HOST}:${DB_PORT}/${DB_NAME} ..."
      if MYSQL_PWD="$SV_DB_PASSWORD" docker run --rm "${net_args[@]+"${net_args[@]}"}" -e MYSQL_PWD mariadb:12.3 \
          mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -N -e 'select 1' "$DB_NAME" >/dev/null 2>&1; then
        say "Datenbank erreichbar, Anmeldung erfolgreich."
      else
        warn "Datenbank nicht erreichbar oder Anmeldung fehlgeschlagen (Host, Port, Benutzer, Passwort, Datenbank, Firewall)."
        CHECK_FAILED=1
      fi
    else
      say "Datenbank: Passwort liegt nur im vorhandenen Secret vor, Anmeldetest übersprungen."
    fi
    code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$S3_ENDPOINT" 2>/dev/null || true)"
    if [ -z "$code" ] || [ "$code" = 000 ]; then
      warn "S3-Endpunkt ${S3_ENDPOINT} von diesem Host aus nicht erreichbar (DNS, Port, TLS)."
      CHECK_FAILED=1
    else
      say "S3-Endpunkt antwortet (HTTP $code, von diesem Host aus; Schlüssel werden hier nicht geprüft)."
      bcode="$(curl -sS -o /dev/null -m 10 -I -w '%{http_code}' "${S3_ENDPOINT%/}/${S3_BUCKET}" 2>/dev/null || true)"
      case "$bcode" in
        404) warn "Bucket '${S3_BUCKET}' scheint nicht zu existieren (HTTP 404, Path-Style-Prüfung); vor dem Start anlegen." ;;
        *) say "Bucket-Prüfung (HEAD ${S3_ENDPOINT%/}/${S3_BUCKET}): HTTP ${bcode:-?}." ;;
      esac
    fi
    if [ "$CHECK_FAILED" = 1 ]; then
      if [ "$NONINTERACTIVE" = 1 ]; then die "Verbindungsprüfung fehlgeschlagen (mit --skip-checks überspringbar)"; fi
      confirm "Trotzdem fortfahren?" n || die "abgebrochen"
    fi
  fi
fi

# ---------------------------------------------------------------- Step 9: summary and confirmation
step "Zusammenfassung"
if [ "$DRY" = 1 ]; then
  OUT_ENV="$(mktemp -d)/stack.env"
else
  OUT_ENV="$ENV_FILE"
fi
cat <<EOF
Stack:             $TODO_STACK
Image:             ${IMAGE_BASE}:${TODO_IMAGE_TAG}
Domain / RP_ID:    $PUBLIC_DOMAIN / $RP_ID
RP_ORIGIN:         $RP_ORIGIN
AASA_APP_IDS:      ${AASA_APP_IDS:-(leer: Endpunkt antwortet 404)}
Passwort-Login:    $PASSWORD_LOGIN_ENABLED
Port / Replikate:  $BACKEND_PORT / $BACKEND_REPLICAS (CPU-Limit $BACKEND_CPU_LIMIT, Speicher-Limit $BACKEND_MEMORY_LIMIT)
MariaDB:           $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME
S3:                $S3_ENDPOINT, Bucket $S3_BUCKET, Region $S3_REGION
Env-Datei:         $OUT_ENV (Modus 600)
EOF
for key in $SECRET_KEYS; do
  status="SS_$key"
  case "${!status}" in
    exists) st="vorhanden, bleibt unverändert" ;;
    *) st="wird angelegt"
       if [ "$key" = BOOTSTRAP_TOKEN ] && [ "$GENERATED_TOKEN" = 1 ]; then st="$st (zufällig erzeugt, wird einmal angezeigt)"; fi ;;
  esac
  printf 'Secret %-28s %s\n' "$(secret_name "$key")" "$st"
done
echo "Danach: Migration (scripts/swarm-deploy.sh), Rolling Update, Health- und AASA-Prüfung."
echo "Sichern Sie vor einem Update einer bestehenden Installation die Datenbank (scripts/backup-db.sh)."
if [ "$DRY" = 0 ] && [ "$YES" = 0 ] && [ "$NONINTERACTIVE" = 0 ]; then
  confirm "Mit diesen Einstellungen fortfahren?" n || die "abgebrochen; es wurde nichts geändert"
fi

# ---------------------------------------------------------------- Step 10: env file
step "Env-Datei schreiben"
write_env() {
  local target="$1" tmp
  mkdir -p "$(dirname "$target")"
  tmp="$(umask 077; mktemp "${target}.XXXXXX")"
  {
    echo "# Generated by deploy/swarm/setup.sh. No secret values in this file."
    echo "# Used by deploy/swarm/update.sh and scripts/swarm-deploy.sh. Re-run setup.sh --reconfigure to change values."
    echo "TODO_STACK=$TODO_STACK"
    echo "TODO_IMAGE_TAG=$TODO_IMAGE_TAG"
    echo "PUBLIC_DOMAIN=$PUBLIC_DOMAIN"
    echo "RP_ID=$RP_ID"
    echo "RP_ORIGIN=$RP_ORIGIN"
    echo "AASA_APP_IDS=$AASA_APP_IDS"
    echo "PASSWORD_LOGIN_ENABLED=$PASSWORD_LOGIN_ENABLED"
    echo "BACKEND_PORT=$BACKEND_PORT"
    echo "BACKEND_REPLICAS=$BACKEND_REPLICAS"
    echo "BACKEND_CPU_LIMIT=$BACKEND_CPU_LIMIT"
    echo "BACKEND_MEMORY_LIMIT=$BACKEND_MEMORY_LIMIT"
    echo "DB_HOST=$DB_HOST"
    echo "DB_PORT=$DB_PORT"
    echo "DB_NAME=$DB_NAME"
    echo "DB_USER=$DB_USER"
    echo "DB_PASSWORD_SECRET=$DB_PASSWORD_SECRET"
    echo "S3_ENDPOINT=$S3_ENDPOINT"
    echo "S3_BUCKET=$S3_BUCKET"
    echo "S3_REGION=$S3_REGION"
    echo "S3_ACCESS_KEY_SECRET=$S3_ACCESS_KEY_SECRET"
    echo "S3_SECRET_KEY_SECRET=$S3_SECRET_KEY_SECRET"
    echo "BOOTSTRAP_TOKEN_SECRET=$BOOTSTRAP_TOKEN_SECRET"
  } > "$tmp"
  chmod 600 "$tmp"
  if [ -f "$target" ]; then
    if cmp -s "$tmp" "$target"; then rm -f "$tmp"; say "Env-Datei unverändert: $target"; return; fi
    cp -p "$target" "${target}.bak"; chmod 600 "${target}.bak"
    say "Vorherige Version gesichert als ${target}.bak"
  fi
  mv "$tmp" "$target"; chmod 600 "$target"
  say "Env-Datei geschrieben: $target (Modus 600)"
}
write_env "$OUT_ENV"

if [ "$DRY" = 1 ]; then
  step "Trockenlauf: geplante Aktionen"
  for key in $SECRET_KEYS; do
    status="SS_$key"
    [ "${!status}" = exists ] || echo "  docker secret create $(secret_name "$key") -   (Wert nicht angezeigt)"
  done
  echo "  scripts/swarm-deploy.sh   (STACK=$TODO_STACK, Migration, danach Rollout mit $BACKEND_REPLICAS Replikaten)"
  echo "  Rollout abwarten, GET $RP_ORIGIN/health/ready und /.well-known/apple-app-site-association prüfen"
  say "Trockenlauf beendet; es wurden keine Docker-Aufrufe ausgeführt."
  exit 0
fi

# ---------------------------------------------------------------- Step 11: create secrets
step "Secrets anlegen"
for key in $SECRET_KEYS; do
  name="$(secret_name "$key")"
  status="SS_$key"; value="SV_$key"
  if [ "${!status}" = exists ]; then continue; fi
  if secret_exists "$name"; then say "Secret '$name' wurde inzwischen angelegt, unverändert gelassen."; continue; fi
  printf '%s' "${!value}" | docker secret create "$name" - >/dev/null
  say "Secret '$name' angelegt."
done
if [ "$GENERATED_TOKEN" = 1 ]; then
  cat <<EOF

  ======================================================================
  BOOTSTRAP-TOKEN (wird nur jetzt einmal angezeigt, jetzt notieren):

      $SV_BOOTSTRAP_TOKEN

  Es steht danach nur noch im Swarm-Secret '$BOOTSTRAP_TOKEN_SECRET'.
  ======================================================================
EOF
fi
for key in $SECRET_KEYS; do printf -v "SV_$key" '%s' ''; done

if [ "$NO_DEPLOY" = 1 ]; then
  say "--no-deploy: Env-Datei und Secrets sind bereit. Deploy später mit: set -a; . $ENV_FILE; set +a; STACK=$TODO_STACK $REPO_ROOT/scripts/swarm-deploy.sh"
  exit 0
fi

# ---------------------------------------------------------------- Step 12: deploy
step "Deploy (Migration, dann Rollout)"
(
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  export STACK="$TODO_STACK"
  "$REPO_ROOT/scripts/swarm-deploy.sh"
)
step "Rollout abwarten"
wait_for_rollout "${TODO_STACK}_backend" 600
docker service ps "${TODO_STACK}_backend" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'

# ---------------------------------------------------------------- Step 13: verify
step "Prüfung: Health und AASA"
HEALTH_OK=0
VERIFY_BASE=""
http_get() { # url -> "code" and body in $BODY_FILE; never follows redirects
  curl -sS -m 5 -o "$BODY_FILE" -w '%{http_code}' "$1" 2>/dev/null || echo 000
}
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
LOCAL_URL="http://127.0.0.1:${BACKEND_PORT}"
for base in "$RP_ORIGIN" "$LOCAL_URL"; do
  ok=0
  tries=6; [ "$base" != "$RP_ORIGIN" ] || tries=3
  for ((n = 0; n < tries; n++)); do
    if [ "$(http_get "$base/health/ready")" = 200 ]; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" = 1 ]; then
    say "GET $base/health/ready -> 200"
    HEALTH_OK=1; VERIFY_BASE="$base"
    [ "$base" = "$RP_ORIGIN" ] || warn "über die öffentliche Domain nicht erreichbar, nur über den Ingress-Port des Knotens: DNS, TLS und Reverse Proxy prüfen."
    break
  fi
  warn "GET $base/health/ready nicht erfolgreich"
done
if [ "$HEALTH_OK" = 1 ]; then
  code="$(http_get "$VERIFY_BASE/.well-known/apple-app-site-association")"
  if [ -n "$AASA_APP_IDS" ]; then
    if [ "$code" = 200 ] && grep -q webcredentials "$BODY_FILE"; then
      say "AASA: 200 mit webcredentials (${VERIFY_BASE})."
    else
      warn "AASA erwartet 200 mit webcredentials, erhielt HTTP $code (Redirects des Proxys auf diesem Pfad verbieten)."
    fi
  elif [ "$code" = 404 ]; then
    say "AASA: 404, wie ohne AASA_APP_IDS erwartet."
  else
    warn "AASA: unerwartet HTTP $code"
  fi
else
  # Last resort (e.g. VM-based Docker hosts without port forwarding): ask a local replica from the inside.
  cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${TODO_STACK}_backend" | head -n 1)"
  if [ -n "$cid" ]; then
    # shellcheck disable=SC2016
    probe='req() { exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET $1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3; cat <&3; exec 3>&-; }; req "$1"'
    if docker exec "$cid" /bin/bash -c "$probe" _ /health/ready 2>/dev/null | head -n 1 | grep -q ' 200 '; then
      HEALTH_OK=1
      warn "nur von innen geprüft (Replikat $cid: /health/ready = 200); Domain und Ingress-Port von außen selbst prüfen."
      aasa="$(docker exec "$cid" /bin/bash -c "$probe" _ /.well-known/apple-app-site-association 2>/dev/null | tr -d '\r' || true)"
      acode="$(printf '%s' "$aasa" | head -n 1 | awk '{print $2}')"
      if [ -n "$AASA_APP_IDS" ]; then
        if [ "$acode" = 200 ] && printf '%s' "$aasa" | grep -q webcredentials; then say "AASA (von innen): 200 mit webcredentials."
        else warn "AASA (von innen): erwartet 200 mit webcredentials, erhielt HTTP ${acode:-?}."; fi
      elif [ "$acode" = 404 ]; then say "AASA (von innen): 404, wie ohne AASA_APP_IDS erwartet."
      else warn "AASA (von innen): unerwartet HTTP ${acode:-?}"; fi
    fi
  fi
fi

echo
echo "Nächste Schritte"
echo "  1. App öffnen: $RP_ORIGIN"
echo "  2. Erstes Administrator-Konto mit Passkey registrieren und das Bootstrap-Token eingeben"
echo "     (Secret '$BOOTSTRAP_TOKEN_SECRET'). Danach ist das Token wirkungslos; das Secret wird vom Stack noch"
echo "     referenziert und bleibt bestehen."
echo "  3. Reverse Proxy/TLS auf Port $BACKEND_PORT der Swarm-Knoten zeigen lassen; /.well-known/ ohne Redirect durchreichen."
echo "  4. Backups einrichten: scripts/backup-db.sh (Datenbank) und Bucket-Sicherung (docs/BETRIEB.md)."
echo "  5. Updates: deploy/swarm/update.sh --env-file $ENV_FILE"
[ "$SWARM_CREATED" = 0 ] || echo "  Hinweis: Dieses Skript hat den Swarm initialisiert ('docker swarm leave --force' macht das rückgängig)."
if [ "$HEALTH_OK" = 0 ]; then
  echo "Health-Prüfung nicht erfolgreich: docker service ps ${TODO_STACK}_backend; docker service logs ${TODO_STACK}_backend" >&2
  exit 2
fi
say "Fertig nach $(elapsed)."
