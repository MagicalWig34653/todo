#!/bin/sh
# Stop: in a repository bound to Todolino (.todolino.json) block the end of a turn when work happened without board
# activity (once per new work state, see third duty) or when files were changed but record_sync was never called in
# this session (once per session). Never loops (stop_hook_active, at most one block per turn, state markers),
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
# Third duty (board usage): work (Edit/Write or git commit) happened after the last board activity (post_progress,
# request_review, ask_question or record_sync as tool_use name, in the session or a subagent transcript) -> reminder,
# ONCE PER NEW WORK STATE: a fingerprint (git HEAD + hash of "git status --porcelain -uall" + diff shortstat) is kept in a
# private marker file; the same fingerprint never blocks twice, a new commit or changed files do again, however long
# the session runs. TODOLINO_STOP_MAX caps the reminders per session (default 20, 0 = unlimited). Without git or
# outside a repository this duty stays silent (fail open). Tool names only count as tool_use names; transcript text is
# never quoted.
counter="$dir/board-$session"
fpfile="$dir/boardfp-$session"
max="${TODOLINO_STOP_MAX:-20}"
case "$max" in *[!0-9]*|"") max=20 ;; esac
# Subagent transcripts live next to the session transcript (<session>/subagents/*.jsonl); their board calls count too.
subdir="${transcript%.jsonl}/subagents"
BOARD_RE='"name": ?"mcp__[A-Za-z0-9_-]*(post_progress|request_review|ask_question|record_sync)"'
used() {
  grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*'"$1"'"' "$transcript" 2>/dev/null && return 0
  [ -d "$subdir" ] && [ ! -L "$subdir" ] || return 1
  for f in "$subdir"/*.jsonl; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*'"$1"'"' "$f" 2>/dev/null && return 0
  done
  return 1
}
edited=0
grep -Eq '"name": ?"(Edit|Write|MultiEdit|NotebookEdit)"' "$transcript" 2>/dev/null && edited=1
committed=0
grep -Eq '"name": ?"Bash".*git commit' "$transcript" 2>/dev/null && committed=1
if [ "$edited" = 1 ] || [ "$committed" = 1 ]; then
  command -v git >/dev/null 2>&1 || exit 0
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0
  head=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || head=nohead
  st=$(git -C "$cwd" status --porcelain --untracked-files=all 2>/dev/null | cksum) || exit 0
  df=$(git -C "$cwd" diff HEAD --shortstat 2>/dev/null | cksum)
  fp="$head $st $df"
  { [ -L "$fpfile" ] || [ -L "$counter" ]; } && exit 0
  stored=$(cat "$fpfile" 2>/dev/null)
  # Position (line number) of the last work and the last board call in the main transcript.
  lastwork=$(grep -nE '"name": ?"(Edit|Write|MultiEdit|NotebookEdit)"|"name": ?"Bash".*git commit' "$transcript" 2>/dev/null | tail -n 1 | cut -d: -f1)
  lastboard=$(grep -nE "$BOARD_RE" "$transcript" 2>/dev/null | tail -n 1 | cut -d: -f1)
  board_after=0
  if [ -n "$lastboard" ] && [ "$lastboard" -ge "${lastwork:-0}" ]; then board_after=1; fi
  # Subagent board calls have no position: they count as current when their transcript is newer than the marker.
  if [ "$board_after" = 0 ] && [ -d "$subdir" ] && [ ! -L "$subdir" ]; then
    for f in "$subdir"/*.jsonl; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      grep -Eq "$BOARD_RE" "$f" 2>/dev/null || continue
      if [ ! -e "$fpfile" ] || [ "$f" -nt "$fpfile" ]; then board_after=1; break; fi
    done
  fi
  if [ "$board_after" = 1 ]; then
    safe_write "$fpfile" "$fp" || exit 0
  elif [ "$fp" != "$stored" ]; then
    n=$(cat "$counter" 2>/dev/null); case "$n" in *[!0-9]*|"") n=0 ;; esac
    if [ "$max" = 0 ] || [ "$n" -lt "$max" ]; then
      safe_write "$counter" $((n + 1)) || exit 0
      safe_write "$fpfile" "$fp" || exit 0
      safe_write "$flag" ""
      printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber seit der letzten Board-Aktivitaet gab es neue Aenderungen oder Commits (kein post_progress, request_review, ask_question oder record_sync danach). Aktualisiere jetzt das Board: passende Aufgabe suchen oder mit create_task anlegen (keine Duplikate), claim_task, post_progress mit dem erledigten Stand und dem naechsten Schritt, bei belegter Fertigstellung (gemergt, Tests gruen, nichts zu entscheiden) Karte selbst per update_task auf done, bei sichtbarem Ergebnis/Risiko/Rollout request_review, offene Entscheidungen des Nutzers als ask_question auf der Aufgabe, danach record_sync (mit repository aus .todolino.json, falls vorhanden). Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt einmal je neuem Arbeitsstand, nicht erneut bei unveraendertem Stand."}'
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
printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber in dieser Sitzung wurde record_sync nicht aufgerufen, obwohl Dateien geaendert wurden. Bring das Board jetzt auf den aktuellen Stand: post_progress fuer die erledigte Arbeit, Status/Fragen/Review aktualisieren (import_plan fuer neue oder erledigte Plan-Punkte) und dann record_sync mit kurzer Zusammenfassung aufrufen (mit repository aus .todolino.json, falls vorhanden). Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt nur einmal pro Sitzung."}'
exit 0
