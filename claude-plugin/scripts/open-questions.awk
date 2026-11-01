# Prints "open" when the transcript (JSONL) holds a blocking ask_question without a later answer pickup.
# Evaluated per tool_use: a line is split before every "type":"tool_use" / "type":"tool_result" object, so a
# "blocking": false belongs only to its own call. blocking defaults to true. A question is handled when a later
# get_question names a UUID from the matching tool_result (minus UUIDs the ask itself carried, e.g. taskID), or a later
# list_open_questions with includeAnswered was called. Reads only structure and ids, never prints transcript text.
function uuids(t, out,   n, u) {
  n = 0
  while (match(t, /[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+/)) {
    u = toupper(substr(t, RSTART, RLENGTH)); t = substr(t, RSTART + RLENGTH)
    if (length(u) == 36) out[++n] = u
  }
  return n
}
function field(t, key,   v) {
  if (match(t, "\"" key "\": ?\"[^\"]*\"")) {
    v = substr(t, RSTART, RLENGTH); sub(/^[^:]*: ?"/, "", v); sub(/"$/, "", v); return v
  }
  return ""
}
{
  line = $0
  gsub(/"type": ?"tool_(use|result)"/, "\001&", line)
  np = split(line, parts, "\001")
  for (i = 1; i <= np; i++) {
    p = parts[i]
    if (p ~ /^"type": ?"tool_use"/) {
      if (p ~ /"name": ?"mcp__[A-Za-z0-9_-]*ask_question"/) {
        nq++; qline[nq] = NR; qtool[nq] = field(p, "id")
        qblock[nq] = (p ~ /"blocking": ?"?false"?/) ? 0 : 1
        nk = uuids(p, tmp); for (k = 1; k <= nk; k++) own[nq, tmp[k]] = 1
      } else if (p ~ /"name": ?"mcp__[A-Za-z0-9_-]*get_question"/) {
        nk = uuids(p, tmp); for (k = 1; k <= nk; k++) { ng++; gline[ng] = NR; gid[ng] = tmp[k] }
      } else if (p ~ /"name": ?"mcp__[A-Za-z0-9_-]*list_open_questions"/ && p ~ /"includeAnswered": ?"?true"?/) {
        lastlist = NR
      }
    } else if (p ~ /^"type": ?"tool_result"/) {
      tid = field(p, "tool_use_id")
      for (q = 1; q <= nq; q++) if (tid != "" && qtool[q] == tid) {
        nk = uuids(p, tmp)
        for (k = 1; k <= nk; k++) if (!((q, tmp[k]) in own)) { nr[q]++; rid[q, nr[q]] = tmp[k] }
      }
    }
  }
}
END {
  for (q = 1; q <= nq; q++) {
    if (!qblock[q]) continue
    handled = (lastlist > qline[q])
    for (g = 1; g <= ng && !handled; g++) if (gline[g] >= qline[q])
      for (r = 1; r <= nr[q]; r++) if (rid[q, r] == gid[g]) handled = 1
    if (!handled) { print "open"; exit }
  }
}
