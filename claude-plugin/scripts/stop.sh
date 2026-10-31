#!/bin/sh
# Stop: in a repository bound to Todolino (.todolino.json) block the end of a turn ONCE per session when files were
# changed but record_sync was never called in this session. Never loops (stop_hook_active, per-session marker),
# fails open on every error, needs no network and handles no secrets.
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
flag="${TMPDIR:-/tmp}/todolino-stop-$session"
[ -e "$flag" ] && exit 0
# Did this session call record_sync (any server naming: mcp__todolino__ or mcp__plugin_todolino_todolino__)?
grep -Eq '"name": ?"mcp__[A-Za-z0-9_-]*record_sync"' "$transcript" 2>/dev/null && exit 0
# Was anything changed? Only then Todolino can be out of date.
grep -Eq '"name": ?"(Edit|Write|MultiEdit|NotebookEdit)"' "$transcript" 2>/dev/null || exit 0
: > "$flag" 2>/dev/null || exit 0
printf '%s\n' '{"decision":"block","reason":"Todolino ist in diesem Repository eingerichtet (.todolino.json), aber in dieser Sitzung wurde record_sync nicht aufgerufen, obwohl Dateien geaendert wurden. Bring das Board jetzt auf den aktuellen Stand: post_progress fuer die erledigte Arbeit, Status/Fragen/Review aktualisieren (import_plan fuer neue oder erledigte Plan-Punkte) und dann record_sync mit kurzer Zusammenfassung aufrufen. Wenn Todolino nicht erreichbar ist, nenne das dem Nutzer kurz und beende dann die Sitzung. Diese Erinnerung kommt nur einmal pro Sitzung."}'
exit 0
