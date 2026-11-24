#!/usr/bin/env python3
"""End-to-end check of the overview block `now`, the compact answer and ending a session status (card 692891DF, ADR 0034
addendum 24.11.2026, contract session-status 1.4.0) against a running backend: REST (sessions) and MCP over HTTP with a real
OAuth token, two accounts.

The case "no sign of life" is checked with a time shift in the scratch SQLite (like live-session-e2e.py): the card's signs of
life and a session's updated_at are moved back by sqlite3, then the answer is read again. The 24 hour cleanup uses the real
`cleanup-expired` command.
Usage: overview-now-e2e.py BASE_URL SESSION_A SESSION_B SQLITE_FILE APP_BINARY BACKEND_LOG
"""
import base64, hashlib, json, os, sqlite3, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

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
        with opener.open(req) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def j(b):
    try: return json.loads(b)
    except Exception: return None

st, b = http("POST", "/v1/projects", {"name": "Now E2E"}, sess_a); project = j(b)["id"]
st, b = http("POST", "/v1/projects", {"name": "Fremd E2E"}, sess_b); foreign = j(b)["id"]
def new_task(title, proj=None, token=sess_a):
    st, b = http("POST", "/v1/tasks", {"projectID": proj or project, "title": title}, token); return j(b)
t_run, t_wait_q, t_wait_r, t_done = new_task("Laeuft"), new_task("Mit Frage"), new_task("Zur Pruefung"), new_task("Fertig")
t_foreign = new_task("Geheimes Fremdes", foreign, sess_b)

def oauth_token(scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Now E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = j(b)["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    st, b = http("GET", "/.well-known/oauth-protected-resource/mcp")
    resource = j(b)["resource"]
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client, "redirect_uri": "http://127.0.0.1:54321/callback", "scope": scope,
        "state": "s", "resource": resource, "code_challenge": challenge, "code_challenge_method": "S256"})
    st, b = http("GET", "/oauth/authorize?" + q, token=sess_a, headers={"Accept": "application/json"})
    if st != 200: raise SystemExit(f"authorize failed: {st} {b[:200]}")
    st, b = http("POST", "/oauth/consent", {"consent_token": j(b)["consent_token"], "approve": True, "project_ids": [project]}, sess_a)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(j(b)["redirect_uri"]).query)["code"][0]
    st, b = http("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client, "resource": resource, "code": code,
        "redirect_uri": "http://127.0.0.1:54321/callback", "code_verifier": verifier})
    return j(b)["access_token"]

def tool(tok, name, args):
    st, b = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}, tok)
    res = j(b)["result"]; text = res["content"][0]["text"]
    return res.get("isError", False), text, j(text)

agent = oauth_token("projects:read tasks:read tasks:write")
reader = oauth_token("projects:read tasks:read")

def now(query="", tok=sess_a):
    st, b = http("GET", "/v1/overview/now" + query, token=tok); return st, j(b), len(b)
def block(query=""):
    st, body, _ = now(query); return body["now"]
def titles(blk, key): return [x["title"] for x in blk[key]]

con = sqlite3.connect(db_path, timeout=20)
def session_rows(): return con.execute("SELECT session_name FROM session_statuses ORDER BY session_name").fetchall()

# Empty start: the block is there and empty.
st, body, _ = now()
check("fresh overview has the block now with zero counts", st == 200 and body["now"]["counts"] == {"running": 0, "waiting": 0, "recentlyDone": 0, "silent": 0} and "projects" in body, body)
st, _, _ = now(tok=None)
check("anonymous overview is 401", st == 401, st)

# 1. Claim + progress -> running (MCP, as an agent does it)
err, text, _ = tool(agent, "claim_task", {"taskID": t_run["id"], "agentName": "Claude E2E"})
check("claim_task works", not err, text)
err, text, _ = tool(agent, "post_progress", {"taskID": t_run["id"], "note": "Baue den\nMigrationstest", "percent": 40})
check("post_progress works", not err, text)
blk = block()
row = next((x for x in blk["running"] if x.get("taskID") == t_run["id"]), None)
check("claimed card with fresh progress is running", row is not None and row["kind"] == "task" and row["projectName"] == "Now E2E", blk)
check("running row carries one-line text, worker and percent", row is not None and row["text"] == "Baue den Migrationstest" and row["worker"] == "Claude E2E" and row["percent"] == 40, row)
check("counts match the lists", blk["counts"]["running"] == len(blk["running"]) == 1 and blk["counts"]["silent"] == 0, blk["counts"])

# 2. Session report -> running; "Beendet ..." -> neither running nor silent
err, text, _ = tool(agent, "report_session_status", {"projectID": project, "sessionName": "Mac Studio", "activity": "Schreibe E2E"})
check("report_session_status works", not err, text)
st, b = http("PUT", f"/v1/projects/{project}/session-status", {"sessionName": "Window 2", "activity": "Beendet: alles erledigt"}, sess_a)
check("REST report of a 'Beendet' sentence is stored (200)", st == 200, (st, b))
blk = block()
check("session shows up as running", "Mac Studio" in titles(blk, "running") and any(x["kind"] == "session" and x["text"] == "Schreibe E2E" for x in blk["running"]), blk)
check("a 'Beendet ...' session is neither running nor silent", "Window 2" not in titles(blk, "running") + titles(blk, "silent"), blk)
st, body, _ = now()
names = [s["sessionName"] for s in body["projects"][0]["sessions"]]
check("projects[].sessions still lists it (unchanged)", "Window 2" in names and "Mac Studio" in names, names)

# 3. Ending a session deletes the row (REST and MCP, idempotent, no rate limit)
check("both rows exist in the database", session_rows() == [("Mac Studio",), ("Window 2",)], session_rows())
st, b = http("PUT", f"/v1/projects/{project}/session-status", {"sessionName": "Mac Studio", "ended": True}, sess_a)
r = j(b)
check("ending right after the report is allowed (no 10 s limit)", st == 200 and r["ended"] is True and r["activity"] == "", (st, b))
check("the row is gone", session_rows() == [("Window 2",)], session_rows())
st, b = http("PUT", f"/v1/projects/{project}/session-status", {"sessionName": "Mac Studio", "ended": True}, sess_a)
check("ending again is idempotent (200)", st == 200, (st, b))
err, text, r = tool(agent, "report_session_status", {"projectID": project, "sessionName": "Window 2", "ended": True})
check("MCP ended=true without activity deletes the other row", not err and r["ended"] is True and session_rows() == [], (text, session_rows()))
err, text, _ = tool(agent, "report_session_status", {"projectID": project, "sessionName": "Window 2", "ended": True})
check("MCP ending an unknown name is fine", not err, text)
st, b = http("PUT", f"/v1/projects/{project}/session-status", {"sessionName": "Mac Studio"}, sess_a)
check("without ended the activity stays required (400 invalid_activity)", st == 400 and j(b).get("reason") == "invalid_activity", (st, b))
blk = block()
check("ended sessions are gone from now", not [x for x in blk["running"] + blk["silent"] if x["kind"] == "session"], blk)
st, b = http("PUT", f"/v1/projects/{project}/session-status", {"sessionName": "Fremd", "ended": True}, sess_b)
check("a stranger cannot end sessions in the project (404)", st == 404, (st, b))
st, b = http("PUT", f"/v1/projects/{project}/session-status", {"sessionName": "Mac Studio", "activity": "x"}, sess_a)
check("a new report after ending works", st == 200, (st, b))
err, text, _ = tool(reader, "report_session_status", {"projectID": project, "sessionName": "Mac Studio", "ended": True})
check("a read-only connection cannot end (insufficient_scope)", err and text == "insufficient_scope", text)
check("the rejected end deleted nothing", session_rows() == [("Mac Studio",)], session_rows())

# 4. Waiting: open question and pending review
err, text, _ = tool(agent, "ask_question", {"taskID": t_wait_q["id"], "prompt": "Welche Farbe soll der Button haben?"})
check("ask_question works", not err, text)
err, text, _ = tool(agent, "request_review", {"taskID": t_wait_r["id"], "summary": "Migration fertig, bitte pruefen."})
check("request_review works", not err, text)
blk = block()
kinds = sorted(x["kind"] for x in blk["waiting"])
check("waiting has the question and the review", kinds == ["question", "review"] and blk["counts"]["waiting"] == 2, blk["waiting"])
check("waiting entries name card and project", all(x["projectName"] == "Now E2E" and x["taskTitle"] in ("Mit Frage", "Zur Pruefung") and x["text"] for x in blk["waiting"]), blk["waiting"])
check("newest first", blk["waiting"][0]["createdAt"] >= blk["waiting"][1]["createdAt"], blk["waiting"])

# 5. Recently done: a card set to done moments ago
st, b = http("PATCH", f"/v1/tasks/{t_done['id']}", {"version": t_done["version"], "status": "done"}, sess_a)
check("card set to done (200)", st == 200, (st, b))
blk = block()
check("recentlyDone lists the card", [x["title"] for x in blk["recentlyDone"]] == ["Fertig"] and blk["counts"]["recentlyDone"] == 1, blk["recentlyDone"])

# 6. Rights: nothing of the stranger's project, MCP stays inside its grant
check("the stranger's project does not appear anywhere", "Geheimes Fremdes" not in json.dumps(block()) and "Fremd E2E" not in json.dumps(block()))
st, body, _ = now(tok=sess_b)
check("the stranger sees only their own project in now", st == 200 and [x["title"] for x in body["now"]["silent"] + body["now"]["running"]] == [], body["now"])

# 7. Compact answer
st, body, small = now("?compact=true")
st2, full_body, large = now()
check("compact has only serverTime and now", st == 200 and set(body.keys()) == {"serverTime", "now"}, list(body.keys()))
check("compact is smaller than the full answer", small < large, (small, large))
for bad in ("0", "51", "abc", "-3"):
    st, _, _ = now(f"?compact=true&limit={bad}")
    check(f"limit={bad} is 400", st == 400, st)
st, body, _ = now("?compact=true&limit=1")
check("limit=1 cuts the lists but counts stay totals", st == 200 and all(len(body["now"][k]) <= 1 for k in ("running", "waiting", "recentlyDone", "silent")) and body["now"]["counts"]["waiting"] == 2, body["now"])
err, text, r = tool(agent, "get_overview_now", {"compact": True, "limit": 5})
check("MCP get_overview_now compact", not err and set(r.keys()) == {"serverTime", "now"}, text[:200])
err, text, r = tool(agent, "get_overview_now", {})
check("MCP get_overview_now without arguments is the full answer plus now", not err and "projects" in r and "now" in r, text[:200])
err, text, _ = tool(agent, "get_overview_now", {"compact": True, "limit": 99})
check("MCP limit out of range is invalid_limit", err and "invalid_limit" in text, text)
st, body, _ = now("?compact=true&limit=50")
long_text = "Lang " * 80
tool(agent, "post_progress", {"taskID": t_run["id"], "note": long_text})
body = block("?compact=true")
row = next(x for x in body["running"] if x.get("taskID") == t_run["id"])
check("compact shortens texts to 140 characters with an ellipsis", len(row["text"]) == 140 and row["text"].endswith("…"), len(row["text"]))
row = next(x for x in block()["running"] if x.get("taskID") == t_run["id"])
check("the full answer keeps up to 200 characters", len(row["text"]) == 200, len(row["text"]))

# 8. No sign of life: time shift in the scratch database (all signs of the card and the session's updated_at, 40 minutes back)
tool(agent, "report_session_status", {"projectID": project, "sessionName": "Leise", "activity": "Warte"})
past = time.time() - 40 * 60
tid = t_run["id"].upper()
con.execute("UPDATE task_workflow SET claimed_at = ? WHERE id = ?", (past, tid))
for table, col in (("task_progress_notes", "task_id"), ("activity_events", "task_id"), ("comments", "task_id")):
    con.execute(f"UPDATE {table} SET created_at = ? WHERE {col} = ?", (past, tid))
con.execute("UPDATE session_statuses SET updated_at = ? WHERE session_name = 'Leise'", (past,))
con.commit()
blk = block()
check("card without sign of life for 40 minutes is silent, not running", "Laeuft" in titles(blk, "silent") and "Laeuft" not in titles(blk, "running"), blk)
check("session without sign of life for 40 minutes is silent", "Leise" in titles(blk, "silent") and "Leise" not in titles(blk, "running"), blk)
check("silent entries are old enough", all(x["ageSeconds"] > 30 * 60 for x in blk["silent"]), blk["silent"])
check("counts follow", blk["counts"]["silent"] == 2, blk["counts"])
# A fresh sign of life brings the card back.
tool(agent, "post_progress", {"taskID": t_run["id"], "note": "wieder da"})
check("a new progress note makes the card running again", "Laeuft" in titles(block(), "running"))

# 9. 24 hour cleanup with the real command
con.execute("UPDATE session_statuses SET updated_at = ? WHERE session_name = 'Leise'", (time.time() - 25 * 3600,))
con.commit()
st, body, _ = now()
check("a session older than 24 hours is hidden in the overview", "Leise" not in [s["sessionName"] for p in body["projects"] for s in p["sessions"]] and "Leise" not in titles(body["now"], "silent"), body["now"])
r = subprocess.run([native, "cleanup-expired"], capture_output=True, text=True, env=os.environ)
check("cleanup-expired runs", r.returncode == 0, r.stdout + r.stderr)
check("cleanup deleted the old row and kept the fresh one", session_rows() == [("Mac Studio",)], session_rows())
con.close()

# 10. No texts in the backend log
log = open(log_path, errors="replace").read()
for needle in ("Schreibe E2E", "Migrationstest", "Welche Farbe soll der Button haben"):
    check(f"backend log does not contain {needle!r}", needle not in log)

print(f"\n{len(failures)} failure(s)" if failures else "\nall checks passed")
sys.exit(1 if failures else 0)
