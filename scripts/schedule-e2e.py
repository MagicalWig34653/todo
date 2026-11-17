#!/usr/bin/env python3
"""End-to-end check of the calendar schedule (ADR 0033) against a running backend: REST, sync and MCP, two accounts.

Real HTTP and a real OAuth token for /mcp.
Usage: schedule-e2e.py BASE_URL SESSION_A SESSION_B SQLITE_FILE APP_BINARY BACKEND_LOG
"""
import base64, hashlib, json, sys, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

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

iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
t0 = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=9, minute=0, second=0, microsecond=0)
win = f"from={iso(t0 - timedelta(hours=10))}&to={iso(t0 + timedelta(days=7))}"

st, b = http("POST", "/v1/projects", {"name": "Schedule E2E"}, sess_a); project = j(b)["id"]
def new_task(title):
    st, b = http("POST", "/v1/tasks", {"projectID": project, "title": title}, sess_a); return j(b)["id"]
def version(tid):
    return j(http("GET", f"/v1/planning/tasks/{tid}", token=sess_a)[1])["task"]["version"]
a, b_, c = new_task("Alpha"), new_task("Beta"), new_task("Gamma")

# Existing planning data must survive a drag.
due = iso(t0 + timedelta(hours=4))
st, body = http("PUT", f"/v1/planning/tasks/{a}", {"priority": 3, "dueAt": due, "reminders": [iso(t0)],
    "recurrence": {"frequency": "daily", "interval": 1, "timeZone": "Europe/Berlin"}}, sess_a)
check("PUT planning ok", st == 200, body)
st, body = http("PATCH", f"/v1/tasks/{a}/schedule", {"version": version(a), "plannedAt": iso(t0), "plannedMinutes": 60}, sess_a)
r = j(body)
check("PATCH schedule ok with duration", st == 200 and r["plannedMinutes"] == 60 and r["plannedAllDay"] is False, body)
check("PATCH keeps priority, due date, recurrence, reminders",
      r["priority"] == 3 and r["dueAt"] == due and r["recurrence"]["timeZone"] == "Europe/Berlin" and len(r["reminders"]) == 1, body)
st, body = http("PATCH", f"/v1/tasks/{a}/schedule", {"version": 1, "plannedAt": iso(t0)}, sess_a)
check("stale version is 409", st == 409, body)
st, body = http("PATCH", f"/v1/tasks/{a}/schedule", {"version": version(a), "plannedAt": iso(t0), "plannedMinutes": 3}, sess_a)
check("duration below 5 is 400", st == 400, body)
st, body = http("PATCH", f"/v1/tasks/{b_}/schedule", {"version": version(b_), "plannedAt": iso(t0 + timedelta(minutes=30)), "plannedMinutes": 30}, sess_a)
check("second card scheduled", st == 200, body)
st, body = http("PATCH", f"/v1/tasks/{c}/schedule", {"version": version(c), "plannedAt": iso(t0.replace(hour=0)), "plannedAllDay": True}, sess_a)
check("all-day card scheduled", st == 200 and j(body)["plannedAllDay"] is True, body)

st, body = http("GET", f"/v1/planning/schedule?{win}", token=sess_a)
items = (j(body) or {}).get("items", [])
check("schedule lists three cards ordered by start", st == 200 and [i["taskID"] for i in items] == [c, a, b_], body[:300])
check("schedule entry fields", bool(items) and all(k in items[0] for k in ("version", "canEdit", "blocked", "autoStart", "conflicts")) and items[0]["canEdit"] is True, items[:1])
st, body = http("GET", f"/v1/planning/schedule?{win}&limit=2", token=sess_a)
check("limit truncates", j(body)["truncated"] is True and len(j(body)["items"]) == 2, body[:200])
st, body = http("GET", f"/v1/planning/schedule?from={iso(t0)}&to={iso(t0 + timedelta(days=70))}", token=sess_a)
check("window over 62 days is 400", st == 400 and b"window_too_large" in body, body)
st, body = http("GET", "/v1/planning/unscheduled", token=sess_a)
check("unscheduled excludes planned cards", st == 200 and j(body) == [], body)

# Rights: a stranger sees nothing and cannot move.
st, body = http("GET", f"/v1/planning/schedule?{win}", token=sess_b)
check("stranger sees empty schedule", st == 200 and j(body)["items"] == [], body)
st, body = http("PATCH", f"/v1/tasks/{a}/schedule", {"version": version(a), "plannedAt": iso(t0)}, sess_b)
check("stranger PATCH is 404", st == 404, body)
st, body = http("GET", f"/v1/planning/schedule?{win}&projectID={project}", token=sess_b)
check("stranger project filter is 404", st == 404, body)
st, body = http("GET", f"/v1/planning/schedule?{win}")
check("no session is 401", st == 401, body)

# Clearing the start clears duration and all-day.
st, body = http("PATCH", f"/v1/tasks/{b_}/schedule", {"version": version(b_), "plannedAt": None}, sess_a)
check("clearing start clears duration", st == 200 and j(body).get("plannedMinutes") is None and j(body)["plannedAllDay"] is False, body)
st, body = http("PATCH", f"/v1/tasks/{b_}/schedule", {"version": version(b_), "plannedAt": iso(t0 + timedelta(minutes=30)), "plannedMinutes": 30}, sess_a)

# Sync carries the fields; a full replacement from a client without them keeps the duration.
st, body = http("GET", "/v1/sync/changes?cursor=c0&limit=500", token=sess_a)
mine = [x for x in j(body)["changes"] if x["entityType"] == "task" and x["entityID"].lower() == a.lower() and x.get("planning")]
check("sync upsert carries plannedMinutes and plannedAllDay",
      bool(mine) and mine[-1]["planning"].get("plannedMinutes") == 60 and mine[-1]["planning"].get("plannedAllDay") is False, mine[-1:] )
st, body = http("POST", "/v1/sync/mutations", {"mutationID": str(uuid.uuid4()), "type": "task.planning", "id": a, "version": version(a),
    "plannedAt": iso(t0), "priority": 2, "dueAt": due, "recurrence": {"frequency": "daily", "interval": 1, "timeZone": "Europe/Berlin"}}, sess_a)
check("old-style sync planning keeps the duration", st == 200 and j(body)["planning"]["plannedMinutes"] == 60, body)

# MCP with a real OAuth token.
def oauth_token(scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Schedule E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = j(b)["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    resource = j(http("GET", "/.well-known/oauth-protected-resource/mcp")[1])["resource"]
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

tok = oauth_token("projects:read tasks:read tasks:write")
err, text, data = tool(tok, "list_schedule", {"from": iso(t0 - timedelta(hours=10)), "to": iso(t0 + timedelta(days=7))})
rest_ids = [i["taskID"] for i in j(http("GET", f"/v1/planning/schedule?{win}", token=sess_a)[1])["items"]]
check("MCP list_schedule matches REST", not err and [i["taskID"] for i in data["items"]] == rest_ids, text[:200])
err, text, data = tool(tok, "update_task_planning", {"taskID": b_, "plannedAt": iso(t0 + timedelta(hours=2)), "plannedMinutes": 15})
check("MCP update_task_planning sets start and duration", not err and data["plannedMinutes"] == 15, text[:200])
err, text, _ = tool(tok, "update_task_planning", {"taskID": b_, "autoStart": True})
check("MCP cannot set autoStart", err and text == "invalid_arguments", text)
err, text, _ = tool(tok, "list_schedule", {"from": iso(t0), "to": iso(t0 + timedelta(days=70))})
check("MCP window over 62 days refused", err and text == "window_too_large", text)

if failures:
    print(f"\n{len(failures)} check(s) failed"); sys.exit(1)
print("\nall checks passed")
