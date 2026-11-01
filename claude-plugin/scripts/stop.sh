#!/bin/sh
# Stop: in a repository bound to Todolino (.todolino.json) block the end of a turn ONCE per session when files were
# changed but record_sync was never called in this session. Never loops (stop_hook_active, per-session marker),
# fails open on every error, needs no network and handles no secrets.
# Second duty (PUSH-AN-CLAUDE-CODE.md, option b, variant 2): while a blocking ask_question of this session has no
# get_question after it, block the stop with a FIXED text telling the agent to call wait_for_events and then
# get_question. At most ASK_WAIT_MAX own continuations per session (counter file); never quotes transcript content.
. "$(dirname "$0")/lib.sh" 2>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
active=$(json_field stop_hook_active)
cwd=$(json_field cwd); [ -n "$cwd" ] || cwd=$(pwd)
find_marker "$cwd" >/dev/null || exit 0
[ -n "$TODOLINO_HOOKS_OFF" ] && exit 0
transcript=$(json_field transcript_path)
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0
session=$(json_field session_id)
case "$session" in *[!A-Za-z0-9_-]*|"") exit 0 ;; esac
# Open blocking question: the last ask_question (not "blocking": false) lies after the last get_question.
ASK_WAIT_MAX=${TODOLINO_ASK_WAIT_MAX:-6}
askflag="${TMPDIR:-/tmp}/todolino-askwait-$session"
if grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*ask_question"' "$transcript" 2>/dev/null; then
  open=$(awk '
    /"name": ?"mcp__[A-Za-z0-9_-]*ask_question"/ { if ($0 !~ /"blocking": ?false/) q = NR }
    /"name": ?"mcp__[A-Za-z0-9_-]*get_question"/ { g = NR }
    END { if (q > 0 && q > g) print "open" }' "$transcript" 2>/dev/null)
  used=0; [ -f "$askflag" ] && used=$(wc -l < "$askflag" 2>/dev/null | tr -d ' ')
  # Under stop_hook_active only continue a chain that this hook started itself.
  if [ "$open" = "open" ] && [ "${used:-0}" -lt "$ASK_WAIT_MAX" ] && { [ "$active" != "true" ] || [ "${used:-0}" -gt 0 ]; }; then
    echo x >> "$askflag" 2>/dev/null || exit 0
    printf '%s\n' '{"decision":"block","reason":"In dieser Sitzung wurde eine blockierende Frage mit ask_question gestellt, die noch keine abgeholte Antwort hat. Beende die Sitzung noch nicht: rufe wait_for_events auf, um auf die Antwort des Nutzers zu warten, und hole danach die Antwort mit get_question (Frage-ID aus deinem ask_question-Ergebnis). Liegt noch keine Antwort vor, wiederhole wait_for_events hoechstens wenige Male und nenne dem Nutzer dann kurz, dass du auf die Antwort wartest."}'
    exit 0
  fi
fi
[ "$active" = "true" ] && exit 0
flag="${TMPDIR:-/tmp}/todolino-stop-$session"
[ -e "$flag" ] && exit 0
# Did this session call record_sync (any server naming: mcp__todolino__ or mcp__plugin_todolino_todolino__)?
grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*record_sync"' "$transcript" 2>/dev/null && exit 0
# Was anything changed? Only then Todolino can be out of date.
grep -Eq '"name": ?"(Edit|Write|MultiEdit|NotebookEdit)"' "$transcript" 2>/dev/null || exit 0
: > "$flag" 2>/dev/null || exit 0
printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber in dieser Sitzung wurde record_sync nicht aufgerufen, obwohl Dateien geaendert wurden. Bring das Board jetzt auf den aktuellen Stand: post_progress fuer die erledigte Arbeit, Status/Fragen/Review aktualisieren (import_plan fuer neue oder erledigte Plan-Punkte) und dann record_sync mit kurzer Zusammenfassung aufrufen. Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt nur einmal pro Sitzung."}'
exit 0
