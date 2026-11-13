#!/usr/bin/env python3
"""End-to-end check of the live view per card (ADR 0031) against a running backend: REST and MCP, two accounts.

Real HTTP and a real OAuth token for /mcp (register, authorize, consent, PKCE token). Retention is checked by moving the card's
updated_at back in the scratch SQLite and running the real `cleanup-expired` command (no waiting).
Usage: live-session-e2e.py BASE_URL SESSION_A SESSION_B SQLITE_FILE APP_BINARY BACKEND_LOG
"""
import base64, hashlib, json, os, re, sqlite3, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, uuid

base, sess_a, sess_b, db_path, native, log_path = sys.argv[1:7]
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)

def http(method, path, body=None, token=None, headers=None):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with opener.open(req) as r: return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e: return e.code, e.read(), e.headers

def j(b):
    try: return json.loads(b)
    except Exception: return None

def live(task, query="", tok=sess_a):
    st, b, _ = http("GET", f"/v1/tasks/{task}/live{query}", token=tok); return st, j(b), b

# Cards: A owns a project and two tasks; B is a stranger.
st, b, _ = http("POST", "/v1/projects", {"name": "Live E2E"}, sess_a); project = j(b)["id"]
def new_task(title):
    st, b, _ = http("POST", "/v1/tasks", {"projectID": project, "title": title}, sess_a); return j(b)
t1, t2, t3 = new_task("Live card"), new_task("Done card"), new_task("Reopened card")

# MCP with a real OAuth token
def oauth_token(scope):
    st, b, _ = http("POST", "/oauth/register", {"client_name": "Live E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = j(b)["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    st, b, _ = http("GET", "/.well-known/oauth-protected-resource/mcp")
    resource = j(b)["resource"]
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client, "redirect_uri": "http://127.0.0.1:54321/callback", "scope": scope,
        "state": "s", "resource": resource, "code_challenge": challenge, "code_challenge_method": "S256"})
    st, b, _ = http("GET", "/oauth/authorize?" + q, token=sess_a, headers={"Accept": "application/json"})
    if st != 200: raise SystemExit(f"authorize failed: {st} {b[:200]}")
    consent = j(b)["consent_token"]
    st, b, _ = http("POST", "/oauth/consent", {"consent_token": consent, "approve": True, "project_ids": [project]}, sess_a)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(j(b)["redirect_uri"]).query)["code"][0]
    st, b, _ = http("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client, "resource": resource, "code": code,
        "redirect_uri": "http://127.0.0.1:54321/callback", "code_verifier": verifier})
    return j(b)["access_token"]

def rpc(tok, method, params=None):
    st, b, _ = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, tok)
    return st, j(b)

def tool(tok, name, args):
    st, body = rpc(tok, "tools/call", {"name": name, "arguments": args})
    res = body["result"]; text = res["content"][0]["text"]
    return res.get("isError", False), text, j(text)

readonly = oauth_token("projects:read tasks:read")
agent = oauth_token("projects:read tasks:read tasks:write")
names = lambda tok: [t["name"] for t in rpc(tok, "tools/list")[1]["result"]["tools"]]
check("write connection sees all three tools", {"report_session_step", "report_session_event", "get_task_live"} <= set(names(agent)))
check("read-only connection sees get_task_live but not the report tools",
      "get_task_live" in names(readonly) and "report_session_step" not in names(readonly) and "report_session_event" not in names(readonly))
err, text, _ = tool(readonly, "report_session_step", {"taskID": t1["id"], "step": "x"})
check("read-only connection report is insufficient_scope", err and text == "insufficient_scope", text)

# Empty live view
st, body, _ = live(t1["id"])
check("REST live view of a card without reports is empty", st == 200 and body["sessions"] == [] and body["items"] == [], (st, body))
st, _, _ = http("GET", f"/v1/tasks/{t1['id']}/live")
check("anonymous GET 401", st == 401, st)

# Step and events
err, text, sess = tool(agent, "report_session_step", {"taskID": t1["id"], "step": "Lese die Karte", "session": "Mac Studio", "model": "claude-x", "agentName": "Claude Code"})
check("MCP report_session_step creates an active session", not err and sess["status"] == "active" and sess["currentStep"] == "Lese die Karte" and sess["name"] == "Mac Studio", text)
err, text, ev = tool(agent, "report_session_event", {"taskID": t1["id"], "session": "Mac Studio", "kind": "tool", "text": "swift test --filter LiveSessionTests"})
check("MCP report_session_event tool", not err and ev["kind"] == "tool", text)
key = str(uuid.uuid4())
err, text, q1 = tool(agent, "report_session_event", {"taskID": t1["id"], "session": "Mac Studio", "kind": "question", "text": "Soll der Filter Hex maskieren?", "clientUUID": key})
err2, text2, q2 = tool(agent, "report_session_event", {"taskID": t1["id"], "session": "Mac Studio", "kind": "question", "text": "Soll der Filter Hex maskieren?", "clientUUID": key})
check("same clientUUID returns the original event", not err and not err2 and q1["id"] == q2["id"], (text, text2))
err, text, _ = tool(agent, "report_session_event", {"taskID": t1["id"], "session": "Mac Studio", "kind": "question", "text": "anderer Text", "clientUUID": key})
check("same clientUUID with another text is client_uuid_conflict", err and "client_uuid_conflict" in text, text)

# A secret: masked in REST, MCP and the log
secret = "ghp_1234567890abcdefghijklmnopqrstuvwxyzAB"
err, text, sec = tool(agent, "report_session_event", {"taskID": t1["id"], "session": "Mac Studio", "kind": "note", "text": f"git push https://lino:{secret}@github.com/x/y.git password=hunter2hunter2"})
check("secret event is accepted and masked in the answer", not err and secret not in text and "hunter2hunter2" not in text and "[gefiltert]" in sec["text"], text)
err, text, _ = tool(agent, "report_session_step", {"taskID": t1["id"], "step": f"Authorization: Bearer {secret}", "session": "Mac Studio"})
check("secret step is masked", not err and secret not in text and "[gefiltert]" in text, text)
st, body, raw = live(t1["id"])
check("REST live view: one session, newest first, no secret", st == 200 and len(body["sessions"]) == 1 and secret.encode() not in raw and b"hunter2hunter2" not in raw, (st, raw[:300]))
kinds = [e["kind"] for e in body["items"]]
check("REST items: step, tool, question, note, step in reverse order", kinds == ["step", "note", "question", "tool", "step"], kinds)
ms = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
check("timestamps carry milliseconds", all(ms.match(e["createdAt"]) for e in body["items"]) and ms.match(body["serverTime"]) and ms.match(body["sessions"][0]["lastSeenAt"]), body["items"][0])
check("session shows current step, label, model and no stale flag", body["sessions"][0]["actorLabel"] == "Claude Code" and body["sessions"][0]["model"] == "claude-x"
      and body["sessions"][0]["stale"] is False and "[gefiltert]" in body["sessions"][0]["currentStep"], body["sessions"][0])
err, text, via = tool(readonly, "get_task_live", {"taskID": t1["id"]})
check("MCP get_task_live (read scope) matches REST and holds no secret", not err and secret not in text and [e["id"] for e in via["items"]] == [e["id"] for e in body["items"]], text)
st, page1, _ = live(t1["id"], "?limit=2")
st, page2, _ = live(t1["id"], "?limit=2&cursor=" + urllib.parse.quote(page1["nextCursor"]))
check("pagination: 2 + 2 events, no overlap", len(page1["items"]) == 2 and len(page2["items"]) == 2 and not {e["id"] for e in page1["items"]} & {e["id"] for e in page2["items"]})
for bad in ("limit=0", "limit=201", "cursor=garbage", "since=yesterday"):
    st, _, _ = live(t1["id"], "?" + bad)
    check(f"bad query {bad} 400", st == 400, st)
err, text, _ = tool(agent, "report_session_event", {"taskID": t1["id"], "kind": "note", "text": "a" * 281})
check("text over 280 characters is rejected", err and "invalid_text" in text, text)
err, text, ended = tool(agent, "report_session_step", {"taskID": t1["id"], "session": "Mac Studio", "ended": True})
check("ended closes the session", not err and ended["status"] == "ended" and ended.get("endedAt"), text)

# Rights: stranger and a card outside the account
st, _, _ = live(t1["id"], tok=sess_b)
check("foreign account GET live is 404", st == 404, st)
st, _, _ = live(str(uuid.uuid4()))
check("unknown card is 404", st == 404, st)
st, b, _ = http("POST", "/v1/projects", {"name": "Foreign"}, sess_b); fproject = j(b)["id"]
st, b, _ = http("POST", "/v1/tasks", {"projectID": fproject, "title": "B's card"}, sess_b); ftask = j(b)
err, text, _ = tool(agent, "report_session_step", {"taskID": ftask["id"], "step": "hack"})
check("MCP report on a foreign card is not_found", err and text == "not_found", text)
err, text, _ = tool(agent, "get_task_live", {"taskID": ftask["id"]})
check("MCP read of a foreign card is not_found", err and text == "not_found", text)
st, body, _ = live(ftask["id"], tok=sess_b)
check("B sees nothing of A's reports on its own card", st == 200 and body["sessions"] == [] and body["items"] == [], body)

# Review follow-up: two actors, combining-mark bomb, German password, done card
agent2 = oauth_token("projects:read tasks:read tasks:write")
err, text, _ = tool(agent2, "report_session_step", {"taskID": t1["id"], "session": "Mac Studio", "step": "übernommen", "ended": True, "agentName": "Evil"})
check("second connection cannot take over a session name (409)", err and "session_name_taken" in text, text)
err, text, own = tool(agent2, "report_session_step", {"taskID": t1["id"], "session": "Zweiter", "step": "eigene Session"})
check("second connection uses its own session", not err and own["name"] == "Zweiter", text)
st, body, _ = live(t1["id"])
mine = [x for x in body["sessions"] if x["name"] == "Mac Studio"][0]
check("first session untouched by the second connection", mine["actorLabel"] == "Claude Code" and mine["status"] == "ended" and "übernommen" not in str(body["items"]), mine)
bomb = "a" + "\u0301" * 200000
err, text, _ = tool(agent, "report_session_event", {"taskID": t1["id"], "kind": "note", "text": bomb})
check("combining-mark bomb is rejected", err and "invalid_text" in text, text[:100])
err, text, de = tool(agent, "report_session_event", {"taskID": t1["id"], "kind": "note", "text": "Das Passwort: Geheim123x und --password hunter2z"})
check("German password and CLI flag are masked", not err and "Geheim123x" not in text and "hunter2z" not in text and "[gefiltert]" in de["text"], text)

# Live refresh: the token changes with a report
st, b, _ = http("GET", "/v1/sync/head", token=sess_a); before = j(b)["token"]
tool(agent, "report_session_event", {"taskID": t1["id"], "kind": "progress", "text": "50 Prozent"})
st, b, _ = http("GET", "/v1/sync/head", token=sess_a); after = j(b)["token"]
check("a report changes the live-refresh token", before != after, (before, after))

# Retention: done card (t2) and a card that was done and reopened (t3), both with reports
for t in (t2, t3):
    tool(agent, "report_session_step", {"taskID": t["id"], "step": "arbeite"})
    tool(agent, "report_session_event", {"taskID": t["id"], "kind": "note", "text": "n"})
t3now = None
for t in (t2, t3):
    st, b, _ = http("PATCH", f"/v1/tasks/{t['id']}", {"version": t["version"], "status": "done"}, sess_a)
    check(f"task {t['title']} set to done", st == 200, (st, b))
    if t is t3: t3now = j(b)
st, b, _ = http("PATCH", f"/v1/tasks/{t3['id']}", {"version": t3now["version"], "status": "open"}, sess_a)
check("reopened task is open again", st == 200 and j(b)["status"] == "open", (st, b))

err, text, _ = tool(agent, "report_session_event", {"taskID": t2["id"], "kind": "note", "text": "zu spät"})
check("report for a done card is refused (task_done)", err and "task_done" in text, text)

def counts():
    con = sqlite3.connect(db_path, timeout=20)
    def n(table, tid): return con.execute(f"SELECT COUNT(*) FROM {table} WHERE task_id = ?", (tid.upper(),)).fetchone()[0]
    out = {}
    for name, t in (("t1", t1), ("t2", t2), ("t3", t3)):
        out[name] = (n("task_live_sessions", t["id"]), n("task_live_events", t["id"]))
    con.close(); return out
before_counts = counts()
check("before cleanup every card has data", all(s >= 1 and e >= 1 for s, e in before_counts.values()), before_counts)

def run_cleanup():
    r = subprocess.run([native, "cleanup-expired"], capture_output=True, text=True, env=os.environ)
    return r.returncode, r.stdout + r.stderr

rc, out = run_cleanup()
check("cleanup right after done removes nothing (3-day period)", rc == 0 and counts() == before_counts, (rc, out, counts()))
# Time shift: done 4 days ago for t2 (and for t3, which is open again)
con = sqlite3.connect(db_path, timeout=20)
old = time.time() - 4 * 86400
for t in (t2, t3):
    con.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", (old, t["id"].upper()))
con.commit(); con.close()
rc, out = run_cleanup()
after_counts = counts()
check("cleanup 4 days after done deletes the done card's session and events", rc == 0 and after_counts["t2"] == (0, 0), (rc, out, after_counts))
check("reopened card keeps its data despite the old timestamp", after_counts["t3"] == before_counts["t3"], after_counts)
check("an open card with reports keeps its data", after_counts["t1"] == before_counts["t1"], after_counts)
rc, out = run_cleanup()
check("cleanup is idempotent", rc == 0 and counts() == after_counts, (rc, out))
st, body, _ = live(t2["id"])
check("REST live view of the cleaned card is empty but readable", st == 200 and body["sessions"] == [] and body["items"] == [], (st, body))
st, b, _ = http("DELETE", f"/v1/tasks/{t1['id']}", token=sess_a)
con = sqlite3.connect(db_path, timeout=20)
left = con.execute("SELECT COUNT(*) FROM task_live_sessions WHERE task_id = ?", (t1["id"].upper(),)).fetchone()[0] + con.execute("SELECT COUNT(*) FROM task_live_events WHERE task_id = ?", (t1["id"].upper(),)).fetchone()[0]
con.close()
check("deleting the card removes its live data (cascade)", st in (200, 204) and left == 0, (st, left))

# No report text in the backend log
log = open(log_path, errors="replace").read()
for needle in (secret, "Geheim123x", "hunter2z", "hunter2hunter2", "Soll der Filter Hex maskieren", "Lese die Karte"):
    check(f"backend log does not contain {needle[:20]!r}", needle not in log)

print(f"\n{len(failures)} failure(s)" if failures else "\nall checks passed")
sys.exit(1 if failures else 0)
