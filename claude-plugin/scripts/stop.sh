#!/bin/sh
# Stop: in a repository bound to Todolino (.todolino.json) block the end of a turn when the board was not used:
#  1. Files were changed or commits made, but the transcript has no post_progress/request_review/ask_question call
#     -> one reminder (counter file, cap TODOLINO_STOP_MAX, default 1 per session).
#  2. Files were changed, but record_sync was never called -> one reminder (marker per session).
# Never loops (stop_hook_active, per-session counters), fails open on every error, needs no network, handles no
# secrets and never echoes transcript content: the reason texts are fixed.
. "$(dirname "$0")/lib.sh" 2>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
[ "$(json_field stop_hook_active)" = "true" ] && exit 0
cwd=$(json_field cwd); [ -n "$cwd" ] || cwd=$(pwd)
find_marker "$cwd" >/dev/null || exit 0
[ -n "$TODOLINO_HOOKS_OFF" ] && exit 0
transcript=$(json_field transcript_path)
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0
session=$(json_field session_id)
case "$session" in *[!A-Za-z0-9_-]*|"") exit 0 ;; esac
dir="${TMPDIR:-/tmp}"
flag="$dir/todolino-stop-$session"
counter="$dir/todolino-board-$session"
max="${TODOLINO_STOP_MAX:-1}"
case "$max" in *[!0-9]*|"") max=1 ;; esac

# Tool calls only count when they appear as a tool_use name (a mere mention in text is JSON-escaped and does not match).
used() { grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*'"$1"'"' "$transcript" 2>/dev/null; }
edited=0
grep -Eq '"name": ?"(Edit|Write|MultiEdit|NotebookEdit)"' "$transcript" 2>/dev/null && edited=1
committed=0
grep -Eq '"name": ?"Bash".*git commit' "$transcript" 2>/dev/null && committed=1
synced=0; used record_sync && synced=1

if [ "$edited" = 1 ] || [ "$committed" = 1 ]; then
  if ! used post_progress && ! used request_review && ! used ask_question; then
    n=$(cat "$counter" 2>/dev/null); case "$n" in *[!0-9]*|"") n=0 ;; esac
    if [ "$n" -lt "$max" ]; then
      printf '%s' $((n + 1)) > "$counter" 2>/dev/null || exit 0
      : > "$flag" 2>/dev/null
      printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber in dieser Sitzung gab es Aenderungen oder Commits ohne Board-Aktivitaet (kein post_progress, request_review oder ask_question). Aktualisiere jetzt das Board: passende Aufgabe suchen oder mit create_task anlegen (keine Duplikate), claim_task, post_progress mit dem erledigten Stand und dem naechsten Schritt, bei Fertigstellung request_review (nie selbst auf erledigt setzen), offene Entscheidungen des Nutzers als ask_question auf der Aufgabe, danach record_sync. Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt hoechstens einmal pro Sitzung."}'
      exit 0
    fi
  fi
fi

[ -e "$flag" ] && exit 0
[ "$synced" = 1 ] && exit 0
[ "$edited" = 1 ] || exit 0
: > "$flag" 2>/dev/null || exit 0
printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber in dieser Sitzung wurde record_sync nicht aufgerufen, obwohl Dateien geaendert wurden. Bring das Board jetzt auf den aktuellen Stand: post_progress fuer die erledigte Arbeit, Status/Fragen/Review aktualisieren (import_plan fuer neue oder erledigte Plan-Punkte) und dann record_sync mit kurzer Zusammenfassung aufrufen. Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt nur einmal pro Sitzung."}'
exit 0
