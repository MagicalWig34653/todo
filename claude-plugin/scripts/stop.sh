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
# Open blocking question, judged per ask_question tool_use by open-questions.awk (blocking:false never counts; a
# question is handled by a later get_question with its id or list_open_questions includeAnswered).
ASK_WAIT_MAX=${TODOLINO_ASK_WAIT_MAX:-6}
case "$ASK_WAIT_MAX" in *[!0-9]*|"") ASK_WAIT_MAX=6 ;; esac
# State files live only in a private 0700 directory owned by us; symlinks are never followed.
state=$(private_dir) || exit 0
askflag="$state/askwait-$session"
if grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*ask_question"' "$transcript" 2>/dev/null; then
  open=$(awk -f "$(dirname "$0")/open-questions.awk" "$transcript" 2>/dev/null)
  used=0; [ -f "$askflag" ] && [ ! -L "$askflag" ] && used=$(wc -l < "$askflag" 2>/dev/null | tr -d ' ')
  # Under stop_hook_active only continue a chain that this hook started itself.
  if [ "$open" = "open" ] && [ "${used:-0}" -lt "$ASK_WAIT_MAX" ] && { [ "$active" != "true" ] || [ "${used:-0}" -gt 0 ]; }; then
    [ -L "$askflag" ] && exit 0
    echo x >> "$askflag" 2>/dev/null || exit 0
    printf '%s\n' '{"decision":"block","reason":"In dieser Sitzung wurde eine blockierende Frage mit ask_question gestellt, die noch keine abgeholte Antwort hat. Beende die Sitzung noch nicht: rufe wait_for_events auf, um auf die Antwort des Nutzers zu warten, und hole danach die Antwort mit get_question (Frage-ID aus deinem ask_question-Ergebnis). Lies dabei auch neue Chat-Nachrichten des Nutzers zu dieser Frage (list_comments mit questionID und authorKind person) und antworte mit add_comment. Liegt noch keine Antwort vor, wiederhole wait_for_events hoechstens wenige Male und nenne dem Nutzer dann kurz, dass du auf die Antwort wartest."}'
    exit 0
  fi
fi
[ "$active" = "true" ] && exit 0
dir="$state"
flag="$dir/stop-$session"
# Third duty (board usage): files changed or commits made, but no post_progress/request_review/ask_question call in
# the transcript -> reminder, at most TODOLINO_STOP_MAX (default 1) times per session (counter file). Tool names only
# count as tool_use names; transcript text is never quoted.
counter="$dir/board-$session"
max="${TODOLINO_STOP_MAX:-1}"
case "$max" in *[!0-9]*|"") max=1 ;; esac
used() { grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*'"$1"'"' "$transcript" 2>/dev/null; }
edited=0
grep -Eq '"name": ?"(Edit|Write|MultiEdit|NotebookEdit)"' "$transcript" 2>/dev/null && edited=1
committed=0
grep -Eq '"name": ?"Bash".*git commit' "$transcript" 2>/dev/null && committed=1
if [ "$edited" = 1 ] || [ "$committed" = 1 ]; then
  if ! used post_progress && ! used request_review && ! used ask_question; then
    n=$(cat "$counter" 2>/dev/null); case "$n" in *[!0-9]*|"") n=0 ;; esac
    if [ "$n" -lt "$max" ]; then
      safe_write "$counter" $((n + 1)) || exit 0
      safe_write "$flag" ""
      printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber in dieser Sitzung gab es Aenderungen oder Commits ohne Board-Aktivitaet (kein post_progress, request_review oder ask_question). Aktualisiere jetzt das Board: passende Aufgabe suchen oder mit create_task anlegen (keine Duplikate), claim_task, post_progress mit dem erledigten Stand und dem naechsten Schritt, bei Fertigstellung request_review (nie selbst auf erledigt setzen), offene Entscheidungen des Nutzers als ask_question auf der Aufgabe, danach record_sync. Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt hoechstens einmal pro Sitzung."}'
      exit 0
    fi
  fi
fi
[ -e "$flag" ] && exit 0
# Did this session call record_sync (any server naming: mcp__todolino__ or mcp__plugin_todolino_todolino__)?
used record_sync && exit 0
# Was anything changed? Only then Todolino can be out of date.
[ "$edited" = 1 ] || exit 0
safe_write "$flag" "" || exit 0
printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber in dieser Sitzung wurde record_sync nicht aufgerufen, obwohl Dateien geaendert wurden. Bring das Board jetzt auf den aktuellen Stand: post_progress fuer die erledigte Arbeit, Status/Fragen/Review aktualisieren (import_plan fuer neue oder erledigte Plan-Punkte) und dann record_sync mit kurzer Zusammenfassung aufrufen. Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt nur einmal pro Sitzung."}'
exit 0
