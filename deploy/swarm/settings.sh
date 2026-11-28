#!/usr/bin/env bash
# Einstellungen der Todolino-Env-Datei (stack.env) per Menü (whiptail/dialog) oder Kommandozeile bearbeiten.
#
# Aufruf: deploy/swarm/settings.sh [Optionen]
#   (ohne Aktion)     Menü starten (braucht whiptail oder dialog)
#   --env PFAD        Env-Datei (Standard: deploy/swarm/stack.env)
#   --list            alle Variablen mit Wert, Default und Quelle
#   --get KEY         Wert einer Variablen ausgeben (Geheimnisse nie)
#   --set KEY=VALUE   Wert prüfen und speichern (mit Sicherung); mehrfach möglich
#   --unset KEY       Variable aus der Datei nehmen (zurück auf den Default); mehrfach möglich
#   --info KEY        ausführliche Erklärung einer Variablen
#   --generate KEY    nur SETTINGS_ENCRYPTION_KEY: legt das Swarm-Secret mit einem Zufallsschlüssel an, wenn es fehlt, und setzt
#                     SETTINGS_KEY_ENABLED=true (ein vorhandenes Secret bleibt unverändert; der Wert wird nie angezeigt)
#   --check           gesamte Datei prüfen (Typ, Grenzen, Konflikte, unbekannte Variablen, Geheimnisse)
#   -h, --help        diese Hilfe
#
# Metadaten: config-registry.tsv (aus SettingsRegistry erzeugt, SettingsRegistryTSVTests), config-extra.tsv (Deploy-Variablen,
# die der Server nicht liest), config-help.tsv (ausführliche Erklärungen, optional) und die Vorlage stack.env.example (Vorlagenwerte
# sind der Default der Deploy-Variablen; Standardwerte der Server-Einstellungen stehen im Programm und kommen aus dem Register).
# Geheimnisse (DB-Passwort, Bootstrap-Token, Konfigurationsschlüssel, SMTP-/APNs-/S3-Werte) werden nie angezeigt und nie in die
# Datei geschrieben. Gespeichert wird atomar (temporäre Datei im selben Verzeichnis, dann mv) mit Modus 0600; vorher entsteht eine
# Sicherung <Datei>.bak.JJJJMMTT-HHMMSS. Ausgerollt wird nur im Menü ("Anwenden") nach Bestätigung (update.sh);
# --set, --unset und --generate rollen nie aus.

set -euo pipefail

# Test-Hook SETTINGS_TEST_BASH_VERSION: simuliert eine andere Bash-Version, um die Prüfung testen zu können.
BASH_VER="${SETTINGS_TEST_BASH_VERSION:-$BASH_VERSION}"
BASH_MAJOR="${BASH_VER%%.*}"; BASH_REST="${BASH_VER#*.}"; BASH_MINOR="${BASH_REST%%[!0-9]*}"
if [ "$BASH_MAJOR" -lt 4 ] || { [ "$BASH_MAJOR" -eq 4 ] && [ "${BASH_MINOR:-0}" -lt 4 ]; }; then
  echo "settings.sh braucht Bash 4.4 oder neuer (gefunden: ${BASH_VER}). macOS liefert Bash 3.2 (brew install bash); auf dem Server (Linux) ist Bash 5 üblich." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/stack.env.example"
DEFAULT_ENV="$SCRIPT_DIR/stack.env"
TSV_REGISTRY="${SETTINGS_REGISTRY:-$SCRIPT_DIR/config-registry.tsv}"
TSV_EXTRA="${SETTINGS_EXTRA:-$SCRIPT_DIR/config-extra.tsv}"
TSV_HELP="${SETTINGS_HELP:-$SCRIPT_DIR/config-help.tsv}"
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
ENV_FILE=""
BACKTITLE="Todolino (Swarm): Einstellungen"
# Geheimnisse, die nie in der Datei stehen dürfen (Tabellen-Einträge mit secret=1 kommen dazu).
SECRET_ENV_KEYS=" DB_PASSWORD BOOTSTRAP_TOKEN SETTINGS_ENCRYPTION_KEY SETTINGS_KEY "
# Stack-Standard der Image-Variable (stack.yaml), wenn die Datei keinen Tag nennt.
STACK_DEFAULT_TAG=edge

die() { echo "Fehler: $*" >&2; exit 1; }

# ---------------------------------------------------------------- Tabellen und Vorlage
declare -a KEYS=()
declare -A T_GROUP=() T_TYPE=() T_DEF=() T_UNIT=() T_MIN=() T_MAX=() T_CHOICES=() T_APPLY=() T_SECRET=() T_SUM=() T_ORIGIN=()
declare -A TPL_VAL=() T_HELP=()

load_help() { # optionale Datei key<TAB>Text; "\n" im Text = Zeilenumbruch
  local k t
  [ -r "$TSV_HELP" ] || return 0
  while IFS=$'\x1f' read -r k t; do
    [ -n "$k" ] || continue
    T_HELP[$k]="${t//\\n/$'\n'}"
  done < <(awk -F'\t' -v OFS='\037' '!/^#/ && NF >= 2 { print $1, $2 }' "$TSV_HELP")
  return 0
}

load_table() { # Datei Herkunft(registry|extra)
  local f="$1" origin="$2" k g ty d u mn mx ch ap se sm
  [ -r "$f" ] || die "Tabelle fehlt: $f"
  # Unit Separator als Trenner: Tabulatoren würden leere Felder zusammenziehen.
  while IFS=$'\x1f' read -r k g ty d u mn mx ch ap se sm; do
    [ -n "$k" ] || continue
    if [ -n "${T_GROUP[$k]+x}" ]; then continue; fi
    T_GROUP[$k]="$g"; T_TYPE[$k]="$ty"; T_DEF[$k]="$d"; T_UNIT[$k]="$u"; T_MIN[$k]="$mn"; T_MAX[$k]="$mx"
    T_CHOICES[$k]="$ch"; T_APPLY[$k]="$ap"; T_SECRET[$k]="$se"; T_SUM[$k]="$sm"; T_ORIGIN[$k]="$origin"
    KEYS+=("$k")
  done < <(awk -F'\t' -v OFS='\037' '!/^#/ && NF >= 11 { $1 = $1; print }' "$f")
  return 0
}

load_template() { # aktive Zeilen liefern den Vorlagenwert (Default der Deploy-Variablen); Kommentarzeilen nennen nur den Namen
  local line key val
  [ -r "$TEMPLATE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ $line =~ ^(#\ ?)?([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
      if [ -z "${BASH_REMATCH[1]}" ]; then
        case "$val" in \"*\"|\'*\') val="${val:1:${#val}-2}" ;; esac
        TPL_VAL[$key]="$val"
      fi
    fi
  done < "$TEMPLATE"
  return 0
}

load_tables() {
  load_table "$TSV_REGISTRY" registry
  load_table "$TSV_EXTRA" extra
  load_help
  load_template
}

# Server-Einstellungen: der Standard steht im Programm (Register). Deploy-Variablen: der Wert der Vorlage, sonst der Tabellenwert.
default_of() {
  if [ "${T_ORIGIN[$1]:-}" = extra ] && [ -n "${TPL_VAL[$1]+x}" ]; then printf '%s' "${TPL_VAL[$1]}"
  else printf '%s' "${T_DEF[$1]-}"; fi
}

is_secretlike() { # Tabelle entscheidet; unbekannte Namen mit PASSWORD/KEY/SECRET/TOKEN gelten vorsichtshalber als Geheimnis
  local k="$1" up
  if [ -n "${T_SECRET[$k]+x}" ]; then [ "${T_SECRET[$k]}" = 1 ]; return; fi
  [[ $SECRET_ENV_KEYS == *" $k "* ]] && return 0
  up="${k^^}"
  [[ $up == *_FILE ]] && return 1
  [[ $up == *PASSWORD* || $up == *PASSWD* || $up == *SECRET* || $up == *KEY* || $up == *TOKEN* || $up == *CREDENTIAL* ]]
}
is_known() { [ -n "${T_GROUP[$1]+x}" ]; }

apply_label() {
  case "${T_APPLY[$1]}" in
    live) echo "live" ;;
    restart) echo "Neustart" ;;
    *) echo "nur ENV" ;;
  esac
}
effect_text() {
  case "${T_APPLY[$1]}" in
    live) echo "live: auch in der PWA änderbar; ein Wert in der Datei hat Vorrang und sperrt dort das Feld; wirkt nach dem nächsten Rollout" ;;
    restart) echo "Neustart: wird beim Start gelesen (auch in der PWA änderbar); ein Wert in der Datei sperrt dort das Feld; wirkt nach dem nächsten Rollout" ;;
    *) echo "nur ENV: nur über die Datei, wirkt nach dem nächsten Rollout" ;;
  esac
}

# Name des Swarm-Secrets, aus dem ein Geheimnis stammt (für Hinweise).
secret_ref() { # KEY -> Variable, die den Secret-Namen trägt
  case "$1" in
    SMTP_PASSWORD) echo SMTP_PASSWORD_SECRET ;; APNS_KEY) echo APNS_KEY_SECRET ;;
    S3_ACCESS_KEY) echo S3_ACCESS_KEY_SECRET ;; S3_SECRET_KEY) echo S3_SECRET_KEY_SECRET ;;
    DB_PASSWORD) echo DB_PASSWORD_SECRET ;; BOOTSTRAP_TOKEN) echo BOOTSTRAP_TOKEN_SECRET ;;
    SETTINGS_ENCRYPTION_KEY|SETTINGS_KEY) echo SETTINGS_KEY_SECRET ;;
    GITHUB_APP_PRIVATE_KEY) echo GITHUB_APP_KEY_SECRET ;;
    GITHUB_APP_CLIENT_SECRET) echo GITHUB_APP_CLIENT_SECRET_SECRET ;;
    *) echo "" ;;
  esac
}
secret_hint() {
  local k="$1" ref name
  ref="$(secret_ref "$k")"
  printf '%s ist ein Geheimnis und steht nie in der Env-Datei.\n\n' "$k"
  if [ "$k" = SETTINGS_ENCRYPTION_KEY ] || [ "$k" = SETTINGS_KEY ]; then
    printf 'Den Konfigurationsschlüssel legt settings.sh --generate SETTINGS_ENCRYPTION_KEY an (Menü: Schluessel). Er entsteht zufällig als Swarm-Secret und wird nie angezeigt.'
  elif [ -n "$ref" ]; then
    name="$(eff_value "$ref")"
    printf 'Quelle ist das Swarm-Secret "%s": docker secret create %s -   (Wert über stdin, nie als Argument).\nEin Secret lässt sich nicht ändern: zum Ersetzen unter neuem Namen anlegen (%s) und ausrollen.' "$name" "$name" "$ref"
    case "$k" in SMTP_PASSWORD|APNS_KEY|S3_ACCESS_KEY|S3_SECRET_KEY)
      printf '\nAlternativ kann ein Administrator den Wert in der PWA eintragen (braucht den Konfigurationsschlüssel).' ;;
    esac
  else
    printf 'Geheimnisse gehören in ein Swarm-Secret, nicht in diese Datei.'
  fi
}

# ---------------------------------------------------------------- Env-Datei lesen
declare -a ENV_LINES=()
declare -A ENV_VAL=() ENV_COUNT=() ENV_BAD=()
declare -a ENV_BADLINES=()
declare -A PEND_SET=() PEND_UNSET=()
ENV_EXISTS=0

# Wie update.sh und setup.sh: nur ein umschließendes Anführungszeichenpaar wird entfernt, nichts wird expandiert.
env_load() {
  local line key value n=0
  ENV_LINES=(); ENV_VAL=(); ENV_COUNT=(); ENV_BAD=(); ENV_BADLINES=(); ENV_EXISTS=0
  [ -f "$ENV_FILE" ] || return 0
  ENV_EXISTS=1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; n=$((n + 1))
    ENV_LINES+=("$line")
    case "$line" in ''|'#'*) continue ;; esac
    if [[ $line != *=* ]]; then ENV_BADLINES+=("Zeile $n: KEY=VALUE erwartet"); continue; fi
    key="${line%%=*}"; value="${line#*=}"
    if ! [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]]; then ENV_BADLINES+=("Zeile $n: ungültiger Variablenname"); continue; fi
    case "$value" in \"*\"|\'*\') value="${value:1:${#value}-2}" ;; esac
    ENV_VAL[$key]="$value"
    ENV_COUNT[$key]=$(( ${ENV_COUNT[$key]:-0} + 1 ))
    if [[ $value == *'$'* || $value == *'`'* || $value == *\\* ]]; then ENV_BAD[$key]="enthält \$, Backtick oder Backslash (update.sh liest die Datei mit source)"
    else unset 'ENV_BAD[$key]'; fi
  done < "$ENV_FILE"
  return 0
}

# Wert so schreiben, dass source und setup.sh ihn unverändert lesen: ohne Anführungszeichen, wenn das gefahrlos geht.
quote_value() {
  if [[ $1 =~ ^[A-Za-z0-9_./:@,+%=-]*$ ]]; then printf '%s' "$1"
  elif [[ $1 == *'"'* ]]; then printf "'%s'" "$1"
  else printf '"%s"' "$1"; fi
}

# ---------------------------------------------------------------- wirksamer Zustand (Datei + offene Änderungen)
in_file() { [ -n "${ENV_COUNT[$1]+x}" ]; }
is_set() {
  if [ -n "${PEND_UNSET[$1]+x}" ]; then return 1; fi
  if [ -n "${PEND_SET[$1]+x}" ]; then return 0; fi
  in_file "$1"
}
eff_value() {
  local k="$1"
  if [ -n "${PEND_UNSET[$k]+x}" ]; then default_of "$k"
  elif [ -n "${PEND_SET[$k]+x}" ]; then printf '%s' "${PEND_SET[$k]}"
  elif in_file "$k"; then printf '%s' "${ENV_VAL[$k]}"
  else default_of "$k"; fi
}
file_val() { # Wert nur, wenn die Datei (oder eine offene Änderung) ihn setzt; Defaults zählen nicht (für Konfliktprüfungen)
  local k="$1"
  if [ -n "${PEND_UNSET[$k]+x}" ]; then return 0; fi
  if [ -n "${PEND_SET[$k]+x}" ]; then printf '%s' "${PEND_SET[$k]}"
  elif in_file "$k"; then printf '%s' "${ENV_VAL[$k]}"; fi
  return 0
}
queue_set() { # KEY WERT (bereits geprüft)
  unset 'PEND_UNSET[$1]'
  if [ -z "${PEND_SET[$1]+x}" ] && in_file "$1" && [ "${ENV_VAL[$1]}" = "$2" ] && [ "${ENV_COUNT[$1]}" = 1 ]; then return 0; fi
  PEND_SET[$1]="$2"
  return 0
}
queue_unset() {
  unset 'PEND_SET[$1]'
  if in_file "$1"; then PEND_UNSET[$1]=1; fi
  return 0
}
pending_count() { echo $(( ${#PEND_SET[@]} + ${#PEND_UNSET[@]} )); }

# ---------------------------------------------------------------- Validierung
V_ERR=""

mailbox_ok() {
  local v="$1" local_part domain label
  [ "${#v}" -le 254 ] || return 1
  [[ $v =~ ^[A-Za-z0-9._%+!-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || return 1
  local_part="${v%@*}"; domain="${v#*@}"
  [ "${#local_part}" -le 64 ] && [[ $local_part != .* && $local_part != *. && $local_part != *..* ]] || return 1
  local IFS=.
  for label in $domain; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] && [[ $label != -* && $label != *- ]] || return 1
  done
  return 0
}

validate_text() { # KEY WERT REGEL; Rückgabe 0 = gültig, sonst V_ERR
  local val="$2" rule="$3"
  case "$rule" in
    free) ;;
    hostaddr) [[ $val =~ ^[A-Za-z0-9.:_-]+$ && $val != -* ]] || { V_ERR="Hostname oder IP-Adresse (Buchstaben, Ziffern, . : _ -)"; return 1; } ;;
    dbhost) [[ $val =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]] || { V_ERR="Hostname oder IP-Adresse des DB-Servers"; return 1; } ;;
    dbuser) [[ $val =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$ ]] || { V_ERR="Buchstabe am Anfang, dann Buchstaben, Ziffern, _ . - (höchstens 64 Zeichen)"; return 1; } ;;
    dbident) [[ $val =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]] || { V_ERR="Buchstabe am Anfang, dann Buchstaben, Ziffern, _ (höchstens 64 Zeichen)"; return 1; } ;;
    mailbox) mailbox_ok "$val" || { V_ERR="gültige E-Mail-Adresse erwartet"; return 1; } ;;
    appleid) [[ $val =~ ^[A-Z0-9]{10}$ ]] || { V_ERR="genau 10 Zeichen A-Z und 0-9"; return 1; } ;;
    list) [[ $val =~ ^[A-Za-z0-9._-]+([[:space:]]*,[[:space:]]*[A-Za-z0-9._-]+)*$ ]] || { V_ERR="kommagetrennte Liste ohne leere Einträge (Buchstaben, Ziffern, . _ -)"; return 1; } ;;
    httpurl) [[ $val =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]?#@]*)?$ ]] || { V_ERR="http(s)-Adresse ohne Zugangsdaten, Query und Fragment"; return 1; } ;;
    origin) [[ $val =~ ^https://[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?$ || $val =~ ^http://localhost(:[0-9]{1,5})?$ ]] \
              || { V_ERR="https://host[:port] in Kleinbuchstaben, ohne Pfad (http nur für localhost)"; return 1; } ;;
    host) [[ $val =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { V_ERR="Hostname in Kleinbuchstaben, ohne Schema und Port"; return 1; } ;;
    stackname) [[ $val =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { V_ERR="Kleinbuchstaben, Ziffern, Bindestrich; beginnt mit Buchstabe; höchstens 31 Zeichen"; return 1; } ;;
    imagetag) [[ $val =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { V_ERR="ungültiges Image-Tag"; return 1; } ;;
    memlimit) [[ $val =~ ^[0-9]+(\.[0-9]+)?[bBkKmMgG]?$ ]] || { V_ERR="Zahl mit optionaler Einheit, z. B. 512M"; return 1; } ;;
    secretname) [[ $val =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || { V_ERR="Name eines Swarm-Secrets: Buchstaben, Ziffern, _ . - (höchstens 64 Zeichen)"; return 1; } ;;
    *) V_ERR="unbekannte Regel '$rule' in der Tabelle"; return 1 ;;
  esac
  return 0
}

# Prüft einen Wert gegen die Tabelle; Rückgabe 0 = gültig. Leer ist gültig, wenn der Default leer ist oder die Regel auf ? endet.
validate() { # KEY WERT
  local key="$1" val="$2" type base rule="" lo hi n opt=0 def
  type="${T_TYPE[$key]}"; base="${type%%:*}"; [[ $type == *:* ]] && rule="${type#*:}"
  if [[ $rule == *\? ]]; then rule="${rule%\?}"; opt=1; fi
  lo="${T_MIN[$key]}"; hi="${T_MAX[$key]}"; def="$(default_of "$key")"
  V_ERR=""
  if [[ $val =~ [[:cntrl:]] ]]; then V_ERR="Steuerzeichen und Zeilenumbrüche sind nicht erlaubt"; return 1; fi
  if [[ $val == *'$'* || $val == *'`'* || $val == *\\* ]]; then V_ERR="\$, Backtick und Backslash sind nicht erlaubt (update.sh liest die Datei mit source)"; return 1; fi
  if [[ $val == *'"'* && $val == *"'"* ]]; then V_ERR="gemischte Anführungszeichen (\" und ') werden nicht unterstützt"; return 1; fi
  if [ "$base" = secret ]; then V_ERR="Geheimnisse gehören nicht in die Datei"; return 1; fi
  if [ -z "$val" ]; then
    if [ -z "$def" ] || [ "$opt" = 1 ]; then return 0; fi
    V_ERR="leerer Wert nicht erlaubt (Default: $def); zum Zurücksetzen --unset verwenden"; return 1
  fi
  case "$base" in
    int)
      [[ $val =~ ^(0|[1-9][0-9]{0,11})$ ]] || { V_ERR="muss eine ganze Zahl sein (ohne führende Nullen)"; return 1; }
      n=$((10#$val))
      if [ "$n" -lt "$lo" ] || [ "$n" -gt "$hi" ]; then V_ERR="muss zwischen $lo und $hi liegen"; return 1; fi ;;
    number)
      [[ $val =~ ^[0-9]{1,9}(\.[0-9]{1,6})?$ ]] || { V_ERR="muss eine Zahl sein (Dezimalpunkt)"; return 1; }
      awk -v v="$val" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }' \
        || { V_ERR="muss zwischen $lo und $hi liegen"; return 1; } ;;
    bool) [ "$val" = true ] || [ "$val" = false ] || { V_ERR="muss true oder false sein (Kleinbuchstaben)"; return 1; } ;;
    choice) [[ "|${T_CHOICES[$key]}|" == *"|$val|"* ]] || { V_ERR="erlaubt: ${T_CHOICES[$key]//|/, }"; return 1; } ;;
    text)
      [ "${#val}" -le "$hi" ] || { V_ERR="höchstens $hi Zeichen"; return 1; }
      validate_text "$key" "$val" "$rule" || return 1 ;;
    *) V_ERR="unbekannter Typ '$type' in der Tabelle"; return 1 ;;
  esac
  return 0
}

describe_type() {
  local k="$1" t="${T_TYPE[$1]}" base="${T_TYPE[$1]%%:*}" r="" u="${T_UNIT[$1]}"
  [[ $t == *:* ]] && r="${t#*:}"
  local opt=""; [[ $r == *\? ]] && { r="${r%\?}"; opt=", leer erlaubt"; }
  case "$base" in
    int) echo "Ganzzahl ${T_MIN[$k]} bis ${T_MAX[$k]}${u:+ $u}${opt}" ;;
    number) echo "Zahl ${T_MIN[$k]} bis ${T_MAX[$k]}${u:+ $u}" ;;
    bool) echo "true oder false" ;;
    choice) echo "Auswahl: ${T_CHOICES[$k]//|/, }" ;;
    secret) echo "Geheimnis (nie in der Datei)" ;;
    text) echo "Text (${r:-free}), höchstens ${T_MAX[$k]} Zeichen$opt" ;;
    *) echo "$base" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- Prüfung der gesamten Datei
declare -a CHK_ERR=() CHK_WARN=() CHK_NOTE=()
chk_err() { CHK_ERR+=("$*"); }
chk_warn() { CHK_WARN+=("$*"); }
chk_note() { CHK_NOTE+=("$*"); }

# Autoritative Prüfung der Platzierung: dieselbe Funktion wie scripts/swarm-deploy.sh (placement.sh), in sauberer Umgebung und nur mit
# den Werten aus der Datei (die Datei selbst wird nie ausgeführt). Gibt die erste Fehlermeldung aus.
placement_check() {
  local v msg; local -a vars=()
  [ -r "$SCRIPT_DIR/placement.sh" ] || return 0
  for v in PLACEMENT_CONSTRAINTS PLACEMENT_PREFERENCES EXCLUDE_LABEL PINNED_NODE PINNED_REPLICAS BACKEND_PINNED_PORT BACKEND_PORT; do
    [ -z "$(file_val "$v")" ] || vars+=("$v=$(file_val "$v")")
  done
  # shellcheck disable=SC2016  # $1 gehört zum -c Skript, nicht zu dieser Shell
  msg="$(env -i PATH="$PATH" ${vars[@]+"${vars[@]}"} "$BASH" -c '. "$1"; placement_prepare /dev/null' _ "$SCRIPT_DIR/placement.sh" 2>&1 >/dev/null </dev/null)" || true
  msg="${msg#placement: }"
  [ -z "$msg" ] || printf '%s' "${msg%%$'\n'*}"
  return 0
}

check_all() {
  CHK_ERR=(); CHK_WARN=(); CHK_NOTE=()
  local k v mode line missing host
  if [ "$ENV_EXISTS" = 0 ]; then
    chk_warn "Datei $ENV_FILE existiert noch nicht; zuerst setup.sh ausführen. Es gelten die Vorlagen- und Standardwerte."
  else
    if [ -L "$ENV_FILE" ]; then chk_err "Env-Datei darf kein Symlink sein (Speichern lehnt das ab)."; fi
    mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '')"
    if [ -n "$mode" ] && [ "$mode" != 600 ]; then chk_warn "Dateimodus ist $mode, erwartet 600 (Speichern setzt 600)."; fi
  fi
  for line in ${ENV_BADLINES[@]+"${ENV_BADLINES[@]}"}; do chk_err "$line"; done
  for k in $(printf '%s\n' ${ENV_VAL[@]+"${!ENV_VAL[@]}"} | sort); do
    [ -n "$k" ] || continue
    v="${ENV_VAL[$k]}"
    if [ -n "${PEND_SET[$k]+x}" ]; then v="${PEND_SET[$k]}"; fi
    if [ -n "${PEND_UNSET[$k]+x}" ]; then continue; fi
    if [ "${ENV_COUNT[$k]}" -gt 1 ]; then chk_warn "$k steht ${ENV_COUNT[$k]}-mal in der Datei; der letzte Wert gilt."; fi
    if [ -n "${ENV_BAD[$k]+x}" ] && [ -z "${PEND_SET[$k]+x}" ]; then chk_err "$k: ${ENV_BAD[$k]}."; fi
    if is_secretlike "$k" && { is_known "$k" || [[ $SECRET_ENV_KEYS == *" $k "* ]]; }; then
      if [ -n "$v" ]; then chk_err "$k: Geheimnis in der Datei. Entfernen (--unset $k); die Quelle ist ein Swarm-Secret."
      else chk_warn "$k: gehört nicht in die Datei (leer, wird ignoriert)."; fi
      continue
    fi
    if ! is_known "$k"; then
      if is_secretlike "$k"; then chk_err "$k: unbekannte Variable, der Name deutet auf ein Geheimnis. Entfernen (--unset $k)."
      else chk_warn "$k: unbekannte Variable (nicht in den Tabellen); die Stack-Dateien verwenden sie nicht."; fi
      continue
    fi
    if ! validate "$k" "$v"; then chk_err "$k: $V_ERR"; fi
  done

  # Konflikte: Basis ist der Zustand der Datei samt offenen Änderungen; Defaults zählen nicht.
  if [ "$ENV_EXISTS" = 1 ] && [ -z "$(file_val DB_HOST)" ]; then chk_err "DB_HOST fehlt (stack.yaml verlangt ihn)."; fi
  if [[ "$(file_val DB_HOST)" == *.example.internal ]]; then chk_warn "DB_HOST steht noch auf dem Platzhalter $(file_val DB_HOST)."; fi
  if [ "$(file_val MAIL_ENABLED)" = true ]; then
    missing=""
    for k in SMTP_HOST SMTP_USER MAIL_FROM; do [ -n "$(file_val "$k")" ] || missing+="${missing:+, }$k"; done
    [ -z "$missing" ] || chk_err "MAIL_ENABLED=true braucht SMTP_HOST, SMTP_USER und MAIL_FROM in der Datei (stack.mail.yaml); es fehlt: $missing."
    if [ -n "$(file_val SMTP_USER)" ] && { [ -z "$(file_val SMTP_PORT)" ] || [ -z "$(file_val SMTP_SECURITY)" ]; }; then
      chk_warn "SMTP_USER ist per Umgebung festgelegt: SMTP_PORT und SMTP_SECURITY ebenfalls festlegen, sonst meldet der Server einen Konfigurationsfehler, wenn dafür in der PWA etwas gespeichert ist."
    fi
  fi
  if [ "$(file_val APNS_ENABLED)" = true ]; then
    missing=""
    for k in APNS_KEY_ID APNS_TEAM_ID; do [ -n "$(file_val "$k")" ] || missing+="${missing:+, }$k"; done
    [ -z "$missing" ] || chk_err "APNS_ENABLED=true braucht APNS_KEY_ID und APNS_TEAM_ID in der Datei (stack.push.yaml); es fehlt: $missing."
  fi
  if [ "$(file_val GITHUB_APP_ENABLED)" = true ]; then
    missing=""
    for k in GITHUB_APP_ID GITHUB_APP_SLUG GITHUB_APP_CLIENT_ID; do [ -n "$(file_val "$k")" ] || missing+="${missing:+, }$k"; done
    [ -z "$missing" ] || chk_err "GITHUB_APP_ENABLED=true braucht GITHUB_APP_ID, GITHUB_APP_SLUG und GITHUB_APP_CLIENT_ID in der Datei (stack.github.yaml); es fehlt: $missing."
    if [ -n "$(file_val GITHUB_APP_INSTALLATION_ID)" ] && [ -z "$(file_val GITHUB_APP_REPOSITORIES)" ]; then old_pair=broken
    elif [ -z "$(file_val GITHUB_APP_INSTALLATION_ID)" ] && [ -n "$(file_val GITHUB_APP_REPOSITORIES)" ]; then old_pair=broken; else old_pair=ok; fi
    if [ "$old_pair" = broken ]; then
      chk_err "GITHUB_APP_INSTALLATION_ID und GITHUB_APP_REPOSITORIES gehören zusammen (nur Übergang); setze beide oder keines."
    fi
  fi
  if [ "$(file_val ATTACHMENT_STORAGE)" = s3 ] && [ -z "$(file_val S3_ENDPOINT)" ]; then
    chk_warn "ATTACHMENT_STORAGE=s3 ohne S3_ENDPOINT in der Datei: der Endpunkt muss dann in der PWA stehen, sonst startet der Server nicht."
  fi
  if [ -n "$(file_val S3_ENDPOINT)" ] && [ "$(file_val ATTACHMENT_STORAGE)" != s3 ]; then
    chk_note "S3_ENDPOINT bindet das S3-Overlay ein (nur Lesen/Migration vorhandener S3-Anhänge); neue Anhänge landen mit ATTACHMENT_STORAGE=s3 in S3."
  fi
  if [ -n "$(file_val SETTINGS_KEY_SECRET)" ] && [ "$(file_val SETTINGS_KEY_ENABLED)" != true ]; then
    chk_warn "SETTINGS_KEY_SECRET ist gesetzt, aber ohne SETTINGS_KEY_ENABLED=true wird das Overlay stack.settings.yaml nicht eingebunden."
  fi
  if [ -n "$(file_val SETTINGS_KEY_PREVIOUS_SECRET)" ]; then
    if [ "$(file_val SETTINGS_KEY_ENABLED)" != true ]; then
      chk_err "SETTINGS_KEY_PREVIOUS_SECRET braucht SETTINGS_KEY_ENABLED=true (der alte Schlüssel gilt nur neben dem aktuellen)."
    fi
    if [ "$(file_val SETTINGS_KEY_PREVIOUS_SECRET)" = "$(eff_value SETTINGS_KEY_SECRET)" ]; then
      chk_err "SETTINGS_KEY_PREVIOUS_SECRET und SETTINGS_KEY_SECRET nennen dasselbe Secret ($(eff_value SETTINGS_KEY_SECRET)); für die Rotation ein neues Secret anlegen."
    fi
  fi
  v="$(file_val RP_ORIGIN)"; k="$(file_val RP_ID)"
  if [[ $v =~ ^https?://([a-z0-9][a-z0-9.-]*)(:[0-9]{1,5})?$ ]]; then
    host="${BASH_REMATCH[1]}"
    if [ -n "$k" ] && [ "$host" != "$k" ] && [[ $host != *".$k" ]]; then
      chk_err "RP_ID ($k) muss die Domain des Hosts von RP_ORIGIN ($host) sein oder eine übergeordnete Domain."
    elif [ -z "$k" ] && [ "$host" != localhost ]; then
      chk_warn "RP_ORIGIN nennt $host, RP_ID fehlt (Standard localhost): Passkeys würden nicht funktionieren."
    fi
  fi
  if [ -n "$(file_val PINNED_REPLICAS)$(file_val BACKEND_PINNED_PORT)" ] && [ -z "$(file_val PINNED_NODE)" ]; then
    chk_note "PINNED_REPLICAS und BACKEND_PINNED_PORT wirken nur mit PINNED_NODE (ohne gibt es backend-pinned nicht)."
  fi
  v="$(placement_check)"
  [ -z "$v" ] || chk_err "Platzierung: $v"
  return 0
}

print_check() { # gibt Meldungen aus; Rückgabe 1 bei Fehlern
  local m
  for m in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do echo "FEHLER   $m"; done
  for m in ${CHK_WARN[@]+"${CHK_WARN[@]}"}; do echo "WARNUNG  $m"; done
  for m in ${CHK_NOTE[@]+"${CHK_NOTE[@]}"}; do echo "HINWEIS  $m"; done
  echo "Ergebnis: ${#CHK_ERR[@]} Fehler, ${#CHK_WARN[@]} Warnungen."
  [ "${#CHK_ERR[@]}" -eq 0 ]
}

# ---------------------------------------------------------------- Schreiben
declare -a NEW_LINES=()
TMPFILES=()
cleanup() { local f; for f in ${TMPFILES[@]+"${TMPFILES[@]}"}; do rm -f "$f"; done; return 0; }

build_new_lines() {
  local k i line last first
  NEW_LINES=(${ENV_LINES[@]+"${ENV_LINES[@]}"})
  for k in $(printf '%s\n' ${PEND_SET[@]+"${!PEND_SET[@]}"} | sort); do
    [ -n "$k" ] || continue
    if is_secretlike "$k"; then die "Interner Schutz: $k ist ein Geheimnis und wird nie in die Datei geschrieben."; fi
    last=-1; first=-1
    for i in "${!NEW_LINES[@]}"; do
      line="${NEW_LINES[$i]}"
      if [[ $line == "$k="* ]]; then last=$i
      elif [[ $line =~ ^#[[:space:]]*"$k"= ]] && [ "$first" = -1 ]; then first=$i; fi
    done
    if [ "$last" != -1 ]; then NEW_LINES[last]="$k=$(quote_value "${PEND_SET[$k]}")"
    elif [ "$first" != -1 ]; then NEW_LINES[first]="$k=$(quote_value "${PEND_SET[$k]}")"
    else NEW_LINES+=("$k=$(quote_value "${PEND_SET[$k]}")"); fi
  done
  for k in $(printf '%s\n' ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"} | sort); do
    [ -n "$k" ] || continue
    for i in "${!NEW_LINES[@]}"; do
      line="${NEW_LINES[$i]}"
      if [[ $line == "$k="* ]]; then
        # Ein Geheimnis wird gelöscht, nicht auskommentiert (es soll nicht als Kommentar lesbar bleiben).
        if is_secretlike "$k"; then NEW_LINES[i]=$'\x01DELETE'; else NEW_LINES[i]="#$line"; fi
      fi
    done
  done
  local -a kept=()
  for i in "${!NEW_LINES[@]}"; do [ "${NEW_LINES[$i]}" = $'\x01DELETE' ] || kept+=("${NEW_LINES[$i]}"); done
  NEW_LINES=(${kept[@]+"${kept[@]}"})
  return 0
}

BACKUP_PATH=""
# Atomar: neue Fassung in eine temporäre Datei im selben Verzeichnis (Modus 0600), Sicherung der alten, dann mv (Rename).
write_env() {
  [ "$ENV_EXISTS" = 1 ] || die "Env-Datei $ENV_FILE fehlt; zuerst setup.sh ausführen (Speichern würde das Setup überspringen)."
  [ ! -L "$ENV_FILE" ] || die "Env-Datei darf kein Symlink sein"
  build_new_lines
  local dir ts bak n tmp same=0
  if [ "${#NEW_LINES[@]}" -eq "${#ENV_LINES[@]}" ]; then
    same=1
    for n in "${!NEW_LINES[@]}"; do [ "${NEW_LINES[$n]}" = "${ENV_LINES[$n]}" ] || { same=0; break; }; done
  fi
  BACKUP_PATH=""
  if [ "$same" = 1 ]; then PEND_SET=(); PEND_UNSET=(); return 0; fi
  dir="$(dirname "$ENV_FILE")"
  tmp="$(umask 077; mktemp "$dir/.settings.XXXXXX")" || die "temporäre Datei in $dir nicht anlegbar"
  TMPFILES+=("$tmp")
  if [ "${#NEW_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NEW_LINES[@]}" > "$tmp"; else : > "$tmp"; fi
  chmod 600 "$tmp"
  chown --reference="$ENV_FILE" "$tmp" 2>/dev/null || true
  ts="$(date +%Y%m%d-%H%M%S)"; bak="$ENV_FILE.bak.$ts"; n=1
  while [ -e "$bak" ]; do bak="$ENV_FILE.bak.$ts-$n"; n=$((n + 1)); done
  ( umask 077; cp -p "$ENV_FILE" "$bak" ); chmod 600 "$bak"
  BACKUP_PATH="$bak"
  mv -f "$tmp" "$ENV_FILE" || die "Schreiben fehlgeschlagen; die Env-Datei ist unverändert (Sicherung: $bak)"
  PEND_SET=(); PEND_UNSET=()
  env_load
  return 0
}

show_val() { # Wert für die Anzeige (Geheimnisse nie)
  local k="$1" v="$2"
  if is_secretlike "$k"; then if [ -n "$v" ]; then printf '***'; else printf '(leer)'; fi; elif [ -z "$v" ]; then printf '(leer)'; else printf '%s' "$v"; fi
  return 0
}
redact_line() { # eine Datei-Zeile ohne Geheimnisse ausgeben
  local line="$1"
  if [[ $line =~ ^[[:space:]]*#?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && is_secretlike "${BASH_REMATCH[1]}"; then
    printf '%s=***' "${BASH_REMATCH[1]}"
  else printf '%s' "$line"; fi
  return 0
}

# ---------------------------------------------------------------- Konfigurationsschlüssel (Swarm-Secret)
GEN_MSG=""
GEN_ERR=""
secret_state() { # Name -> SS_STATE=exists|missing|error (SS_ERR bei error); ändert nichts
  local name="$1" err ctl rc=0
  SS_STATE=""; SS_ERR=""
  err="$(docker secret inspect "$name" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" = 0 ]; then SS_STATE=exists; return 0; fi
  # Ein Fehler kann "nicht vorhanden" oder "Docker nicht nutzbar" heißen: nur ein Swarm-Manager darf "fehlt" sagen.
  ctl="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" || ctl=""
  if [ "$ctl" = true ]; then SS_STATE=missing
  elif [ -z "$ctl" ]; then SS_STATE=error; SS_ERR="Docker ist nicht erreichbar (${err%%$'\n'*}). Auf einem Swarm-Manager ausführen."
  else SS_STATE=error; SS_ERR="Dieser Knoten ist kein Swarm-Manager; Secrets lassen sich nur auf einem Manager anlegen."; fi
  return 0
}
# Legt das Secret nur an, wenn es fehlt, und setzt SETTINGS_KEY_ENABLED=true (vorgemerkt, geschrieben wird vom Aufrufer).
# Der Wert steht nur in einer lokalen Variable und geht per stdin an docker: nie in Argumente, Dateien oder Ausgaben.
generate_settings_key() {
  local name key err rc=0
  GEN_MSG=""; GEN_ERR=""
  if [ "$ENV_EXISTS" = 0 ]; then GEN_ERR="Env-Datei $ENV_FILE fehlt; zuerst setup.sh ausführen. Es wurde nichts angelegt."; return 2; fi
  if [ -L "$ENV_FILE" ]; then GEN_ERR="Env-Datei darf kein Symlink sein. Es wurde nichts angelegt."; return 2; fi
  name="$(eff_value SETTINGS_KEY_SECRET)"
  if ! validate SETTINGS_KEY_SECRET "$name"; then GEN_ERR="SETTINGS_KEY_SECRET ($name): $V_ERR"; return 2; fi
  command -v docker >/dev/null 2>&1 || { GEN_ERR="docker fehlt; auf einem Swarm-Manager ausführen. Es wurde nichts angelegt."; return 2; }
  secret_state "$name"
  case "$SS_STATE" in
    error) GEN_ERR="$SS_ERR Es wurde nichts angelegt."; return 2 ;;
    exists)
      GEN_MSG="Secret '$name' existiert schon und bleibt unverändert (ein vorhandener Schlüssel wird nie ersetzt, sonst wären gespeicherte Geheimnisse unlesbar)." ;;
    missing)
      command -v openssl >/dev/null 2>&1 || { GEN_ERR="openssl fehlt; der Zufallsschlüssel braucht es. Es wurde nichts angelegt."; return 2; }
      key="$(openssl rand -base64 32 2>/dev/null | tr -d '\n')" || key=""
      if ! [[ $key =~ ^[A-Za-z0-9+/]{43}=$ ]]; then key=""; GEN_ERR="Der Zufallswert konnte nicht erzeugt werden (openssl rand -base64 32). Es wurde nichts angelegt."; return 2; fi
      err="$(printf '%s' "$key" | docker secret create "$name" - 2>&1 >/dev/null)" || rc=$?
      key=""
      if [ "$rc" != 0 ]; then GEN_ERR="docker secret create '$name' schlug fehl (${err%%$'\n'*}). SETTINGS_KEY_ENABLED bleibt unverändert."; return 2; fi
      GEN_MSG="Secret '$name' angelegt (32 Zufallsbytes als Base64). Der Wert wird nicht angezeigt und nirgends außer im Swarm-Secret gespeichert; Docker gibt Secrets nur an Container heraus. Geht er verloren, sind in der PWA gespeicherte Geheimnisse unlesbar und werden dort neu eingegeben. Den Schlüssel nicht im selben Backup wie die Datenbank sichern." ;;
  esac
  queue_set SETTINGS_KEY_ENABLED true
  return 0
}

# ---------------------------------------------------------------- Menü (whiptail)
UI=""; ROWS=24; COLS=80; H=22; W=76; LH=12
WT_OUT=""

ui_init() {
  if command -v whiptail >/dev/null 2>&1; then UI=whiptail
  elif command -v dialog >/dev/null 2>&1; then UI=dialog
  else
    cat >&2 <<'EOF'
whiptail (oder dialog) fehlt; das Menü ist nicht verfügbar. Installieren mit: apt install whiptail
Ohne Menü funktionieren: --list, --get KEY, --set KEY=VALUE, --unset KEY, --info KEY, --generate SETTINGS_ENCRYPTION_KEY, --check, --help
EOF
    exit 1
  fi
  return 0
}
ui_size() {
  local sz
  if [ -n "${SETTINGS_ROWS:-}" ] && [ -n "${SETTINGS_COLS:-}" ]; then ROWS="$SETTINGS_ROWS"; COLS="$SETTINGS_COLS"
  elif sz="$(stty size 2>/dev/null </dev/tty)" && [ -n "$sz" ]; then ROWS="${sz% *}"; COLS="${sz#* }"
  else ROWS="${LINES:-$(tput lines 2>/dev/null || echo 24)}"; COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"; fi
  [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24; [[ $COLS =~ ^[0-9]+$ ]] || COLS=80
  H=$((ROWS - 2)); [ "$H" -gt 30 ] && H=30; [ "$H" -lt 14 ] && H=14
  W=$((COLS - 4)); [ "$W" -gt 100 ] && W=100; [ "$W" -lt 50 ] && W=50
  LH=$((H - 8)); [ "$LH" -lt 4 ] && LH=4
  return 0
}
# whiptail aufrufen; Auswahl landet in WT_OUT, Rückgabe = Exit-Code. @H, @W, @LH werden durch die aktuelle Fenstergröße ersetzt.
wt() {
  local rc=0 a bt="$BACKTITLE | ${ENV_FILE##*/}"
  local -a args=()
  ui_size
  [ "$(pending_count)" -eq 0 ] || bt+=" | $(pending_count) ungespeichert"
  for a in "$@"; do
    case "$a" in @H) a="$H" ;; @W) a="$W" ;; @LH) a="$LH" ;; *) ;; esac
    args+=("$a")
  done
  WT_OUT="$("$UI" --backtitle "$bt" --ok-button OK --cancel-button Zurück --yes-button Ja --no-button Nein "${args[@]}" 3>&1 1>&2 2>&3)" || rc=$?
  return "$rc"
}
FIT_H=20; FIT_LH=10
fit_menu() { # Einträge Textzeilen
  ui_size
  FIT_LH="$1"; [ "$FIT_LH" -le "$LH" ] || FIT_LH="$LH"
  FIT_H=$((FIT_LH + $2 + 6)); [ "$FIT_H" -le "$H" ] || FIT_H="$H"
  return 0
}
text_height() { # Zeilen eines Textes (mit Umbruch) + Rahmen
  local text="$1" lines=0 line
  ui_size
  while IFS= read -r line; do lines=$((lines + 1 + ${#line} / (W - 6))); done <<< "$text"
  echo $((lines + 6))
}
fit_menu_text() { local th; th="$(text_height "$2")"; fit_menu "$1" $((th - 5)); }
ui_msg() { # Titel Text
  local h st="" t="$1"; ui_size; h="$(text_height "$2")"
  if [ "$h" -gt "$H" ]; then h=$H; st=--scrolltext; t+=" (Tab, dann Enter schließt)"; fi
  wt --title "$t" ${st:+"$st"} --msgbox "$2" "$h" "$W" || true
  return 0
}
ui_yesno() { # Titel Text [--defaultno]
  local h; ui_size; h="$(text_height "$2")"; [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" ${3:+"$3"} --yesno "$2" "$h" "$W"
}
ui_input() { # Titel Text Startwert
  local h; ui_size; h="$(text_height "$2")"; h=$((h + 2)); [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" --inputbox "$2" "$h" "$W" "$3"
}
ui_textfile() { # Titel Datei
  local text h; text="$(cat "$2")"; ui_size; h="$(text_height "$text")"
  if [ "$h" -le "$H" ]; then wt --title "$1" --msgbox "$text" "$h" "$W" || true
  else wt --title "$1 (Esc schließt)" --scrolltext --textbox "$2" @H @W || true; fi
  return 0
}

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) CRUMB_SEP=" › " ;; *) CRUMB_SEP=" > " ;; esac
crumb() { local out="Einstellungen" p; for p in "$@"; do out+="$CRUMB_SEP$p"; done; printf '%s' "$out"; }

# Pflichtangaben: Mindestsatz für eine lauffähige Installation (Domain/Passkeys, externe Datenbank, Image, Port). Geheimnisse fragt setup.sh.
REQUIRED_KEYS="RP_ORIGIN RP_ID DB_HOST DB_PORT DB_NAME DB_USER TODO_IMAGE_TAG BACKEND_PORT BACKEND_REPLICAS"
declare -a MENU_TITLES=() GROUP_KEYS=()
# Die Gruppen des Menüs sind die Gruppen der Tabellen (in der Reihenfolge ihres ersten Auftretens): neue Einstellungen erscheinen ohne Codeänderung.
build_groups() {
  local k g i found
  MENU_TITLES=("Pflichtangaben"); GROUP_KEYS=("")
  for k in $REQUIRED_KEYS; do is_known "$k" && GROUP_KEYS[0]+="${GROUP_KEYS[0]:+ }$k"; done
  for k in "${KEYS[@]}"; do
    g="${T_GROUP[$k]}"; found=-1
    for i in "${!MENU_TITLES[@]}"; do [ "${MENU_TITLES[$i]}" = "$g" ] && { found=$i; break; }; done
    if [ "$found" = -1 ]; then MENU_TITLES+=("$g"); GROUP_KEYS+=(""); found=$(( ${#MENU_TITLES[@]} - 1 )); fi
    GROUP_KEYS[found]+="${GROUP_KEYS[found]:+ }$k"
  done
  return 0
}
group_summary() { # Index -> "n Einträge, m gesetzt[, c geändert]"
  local n=0 m=0 c=0 k
  for k in ${GROUP_KEYS[$1]}; do
    n=$((n + 1)); is_set "$k" && m=$((m + 1))
    if [ -n "${PEND_SET[$k]+x}" ] || [ -n "${PEND_UNSET[$k]+x}" ]; then c=$((c + 1)); fi
  done
  if [ "$c" -gt 0 ]; then echo "$n Einträge, $m gesetzt, $c geändert"; else echo "$n Einträge, $m gesetzt"; fi
  return 0
}
state_label() {
  local k="$1"
  if [ -n "${PEND_UNSET[$k]+x}" ]; then echo RESET
  elif [ -n "${PEND_SET[$k]+x}" ]; then echo NEU
  elif in_file "$k"; then echo gesetzt
  else echo Default; fi
  return 0
}
item_desc() { # KEY Breite -> "Wert  Zustand  Wirkung" (Wert wird auf die Breite gekürzt)
  local k="$1" dw="${2:-34}" v u vb
  if [ "${T_SECRET[$k]}" = 1 ]; then printf 'Geheimnis (nicht in der Datei)'; return 0; fi
  v="$(eff_value "$k")"; u="${T_UNIT[$k]}"
  if is_secretlike "$k" && [ -n "$v" ]; then v="***"; fi
  if [ "$dw" -ge 32 ]; then vb=$((dw - 19)); elif [ "$dw" -ge 20 ]; then vb=$((dw - 9)); else vb=$dw; fi
  [ "$vb" -ge 6 ] || vb=6; [ "$vb" -le 26 ] || vb=26
  if [ -z "$v" ]; then v="(leer)"; elif [ -n "$u" ] && [ $((${#v} + ${#u} + 1)) -le "$vb" ]; then v="$v $u"; fi
  if [ "${#v}" -gt "$vb" ]; then v="${v:0:$((vb - 1))}~"; fi
  if [ "$dw" -ge 32 ]; then printf '%-*s %-8s %s' "$vb" "$v" "$(state_label "$k")" "$(apply_label "$k")"
  elif [ "$dw" -ge 20 ]; then printf '%-*s %s' "$vb" "$v" "$(state_label "$k")"
  else printf '%s' "$v"; fi
  return 0
}
info_text() { # KEY -> Erklärung (lang, falls vorhanden) plus Typ, Default, aktueller Wert
  local k="$1" h="${T_HELP[$1]:-}"
  [ -n "$h" ] || h="${T_SUM[$k]}"
  printf '%s\n\nTyp:      %s\nDefault:  %s\nAktuell:  %s (%s)\nWirkung:  %s' \
    "$h" "$(describe_type "$k")" "$(show_val "$k" "$(default_of "$k")")" "$(show_val "$k" "$(eff_value "$k")")" "$(state_label "$k")" "$(effect_text "$k")"
}
PARENT_CRUMB=""
reset_key() {
  local k="$1"
  if ! in_file "$k" && [ -z "${PEND_SET[$k]+x}" ]; then
    ui_msg "$k" "Nicht gesetzt: es gilt bereits der Default ($(default_of "$k"))."
    return 0
  fi
  queue_unset "$k"
  if [ -n "${PEND_SET[$k]+x}" ]; then unset 'PEND_SET[$k]'; fi
  return 0
}
edit_key() { # KEY
  local k="$1" base="${T_TYPE[$1]%%:*}" init prompt tok n lo hi ct i choice def
  local -a opts=() ch
  ct="$(crumb ${PARENT_CRUMB:+"$PARENT_CRUMB"} "$k")"
  if [ "${T_SECRET[$k]}" = 1 ]; then ui_msg "$ct" "$(secret_hint "$k")"; return 0; fi
  init="$(eff_value "$k")"; lo="${T_MIN[$k]}"; hi="${T_MAX[$k]}"; def="$(default_of "$k")"
  case "$base" in
    bool) opts=(true "an" false "aus") ;;
    choice) IFS='|' read -ra ch <<< "${T_CHOICES[$k]}"; for tok in "${ch[@]}"; do opts+=("$tok" ""); done ;;
    int) if [[ $lo =~ ^[0-9]+$ && $hi =~ ^[0-9]+$ ]] && [ $((hi - lo)) -le 5 ]; then for ((i = lo; i <= hi; i++)); do opts+=("$i" ""); done; fi ;;
  esac
  if [ "${#opts[@]}" -gt 0 ]; then
    n=$(( ${#opts[@]} / 2 ))
    if in_file "$k" || [ -n "${PEND_SET[$k]+x}" ]; then opts+=("-" "Auf Default zurücksetzen (${def:-leer})"); n=$((n + 1)); fi
    for ((i = 0; i < ${#opts[@]}; i += 2)); do [ "${opts[i]}" = "$init" ] && opts[i + 1]="${opts[i + 1]:+${opts[i + 1]}  }<- aktuell"; done
    prompt="$(info_text "$k")"
    fit_menu_text "$n" "$prompt"
    if wt --title "$ct" --default-item "$init" --menu "$prompt" "$FIT_H" @W "$FIT_LH" "${opts[@]}"; then
      choice="$WT_OUT"
      if [ "$choice" = "$init" ] && ! { [ -z "$init" ] && ! in_file "$k" && [ -z "${PEND_SET[$k]+x}" ]; }; then :
      elif [ "$choice" = - ]; then reset_key "$k"
      else queue_set "$k" "$choice"; fi
    fi
    return 0
  fi
  prompt="$(info_text "$k")"$'\n\n'"Neuer Wert (leer lassen = Default${def:+ $def}"
  if [ -z "$def" ] || [[ ${T_TYPE[$k]} == *\? ]]; then prompt+="; \"\" setzt den Wert explizit auf leer"; fi
  prompt+="):"
  while :; do
    ui_input "$ct" "$prompt" "$init" || return 0
    tok="${WT_OUT#"${WT_OUT%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"
    if [ -z "$tok" ]; then
      if in_file "$k" || [ -n "${PEND_SET[$k]+x}" ]; then
        if ui_yesno "$ct" "Leer: $k auf den Default zurücksetzen (${def:-leer})?
Die Zeile in der Datei wird beim Speichern auskommentiert."; then reset_key "$k"; return 0; fi
        init="$(eff_value "$k")"; continue
      fi
      ui_msg "$ct" "Nicht gesetzt: es gilt bereits der Default (${def:-leer})."; return 0
    fi
    if [ "$tok" = '""' ]; then tok=""; fi
    if validate "$k" "$tok"; then
      if [ "$tok" != "$(eff_value "$k")" ] || in_file "$k" || [ -n "${PEND_SET[$k]+x}" ] || [ -z "$tok" ]; then queue_set "$k" "$tok"; fi
      return 0
    fi
    init="$WT_OUT"
    ui_msg "Ungültiger Wert" "$k: $V_ERR

Erlaubt: $(describe_type "$k")
Die Eingabe bleibt im Feld stehen und kann korrigiert werden."
  done
}

declare -A GSEL=()
longest_key() { local k m=0; for k in "$@"; do [ "${#k}" -le "$m" ] || m=${#k}; done; echo "$m"; }
group_menu() { # Index
  local idx="$1" k kw dw intro title
  local -a items keys
  title="${MENU_TITLES[$idx]}"
  read -ra keys <<< "${GROUP_KEYS[$idx]}"
  [ "${#keys[@]}" -gt 0 ] || return 0
  kw="$(longest_key "${keys[@]}")"
  PARENT_CRUMB="$title"
  while :; do
    ui_size; dw=$((W - kw - 9))
    items=()
    for k in "${keys[@]}"; do items+=("$k" "$(item_desc "$k" "$dw")"); done
    intro="Enter: bearbeiten, Esc: zurück. Spalten: Wert | Zustand | Wirkung"
    if [ "$idx" -eq 0 ]; then intro="Mindestangaben für eine lauffähige Installation (Passwörter und Schlüssel fragt setup.sh). $intro"; fi
    fit_menu "${#keys[@]}" 1
    if wt --title "$(crumb "$title")" ${GSEL[$idx]:+--default-item "${GSEL[$idx]}"} --menu "$intro" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      GSEL[$idx]="$WT_OUT"; edit_key "$WT_OUT"
    else return 0; fi
  done
}
search_menu() {
  local term="" k hay lt sel="" kw dw
  local -a items keys
  while :; do
    ui_input "$(crumb Suche)" "Suchbegriff (Name, Beschreibung, Gruppe oder Zustand wie gesetzt/neu):" "$term" || return 0
    term="${WT_OUT,,}"; term="${term#"${term%%[![:space:]]*}"}"; term="${term%"${term##*[![:space:]]}"}"
    [ -n "$term" ] || { ui_msg "$(crumb Suche)" "Bitte einen Suchbegriff eingeben."; continue; }
    sel=""
    while :; do
      items=(); keys=()
      for k in "${KEYS[@]}"; do
        hay="${k,,} ${T_SUM[$k],,} ${T_GROUP[$k],,} $(state_label "$k" | tr '[:upper:]' '[:lower:]')"
        if [[ $hay == *"$term"* ]]; then keys+=("$k"); fi
      done
      if [ "${#keys[@]}" -eq 0 ]; then ui_msg "$(crumb Suche)" "Keine Treffer für '$term'."; break; fi
      kw="$(longest_key "${keys[@]}")"; ui_size; dw=$((W - kw - 9))
      for k in "${keys[@]}"; do items+=("$k" "$(item_desc "$k" "$dw")"); done
      lt=${#keys[@]}
      fit_menu "$lt" 1
      PARENT_CRUMB="Suche"
      if wt --title "$(crumb Suche "'$term'")" ${sel:+--default-item "$sel"} --menu "$lt Treffer. Enter: bearbeiten, Esc: neue Suche" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
        sel="$WT_OUT"; edit_key "$sel"
      else break; fi
    done
  done
}
show_notes() {
  ui_msg "$(crumb Hinweise)" "Wirkung der Einstellungen
- live: Der Dienst übernimmt Werte auch aus der PWA. Eine Variable in der Datei hat Vorrang und sperrt das Feld dort; sie wirkt nach einem Rollout (Anwenden).
- Neustart: wird beim Start der Dienste gelesen; wirkt nach einem Rollout.
- nur ENV: nur über die Datei, wirkt nach einem Rollout.
Wer eine Einstellung in der PWA ändern lassen will, nimmt sie aus der Datei (Zurücksetzen) und rollt neu aus.

Speichern und Anwenden
- Änderungen sammelt das Menü im Speicher. Beim Speichern erscheint eine Übersicht mit Prüfung; vorher entsteht eine Sicherung <Datei>.bak.JJJJMMTT-HHMMSS.
- Zurücksetzen kommentiert die Zeile aus (# KEY=alt): reversibel, danach gilt der Default.
- Geheimnisse erscheinen hier nie und werden nie geschrieben (Swarm-Secrets).
- Ausgerollt wird nur mit \"Anwenden\" und Bestätigung (ruft update.sh mit dem aktuellen Image-Tag)."
  return 0
}

build_review() { # Datei
  local f="$1" k old new line m lbl before after
  {
    echo "ÄNDERUNGEN"
    for k in $(printf '%s\n' ${PEND_SET[@]+"${!PEND_SET[@]}"} ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"} | sort -u); do
      [ -n "$k" ] || continue
      if in_file "$k"; then old="$(show_val "$k" "${ENV_VAL[$k]}")"; else old="(Default: $(show_val "$k" "$(default_of "$k")"))"; fi
      if [ -n "${PEND_SET[$k]+x}" ]; then new="$(show_val "$k" "${PEND_SET[$k]}")"; else new="(Default: $(show_val "$k" "$(default_of "$k")"), Zeile wird auskommentiert)"; fi
      lbl="$(apply_label "$k")"
      echo "  $k: $old  ->  $new   [$lbl]"
    done
    echo
    echo "WIRKUNG: erst nach \"Jetzt anwenden\" (Menü Anwenden: update.sh, Migration, dann Rolling Update)."
    echo
    echo "DIFF der Datei $ENV_FILE (ohne Kontext)"
    before="$(mktemp)"; after="$(mktemp)"; TMPFILES+=("$before" "$after")
    if [ "${#ENV_LINES[@]}" -gt 0 ]; then printf '%s\n' "${ENV_LINES[@]}" > "$before"; fi
    build_new_lines
    if [ "${#NEW_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NEW_LINES[@]}" > "$after"; fi
    diff -U0 "$before" "$after" | tail -n +3 | while IFS= read -r line; do
      case "$line" in
        '@@'*) ;;
        [+-]*) printf '%s%s\n' "${line:0:1}" "$(redact_line "${line:1}")" ;;
      esac
    done || true
    rm -f "$before" "$after"
    check_all
    if [ "${#CHK_ERR[@]}" -gt 0 ] || [ "${#CHK_WARN[@]}" -gt 0 ] || [ "${#CHK_NOTE[@]}" -gt 0 ]; then
      echo; echo "PRÜFUNG"
      for m in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do echo "  FEHLER   $m"; done
      for m in ${CHK_WARN[@]+"${CHK_WARN[@]}"}; do echo "  WARNUNG  $m"; done
      for m in ${CHK_NOTE[@]+"${CHK_NOTE[@]}"}; do echo "  HINWEIS  $m"; done
    fi
  } > "$f"
  return 0
}
save_flow() { # Rückgabe 0 = gespeichert
  local f
  if [ "$(pending_count)" -eq 0 ]; then ui_msg "Speichern" "Keine Änderungen."; return 1; fi
  if [ "$ENV_EXISTS" = 0 ]; then ui_msg "Speichern" "Die Datei $ENV_FILE existiert nicht. Zuerst setup.sh ausführen."; return 1; fi
  f="$(mktemp)"; TMPFILES+=("$f")
  build_review "$f"
  ui_textfile "$(crumb "Änderungen prüfen")" "$f"
  if [ "${#CHK_ERR[@]}" -gt 0 ]; then
    ui_yesno "Fehler in der Prüfung" "Die Prüfung meldet ${#CHK_ERR[@]} Fehler (siehe Übersicht); das Ausrollen würde scheitern. Trotzdem speichern?" --defaultno || return 1
  elif ! ui_yesno "Speichern" "Änderungen in $ENV_FILE speichern?
Vorher wird eine Sicherung angelegt."; then
    return 1
  fi
  write_env
  ui_msg "$(crumb Gespeichert)" "${BACKUP_PATH:+Sicherung: $BACKUP_PATH
}Datei: $ENV_FILE

Die Dienste laufen noch mit den alten Werten. Wirksam wird die Änderung erst nach 'Anwenden' (oder update.sh)."
  return 0
}
key_flow() { # Konfigurationsschlüssel anlegen (Menü "Schluessel")
  local name
  if [ "$ENV_EXISTS" = 0 ]; then ui_msg "$(crumb Konfigurationsschlüssel)" "Die Datei $ENV_FILE existiert nicht. Zuerst setup.sh ausführen."; return 0; fi
  if [ "$(pending_count)" -gt 0 ]; then ui_msg "$(crumb Konfigurationsschlüssel)" "Es gibt ungespeicherte Änderungen. Erst speichern oder verwerfen, dann den Schlüssel anlegen (die Datei wird dabei sofort geschrieben)."; return 0; fi
  name="$(eff_value SETTINGS_KEY_SECRET)"
  ui_yesno "$(crumb Konfigurationsschlüssel)" "Zufälligen Konfigurationsschlüssel als Swarm-Secret '$name' anlegen?
- Nur wenn das Secret fehlt; ein vorhandenes bleibt unverändert.
- Der Wert wird nie angezeigt und nirgends gespeichert außer im Secret.
- SETTINGS_KEY_ENABLED=true wird in die Datei geschrieben (mit Sicherung).
- Es wird nichts ausgerollt." || return 0
  if generate_settings_key; then
    write_env
    ui_msg "$(crumb Konfigurationsschlüssel)" "$GEN_MSG
${BACKUP_PATH:+
Sicherung: $BACKUP_PATH}
SETTINGS_KEY_ENABLED=true steht in der Datei. Wirksam nach 'Anwenden'."
  else
    ui_msg "$(crumb Konfigurationsschlüssel)" "$GEN_ERR"
  fi
  return 0
}
apply_now() {
  local choice tag
  if [ "$(pending_count)" -gt 0 ]; then
    ui_yesno "Anwenden" "Es gibt ungespeicherte Änderungen. Zuerst speichern?" || return 0
    save_flow || return 0
  fi
  if [ ! -f "$ENV_FILE" ]; then ui_msg "Anwenden" "Es gibt noch keine Env-Datei; zuerst setup.sh ausführen."; return 0; fi
  check_all
  if [ "${#CHK_ERR[@]}" -gt 0 ]; then
    ui_msg "Anwenden" "Die Prüfung meldet Fehler; zuerst beheben (Menü oder --check):
$(printf '%s\n' "${CHK_ERR[@]}")"
    return 0
  fi
  [ -x "$UPDATE_SCRIPT" ] || { ui_msg "Anwenden" "$UPDATE_SCRIPT nicht gefunden oder nicht ausführbar."; return 0; }
  # update.sh ohne --tag fragt die Registry nach dem neuesten Image. Hier soll nur die Konfiguration ausgerollt werden: der Tag bleibt.
  tag="$(file_val TODO_IMAGE_TAG)"; tag="${tag:-$STACK_DEFAULT_TAG}"
  wt --title "$(crumb Anwenden)" --cancel-button Zurück --menu "Nichts wird ohne Bestätigung ausgerollt. Image-Tag bleibt: $tag" @H @W 3 \
    A "Einstellungen ausrollen (update.sh --tag $tag --force)" \
    D "Trockenlauf anzeigen (update.sh --dry-run, ändert nichts)" || return 0
  choice="$WT_OUT"
  case "$choice" in
    A)
      ui_yesno "Ausrollen bestätigen" "update.sh führt aus: Migration der externen Datenbank, danach Rolling Update der API mit den Werten aus $ENV_FILE (Image-Tag bleibt $tag). Ist die Datenbank gesichert (scripts/backup-db.sh)? Jetzt ausrollen?" --defaultno || return 0
      clear 2>/dev/null || true
      "$UPDATE_SCRIPT" --env-file "$ENV_FILE" --tag "$tag" --force --yes || echo "update.sh endete mit einem Fehler."
      read -r -p "Enter zum Zurückkehren ... " _ || true
      env_load ;;
    D)
      clear 2>/dev/null || true
      "$UPDATE_SCRIPT" --env-file "$ENV_FILE" --tag "$tag" --force --dry-run || echo "update.sh --dry-run endete mit einem Fehler."
      read -r -p "Enter zum Zurückkehren ... " _ || true ;;
  esac
  return 0
}
leave_menu() { # Rückgabe 0 = beenden
  local choice
  if [ "$(pending_count)" -eq 0 ]; then return 0; fi
  if wt --title "$(crumb Beenden)" --cancel-button "Zurück zum Menü" --menu "$(pending_count) Änderung(en) sind nicht gespeichert." @H @W 3 \
      S "Speichern und beenden" V "Verwerfen und beenden" Z "Zurück zum Menü"; then choice="$WT_OUT"; else return 1; fi
  case "$choice" in
    S) save_flow && return 0 || return 1 ;;
    V) return 0 ;;
    *) return 1 ;;
  esac
}
main_menu() {
  local sel="" i t d dw
  local -a items
  ui_size
  if [ "$ENV_EXISTS" = 0 ]; then ui_msg "Hinweis" "Die Datei $ENV_FILE existiert noch nicht. Sie können Werte ansehen; Speichern und Anwenden gehen erst nach setup.sh."; fi
  while :; do
    ui_size; dw=$((W - 36 - 9))
    items=()
    for i in "${!MENU_TITLES[@]}"; do
      [ -n "${GROUP_KEYS[$i]}" ] || continue
      d="($(group_summary "$i"))"
      if [ "${#d}" -gt "$dw" ]; then d="${d/ Einträge/}"; d="${d/ gesetzt/ ges.}"; fi
      items+=("${MENU_TITLES[$i]}" "${d:0:dw}")
    done
    d="Prüfen, speichern ($(pending_count) offen)"
    items+=("Suchen" "Filtern nach Text" "Hinweise" "live / Neustart / nur ENV" "Schluessel" "Konfigurationsschlüssel anlegen" \
            "Speichern" "${d:0:dw}" "Anwenden" "Ausrollen (mit Bestätigung)")
    t="Gruppe wählen (Enter), Esc beendet."
    if [ "$ROWS" -lt 24 ] || [ "$COLS" -lt 80 ]; then t+=$'\n'"Terminal ${COLS}x${ROWS}: empfohlen 80x24 oder größer."; fi
    fit_menu $(( ${#items[@]} / 2 )) "$(grep -c '' <<< "$t")"
    if wt --title "$(crumb)" --cancel-button Beenden ${sel:+--default-item "$sel"} --menu "$t" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      sel="$WT_OUT"
      case "$sel" in
        Suchen) search_menu ;;
        Hinweise) show_notes ;;
        Schluessel) key_flow ;;
        Speichern) save_flow || true ;;
        Anwenden) apply_now ;;
        *) for i in "${!MENU_TITLES[@]}"; do if [ "${MENU_TITLES[$i]}" = "$sel" ]; then group_menu "$i"; break; fi; done ;;
      esac
    else
      if leave_menu; then return 0; fi
    fi
  done
}

# ---------------------------------------------------------------- Kommandozeile
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

cli_list() {
  local k v src extra
  printf '%-38s %-26s %-18s %s\n' VARIABLE WERT DEFAULT QUELLE
  for k in "${KEYS[@]}"; do
    if [ "${T_SECRET[$k]}" = 1 ]; then
      printf '%-38s %-26s %-18s %s\n' "$k" "(Geheimnis)" "-" "Swarm-Secret/PWA"
      continue
    fi
    v="$(eff_value "$k")"
    if in_file "$k"; then src="Datei"; else src="Default"; fi
    printf '%-38s %-26s %-18s %s\n' "$k" "${v:-(leer)}" "$(default_of "$k")" "$src"
  done
  for k in $(printf '%s\n' ${ENV_VAL[@]+"${!ENV_VAL[@]}"} | sort); do
    [ -n "$k" ] || continue
    if is_known "$k"; then continue; fi
    if is_secretlike "$k"; then extra="***"; else extra="${ENV_VAL[$k]:-(leer)}"; fi
    printf '%-38s %-26s %-18s %s\n' "$k" "$extra" "-" "Datei (unbekannt)"
  done
  return 0
}
cli_generate() {
  local k="$1" rc=0
  if [ "$k" != SETTINGS_ENCRYPTION_KEY ]; then
    echo "--generate erzeugt nur SETTINGS_ENCRYPTION_KEY (Konfigurationsschlüssel als Swarm-Secret). $k wird nicht erzeugt." >&2; return 2
  fi
  generate_settings_key || rc=$?
  if [ "$rc" != 0 ]; then echo "$GEN_ERR" >&2; return "$rc"; fi
  echo "$GEN_MSG"
  echo "SETTINGS_KEY_ENABLED=true wird in die Env-Datei geschrieben."
  return 0
}
cli_info() {
  local k="$1"
  if ! is_known "$k"; then echo "Unbekannte Variable: $k" >&2; return 2; fi
  printf '%s\n' "$k"; info_text "$k"; echo
  return 0
}
cli_get() {
  local k="$1"
  if is_secretlike "$k"; then echo "$k ist ein Geheimnis und wird nie ausgegeben." >&2; return 2; fi
  if ! is_known "$k"; then
    if [ -n "${ENV_VAL[$k]+x}" ]; then printf '%s\n' "${ENV_VAL[$k]}"; return 0; fi
    echo "Unbekannte Variable: $k" >&2; return 2
  fi
  eff_value "$k"; echo
  return 0
}
cli_set() { # KEY=VALUE
  local pair="$1" k v
  if ! [[ $pair == ?*=* ]]; then echo "Format: --set KEY=VALUE" >&2; return 64; fi
  k="${pair%%=*}"; v="${pair#*=}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if is_secretlike "$k"; then
    echo "$k ist ein Geheimnis und wird nie in die Datei geschrieben." >&2; secret_hint "$k" >&2; echo >&2; return 2
  fi
  if ! is_known "$k"; then echo "Unbekannte Variable: $k (siehe --list)" >&2; return 2; fi
  if ! validate "$k" "$v"; then echo "Ungültiger Wert für $k: $V_ERR" >&2; return 3; fi
  queue_set "$k" "$v"
  echo "$k gesetzt auf: $(show_val "$k" "$v")"
  case "${T_APPLY[$k]}" in live|restart) echo "Hinweis: $k ist auch in der PWA einstellbar; ein Wert in der Datei hat Vorrang und sperrt dort das Feld." ;; esac
  return 0
}
cli_unset() {
  local k="$1"
  if ! is_known "$k" && [ -z "${ENV_COUNT[$k]+x}" ]; then echo "Unbekannte Variable: $k" >&2; return 2; fi
  if ! in_file "$k"; then echo "$k ist nicht gesetzt (Default)."; return 0; fi
  queue_unset "$k"
  if is_secretlike "$k"; then echo "$k wird aus der Datei gelöscht (Zeile wird entfernt, nicht auskommentiert)."
  else echo "$k wird auf den Default zurückgesetzt (Zeile auskommentiert)."; fi
  return 0
}

main() {
  local -a actions=()
  local want_menu=1 rc=0 act before="" after="" line mutate=0 new_err=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) ENV_FILE="${2:?--env braucht einen Pfad}"; shift 2 ;;
      --list) actions+=("list"); want_menu=0; shift ;;
      --get) actions+=("get:${2:?--get braucht einen Namen}"); want_menu=0; shift 2 ;;
      --set) actions+=("set:${2:?--set braucht KEY=VALUE}"); want_menu=0; shift 2 ;;
      --unset) actions+=("unset:${2:?--unset braucht einen Namen}"); want_menu=0; shift 2 ;;
      --info) actions+=("info:${2:?--info braucht einen Namen}"); want_menu=0; shift 2 ;;
      --generate) actions+=("generate:${2:?--generate braucht SETTINGS_ENCRYPTION_KEY}"); want_menu=0; shift 2 ;;
      --check) actions+=("check"); want_menu=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
    esac
  done
  [ -n "$ENV_FILE" ] || ENV_FILE="$DEFAULT_ENV"
  [[ $ENV_FILE == /* ]] || ENV_FILE="$PWD/$ENV_FILE"
  [ -d "$(dirname "$ENV_FILE")" ] || die "Verzeichnis der Env-Datei fehlt: $(dirname "$ENV_FILE")"
  load_tables
  env_load
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ "$want_menu" = 1 ]; then
    ui_init
    build_groups
    main_menu
    return 0
  fi

  for act in "${actions[@]}"; do case "$act" in set:*|unset:*|generate:*) mutate=1 ;; esac; done
  if [ "$mutate" = 1 ]; then check_all; before="$(print_check || true)"; fi
  for act in "${actions[@]}"; do
    case "$act" in
      list) cli_list ;;
      get:*) cli_get "${act#get:}" || rc=$? ;;
      generate:*) cli_generate "${act#generate:}" || { rc=$?; break; } ;;
      info:*) cli_info "${act#info:}" || rc=$? ;;
      set:*) cli_set "${act#set:}" || { rc=$?; break; } ;;
      unset:*) cli_unset "${act#unset:}" || { rc=$?; break; } ;;
      check) check_all; print_check || rc=1 ;;
    esac
  done
  if [ "$rc" != 0 ]; then PEND_SET=(); PEND_UNSET=(); return "$rc"; fi
  if [ "$(pending_count)" -gt 0 ]; then
    if [ "$ENV_EXISTS" = 0 ]; then echo "Env-Datei $ENV_FILE fehlt; zuerst setup.sh ausführen. Es wurde nichts geschrieben." >&2; return 2; fi
    check_all; after="$(print_check || true)"
    # Neue Fehler (gegenüber dem Zustand vorher) verhindern das Speichern: das Ausrollen würde scheitern.
    while IFS= read -r line; do
      case "$line" in FEHLER*) [[ $before == *"$line"* ]] || new_err+="$line"$'\n' ;; esac
    done <<< "$after"
    if [ -n "$new_err" ]; then
      printf '%s' "$new_err" >&2
      echo "Nicht gespeichert: die Änderung würde einen Fehler erzeugen. Zusammengehörige Werte in einem Aufruf setzen (mehrere --set)." >&2
      return 3
    fi
    write_env
    if [ -n "$BACKUP_PATH" ]; then
      echo "Sicherung: $BACKUP_PATH"
      echo "Gespeichert: $ENV_FILE. Die Änderung ist nicht ausgerollt; sie wirkt erst nach dem nächsten Rollout (Menü \"Anwenden\" oder update.sh)."
    else
      echo "Unverändert: $ENV_FILE"
    fi
    while IFS= read -r line; do
      case "$line" in Ergebnis:*|'') continue ;; esac
      [[ $before == *"$line"* ]] || echo "$line"
    done <<< "$after"
  fi
  return 0
}

# Beim Einbinden per `source` (Tests) wird nicht gestartet.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
