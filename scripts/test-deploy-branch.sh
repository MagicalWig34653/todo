#!/usr/bin/env bash
# Prueft die Dateiliste des Workflows .github/workflows/deploy-branch.yml gegen die Laufzeitdateien von deploy/swarm/settings.sh.
# Der Branch `deploy` entsteht nur aus dieser festen Liste; fehlt eine Datei, die settings.sh zur Laufzeit liest oder aufruft,
# laeuft das Skript im Branch nicht (Karte 139D9CC6).
# 1. Abhaengigkeiten ermitteln: settings.sh selbst plus jede Datei, die ein Skript ueber "$SCRIPT_DIR/<datei>" oder
#    "$SCRIPT_DIR/../../scripts/<datei>" nennt (rekursiv ueber die Skripte; nur im Git verfolgte Dateien, stack.env ist keine).
# 2. Jede muss in der Workflow-Liste stehen.
# 3. Die Liste wird in ein leeres Verzeichnis kopiert (wie der Workflow) und settings.sh dort nicht-interaktiv gestartet.
# Aufruf: scripts/test-deploy-branch.sh   (braucht bash 4.4+, git; kein Netz, kein Docker)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/deploy-branch.yml"
cd "$ROOT" || exit 2
fail=0; WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# Dateiliste des Workflows: der Wert von files="..." (mehrzeilig, bis zum schliessenden Anfuehrungszeichen).
wf_files="$(awk '/files="deploy\/swarm\/setup\.sh/ { on = 1; sub(/^[^"]*"/, "") } on { line = $0; if (line ~ /"/) { sub(/".*/, "", line); print line; exit } print line }' "$WF")"
[ -n "$wf_files" ] || { echo "FAIL Dateiliste in $WF nicht gefunden"; exit 2; }
# shellcheck disable=SC2086  # Wortzerlegung ist hier gewollt
set -- $wf_files; listed=" $* "

# Laufzeitabhaengigkeiten (Worklist)
declare -A seen=()
queue=("deploy/swarm/settings.sh")
while [ "${#queue[@]}" -gt 0 ]; do
  cur="${queue[0]}"; queue=("${queue[@]:1}")
  [ -z "${seen[$cur]+x}" ] || continue
  seen[$cur]=1
  case "$cur" in *.sh) ;; *) continue ;; esac
  dir="$(dirname "$cur")"
  while IFS= read -r ref; do
    ref="${ref#*SCRIPT_DIR\}/}"; ref="${ref#*SCRIPT_DIR/}"
    [ -n "$ref" ] || continue
    path="$(python3 -c 'import os,sys;print(os.path.normpath(sys.argv[1]))' "$dir/$ref")"
    if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then queue+=("$path"); fi
  done < <(grep -oE '\$\{?SCRIPT_DIR\}?/[A-Za-z0-9_./-]+' "$cur" | sort -u)
done

deps=("${!seen[@]}")
IFS=$'\n' deps=($(printf '%s\n' "${deps[@]}" | sort)); unset IFS
[ "${#deps[@]}" -ge 5 ] || bad "zu wenige Abhaengigkeiten erkannt (${#deps[@]}): ${deps[*]}"
for f in "${deps[@]}"; do
  case "$listed" in *" $f "*) ok "in der Workflow-Liste: $f" ;; *) bad "fehlt in der Workflow-Liste: $f" ;; esac
done
# Die drei Tabellen muessen immer dabei sein (settings.sh liest config-help.tsv nur optional und wuerde ihr Fehlen still hinnehmen).
for f in deploy/swarm/config-registry.tsv deploy/swarm/config-extra.tsv deploy/swarm/config-help.tsv deploy/swarm/settings.sh; do
  case "$listed" in *" $f "*) ok "Pflichtdatei gelistet: $f" ;; *) bad "Pflichtdatei fehlt: $f" ;; esac
done
# Jede gelistete Datei existiert in main (sonst bricht cp im Workflow ab).
for f in $listed; do [ -f "$f" ] || bad "gelistete Datei fehlt in main: $f"; done

# Frischer Baum nur aus der Liste, wie der Workflow ihn schreibt.
FRESH="$WORK/deploy-clone"; mkdir -p "$FRESH"
for f in $listed; do mkdir -p "$FRESH/$(dirname "$f")"; cp -p "$f" "$FRESH/$f"; done
cp deploy/branch/gitignore "$FRESH/.gitignore"
S="$FRESH/deploy/swarm/settings.sh"
[ -x "$S" ] && ok "settings.sh ist ausfuehrbar" || bad "settings.sh nicht ausfuehrbar"
if out="$("$S" --help </dev/null 2>&1)" && printf '%s' "$out" | grep -q -- '--check'; then ok "settings.sh --help im frischen Baum"; else bad "settings.sh --help: $out"; fi
cp "$FRESH/deploy/swarm/stack.env.example" "$WORK/example.env"
if out="$("$S" --env "$WORK/example.env" --list </dev/null 2>&1)" && ! printf '%s' "$out" | grep -qiE 'fehlt|Tabelle'; then ok "settings.sh --list im frischen Baum"; else bad "settings.sh --list: ${out:0:300}"; fi
out="$("$S" --env "$WORK/example.env" --info SETTINGS_ENCRYPTION_KEY </dev/null 2>&1)" && [ -n "$out" ] && ok "settings.sh --info (config-help.tsv)" || bad "settings.sh --info: ${out:0:300}"
# --check darf Warnungen und Fehler zum Inhalt der Beispieldatei melden; es darf nur keine fehlende Programmdatei geben.
out="$("$S" --env "$WORK/example.env" --check </dev/null 2>&1)"; printf '%s' "$out" | grep -qE 'Tabelle fehlt|No such file|nicht gefunden|command not found' && bad "settings.sh --check: fehlende Datei: ${out:0:300}" || ok "settings.sh --check ohne fehlende Programmdatei"

exit "$fail"
