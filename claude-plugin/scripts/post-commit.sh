#!/bin/sh
# PostToolUse after Bash: only when tool_input.command really runs "git commit" (or "git push"), in bound repositories
# remind the agent to mirror the work on the board. Quoted strings (echo "git commit", --grep "commit") are blanked
# before matching; chained commands (a && git commit), "git -C x commit" and env prefixes are handled.
. "$(dirname "$0")/lib.sh" 2>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
cwd=$(json_field cwd); [ -n "$cwd" ] || cwd=$(pwd)
find_marker "$cwd" >/dev/null || exit 0

# Raw (still JSON-escaped) body of tool_input.command.
raw=$(printf '%s' "$INPUT" | sed -n -E 's/.*"command" *: *"(([^"\\]|\\.)*)".*/\1/p' | head -n 1)
[ -n "$raw" ] || exit 0

# kind: prints "commit", "push" or nothing.
kind=$(printf '%s' "$raw" | awk '
function flush(seg,   s) {
  s = seg
  sub(/^[ \t]+/, "", s)
  while (s ~ /^[(){!]+[ \t]*/) sub(/^[(){!]+[ \t]*/, "", s)
  while (s ~ /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/, "", s)
  if (s ~ /^git([ \t]+(-C|-c|--git-dir|--work-tree|--namespace)[ \t]+[^ \t]+|[ \t]+--[a-z-]+=[^ \t]+|[ \t]+--(no-pager|bare|paginate|no-replace-objects|literal-pathspecs)|[ \t]+-p)*[ \t]+commit([ \t]|$)/) found = "commit"
  else if (s ~ /^git([ \t]+(-C|-c|--git-dir|--work-tree|--namespace)[ \t]+[^ \t]+|[ \t]+--[a-z-]+=[^ \t]+|[ \t]+--(no-pager|bare|paginate|no-replace-objects|literal-pathspecs)|[ \t]+-p)*[ \t]+push([ \t]|$)/) { if (found == "") found = "push" }
}
{
  txt = txt $0
}
END {
  # 1) JSON unescape into real characters (newline becomes \001 so the scan stays on one record)
  n = length(txt); cmd = ""; i = 1
  while (i <= n) {
    c = substr(txt, i, 1)
    if (c == "\\") {
      d = substr(txt, i + 1, 1); i += 2
      if (d == "n") cmd = cmd "\001"
      else if (d == "\"" || d == "\\" || d == "/") cmd = cmd d
      else cmd = cmd " "
    } else { cmd = cmd c; i++ }
  }
  # 2) shell scan: blank quoted text, split on ; & | newline, drop comments
  n = length(cmd); seg = ""; q = ""; found = ""; i = 1
  while (i <= n) {
    c = substr(cmd, i, 1)
    if (q == "\"") { if (c == "\\") i += 2; else { if (c == "\"") q = ""; i++ }; continue }
    if (q == "\x27") { if (c == "\x27") q = ""; i++; continue }
    if (c == "\\") { seg = seg "X"; i += 2; continue }
    if (c == "\"") { q = "\""; seg = seg "Q"; i++; continue }
    if (c == "\x27") { q = "\x27"; seg = seg "Q"; i++; continue }
    if (c == "\001" || c == ";" || c == "&" || c == "|") { flush(seg); seg = ""; i++; continue }
    if (c == "#" && (seg == "" || seg ~ /[ \t]$/)) {
      flush(seg); seg = ""
      while (i <= n && substr(cmd, i, 1) != "\001") i++
      continue
    }
    seg = seg c; i++
  }
  flush(seg)
  print found
}')

case "$kind" in
  commit)
    emit_context PostToolUse "Todolino: you just committed. Do it NOW, before the next step: post_progress on the task this commit belongs to (commit hash, what is done, what is next); if no task exists yet, create_task and claim_task first. Update information (this commit, tests) belongs into post_progress, not into a review; request_review only if the user has to look at or decide something concrete (never mark done yourself). Open user decision: ask_question. Keep it short, in bullet points. record_sync (with repository from .todolino.json if present) before the session ends." ;;
  push)
    emit_context PostToolUse "Todolino: you just pushed. If the board does not show it yet: post_progress on the task (what was pushed, what is next), short and in bullet points." ;;
esac
exit 0
