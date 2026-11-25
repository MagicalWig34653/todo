#!/usr/bin/env python3
"""End-to-end check of the extended recurrence rules (card 21CF716D) against a running backend: REST, sync and MCP.

Real HTTP and a real OAuth token for /mcp. Completion happens through PATCH /v1/tasks/{id} (REST) and update_task (MCP).
Usage: recurrence-rules-e2e.py BASE_URL SESSION_A SQLITE_FILE APP_BINARY BACKEND_LOG
"""
import base64, hashlib, json, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

base, sess, db_path, native, log_path = sys.argv[1:6]
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

st, b = http("POST", "/v1/projects", {"name": "Recurrence E2E"}, sess); project = j(b)["id"]

def new_task(title):
    st, b = http("POST", "/v1/tasks", {"projectID": project, "title": title}, sess); return j(b)["id"]

def planning(tid):
    return j(http("GET", f"/v1/planning/tasks/{tid}", token=sess)[1])

def put(tid, rule, due, reminders=(), planned=None):
    body = {"priority": 1, "dueAt": due, "reminders": list(reminders), "recurrence": rule}
    if planned: body["plannedAt"] = planned
    return http("PUT", f"/v1/planning/tasks/{tid}", body, sess)

def complete(tid):
    st, b = http("PATCH", f"/v1/tasks/{tid}", {"version": planning(tid)["task"]["version"], "status": "done"}, sess)
    return st == 200

def stored(tid):
    out = subprocess.run(["sqlite3", db_path, f"SELECT recurrence FROM task_planning WHERE lower(id) = lower('{tid}')"], capture_output=True, text=True).stdout.strip()
    return out

def successor_id(tid):
    out = subprocess.run(["sqlite3", db_path, f"SELECT next_task_id FROM planning_occurrences WHERE lower(id) = lower('{tid}')"], capture_output=True, text=True).stdout.strip()
    return out.lower() if out else None

def next_of(tid):
    nid = successor_id(tid)
    return (nid, planning(nid)) if nid else (None, None)

# 1. Old rule without any new field: JSON and successor stay exactly as before.
old = {"frequency": "weekly", "interval": 2, "timeZone": "Europe/Berlin", "until": "2035-01-01T00:00:00Z"}
t_old = new_task("Old rule")
st, body = put(t_old, old, "2030-03-20T08:00:00Z", ["2030-03-20T07:00:00Z"])
check("old rule: PUT ok", st == 200, body)
got = planning(t_old)["recurrence"]
check("old rule: GET returns exactly the old keys", set(got) == {"frequency", "interval", "timeZone", "until"}, got)
row = stored(t_old)
check("old rule: stored JSON has no new keys", row != "" and not any(k in row for k in ("weekdays", "basis", "monthDay")), row)
check("old rule: complete", complete(t_old))
nid, nxt = next_of(t_old)
check("old rule: successor is two weeks later at the same wall-clock time", nxt and nxt["dueAt"] == "2030-04-03T07:00:00Z" and nxt["reminders"] == ["2030-04-03T06:00:00Z"], nxt)
check("old rule: successor keeps the old rule keys", nxt and set(nxt["recurrence"]) == {"frequency", "interval", "timeZone", "until"}, nxt and nxt["recurrence"])

# 2. weekdays Monday + Thursday (2030-01-07 is a Monday), chained through three completions, then Berlin across the DST switch.
t_wd = new_task("Mon+Thu")
rule = {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [4, 1]}
st, body = put(t_wd, rule, "2030-01-07T09:00:00Z", ["2030-01-07T08:00:00Z"])
check("weekdays: PUT ok", st == 200, body)
check("weekdays: GET round trips the rule", planning(t_wd)["recurrence"] == rule, planning(t_wd)["recurrence"])
cur, seen, rem = t_wd, [], []
for _ in range(3):
    ok = complete(cur); cur, p = next_of(cur)
    if not ok or not p: break
    seen.append(p["dueAt"]); rem += p["reminders"]
check("weekdays: Mon -> Thu -> Mon -> Thu", seen == ["2030-01-10T09:00:00Z", "2030-01-14T09:00:00Z", "2030-01-17T09:00:00Z"], seen)
check("weekdays: reminder moves by the same distance", rem == ["2030-01-10T08:00:00Z", "2030-01-14T08:00:00Z", "2030-01-17T08:00:00Z"], rem)
t_wd2 = new_task("Every second week")
st, body = put(t_wd2, {"frequency": "weekly", "interval": 2, "timeZone": "UTC", "weekdays": [1, 4]}, "2030-01-10T09:00:00Z")
complete(t_wd2); _, p = next_of(t_wd2)
check("weekdays: interval 2 skips a week after the last chosen day", p and p["dueAt"] == "2030-01-21T09:00:00Z", p and p["dueAt"])
t_wd3 = new_task("Berlin DST")
st, body = put(t_wd3, {"frequency": "weekly", "interval": 1, "timeZone": "Europe/Berlin", "weekdays": [1, 4]}, "2030-03-28T08:00:00Z")  # Thursday 09:00 CET
complete(t_wd3); _, p = next_of(t_wd3)
check("weekdays: 09:00 Berlin stays 09:00 over the switch (Monday 2030-04-01 is CEST)", p and p["dueAt"] == "2030-04-01T07:00:00Z", p and p["dueAt"])

# 3. monthDay 31: Jan -> Feb 28 -> Mar 31 -> Apr 30.
t_md = new_task("Month end")
rule = {"frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 31}
st, body = put(t_md, rule, "2031-01-31T09:00:00Z", ["2031-01-30T09:00:00Z"])
check("monthDay: PUT ok", st == 200, body)
cur, seen = t_md, []
for _ in range(3):
    ok = complete(cur); cur, p = next_of(cur)
    if not ok or not p: break
    seen.append(p["dueAt"])
check("monthDay: 31st is clamped and does not drift", seen == ["2031-02-28T09:00:00Z", "2031-03-31T09:00:00Z", "2031-04-30T09:00:00Z"], seen)
check("monthDay: successor keeps the rule", p and p["recurrence"] == rule, p and p["recurrence"])
t_md2 = new_task("Every second month, 15th")
put(t_md2, {"frequency": "monthly", "interval": 2, "timeZone": "UTC", "monthDay": 15}, "2030-11-15T09:00:00Z")
complete(t_md2); _, p = next_of(t_md2)
check("monthDay: 15th with interval 2 crosses the year", p and p["dueAt"] == "2031-01-15T09:00:00Z", p and p["dueAt"])

# 4. basis completion: an overdue card is counted from the day it is finished (calendar day in the rule's zone).
t_bc = new_task("From completion")
rule = {"frequency": "daily", "interval": 2, "timeZone": "UTC", "basis": "completion"}
st, body = put(t_bc, rule, "2026-01-05T09:00:00Z", ["2026-01-05T08:30:00Z"], planned="2026-01-05T08:00:00Z")
check("completion: PUT ok", st == 200, body)
before = datetime.now(timezone.utc); ok = complete(t_bc); after = datetime.now(timezone.utc)
_, p = next_of(t_bc)
def day9(moment, hour):
    d = moment.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=2)
    return iso(d.replace(hour=hour))
check("completion: due is two days after the completion day, time of the old due date", ok and p and p["dueAt"] in (day9(before, 9), day9(after, 9)), p and p["dueAt"])
check("completion: planned start follows with its own time", p and p["plannedAt"] in (day9(before, 8), day9(after, 8)), p and p["plannedAt"])
if p:
    due = datetime.strptime(p["dueAt"], "%Y-%m-%dT%H:%M:%SZ")
    check("completion: reminder keeps its 30 minute distance", [datetime.strptime(x, "%Y-%m-%dT%H:%M:%SZ") for x in p["reminders"]] == [due - timedelta(minutes=30)], p["reminders"])

# 5. Invalid combinations are 400 invalid_recurrence and nothing is stored.
t_bad = new_task("Invalid")
bad_cases = [
    {"frequency": "daily", "interval": 1, "timeZone": "UTC", "weekdays": [1]},
    {"frequency": "monthly", "interval": 1, "timeZone": "UTC", "weekdays": [1]},
    {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": []},
    {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [3, 3]},
    {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [0]},
    {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [8]},
    {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "monthDay": 5},
    {"frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 32},
    {"frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 0},
    {"frequency": "daily", "interval": 1, "timeZone": "UTC", "basis": "yesterday"},
]
codes = [(put(t_bad, r, "2030-01-07T09:00:00Z")[0], (j(put(t_bad, r, "2030-01-07T09:00:00Z")[1]) or {}).get("reason")) for r in bad_cases]
check("invalid rules: all 400 invalid_recurrence", all(c == (400, "invalid_recurrence") for c in codes), codes)
check("invalid rules: nothing stored", planning(t_bad).get("recurrence") is None, planning(t_bad))

# 6. Sync feed carries the new fields; the calendar drag keeps them.
st, body = http("GET", "/v1/sync/changes?cursor=c0&limit=500", token=sess)
mine = [x for x in j(body)["changes"] if x["entityType"] == "task" and x["entityID"].lower() == t_wd.lower() and x.get("planning")]
check("sync upsert carries weekdays", bool(mine) and (mine[-1]["planning"].get("recurrence") or {}).get("weekdays") == [4, 1], mine[-1:])
t_dr = new_task("Drag")
put(t_dr, {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [2, 6], "basis": "completion"}, "2030-01-08T09:00:00Z")
st, body = http("PATCH", f"/v1/tasks/{t_dr}/schedule", {"version": planning(t_dr)["task"]["version"], "plannedAt": "2030-01-08T07:00:00Z", "plannedMinutes": 30}, sess)
check("calendar drag keeps weekdays and basis", st == 200 and j(body)["recurrence"] == {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [2, 6], "basis": "completion"}, body)

# 7. MCP with a real OAuth token.
def oauth_token(scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Recurrence E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = j(b)["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    resource = j(http("GET", "/.well-known/oauth-protected-resource/mcp")[1])["resource"]
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client, "redirect_uri": "http://127.0.0.1:54321/callback", "scope": scope,
        "state": "s", "resource": resource, "code_challenge": challenge, "code_challenge_method": "S256"})
    st, b = http("GET", "/oauth/authorize?" + q, token=sess, headers={"Accept": "application/json"})
    if st != 200: raise SystemExit(f"authorize failed: {st} {b[:200]}")
    st, b = http("POST", "/oauth/consent", {"consent_token": j(b)["consent_token"], "approve": True, "project_ids": [project]}, sess)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(j(b)["redirect_uri"]).query)["code"][0]
    st, b = http("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client, "resource": resource, "code": code,
        "redirect_uri": "http://127.0.0.1:54321/callback", "code_verifier": verifier})
    return j(b)["access_token"]

def tool(tok, name, args):
    st, b = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}, tok)
    res = j(b)["result"]; text = res["content"][0]["text"]
    return res.get("isError", False), text, j(text)

tok = oauth_token("projects:read tasks:read tasks:write")
t_mcp = new_task("MCP rules")
rule = {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [1, 4], "basis": "completion"}
err, text, data = tool(tok, "update_task_planning", {"taskID": t_mcp, "dueAt": "2030-01-07T09:00:00Z", "recurrence": rule})
check("MCP: update_task_planning sets weekdays and basis", not err and (data or {}).get("recurrence") == rule, text[:300])
err, text, data = tool(tok, "get_task_planning", {"taskID": t_mcp})
check("MCP: get_task_planning returns them and REST agrees", not err and (data or {}).get("recurrence") == rule and planning(t_mcp)["recurrence"] == rule, text[:300])
err, text, data = tool(tok, "update_task_planning", {"taskID": t_mcp, "recurrence": {"frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 31}})
check("MCP: replacing the rule drops the old fields", not err and (data or {}).get("recurrence") == {"frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 31}, text[:300])
for bad in [{"frequency": "daily", "interval": 1, "timeZone": "UTC", "weekdays": [1]},
            {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [1, 1]},
            {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "monthDay": 4},
            {"frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 32},
            {"frequency": "daily", "interval": 1, "timeZone": "UTC", "basis": "later"}]:
    err, text, _ = tool(tok, "update_task_planning", {"taskID": t_mcp, "recurrence": bad})
    check(f"MCP: refused {json.dumps(bad, sort_keys=True)}", err and text == "invalid_recurrence", text)
err, text, data = tool(tok, "update_task_planning", {"taskID": t_mcp, "recurrence": {"frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [1, 4]}})
check("MCP: back to weekdays", not err and ((data or {}).get("recurrence") or {}).get("weekdays") == [1, 4], text[:300])
err, text, data = tool(tok, "update_task", {"id": t_mcp, "version": planning(t_mcp)["task"]["version"], "status": "done"})
check("MCP: update_task done", not err, text[:200])
_, p = next_of(t_mcp)
check("MCP: successor follows the weekday rule (Mon 2030-01-07 -> Thu 2030-01-10)", p and p["dueAt"] == "2030-01-10T09:00:00Z" and (p["recurrence"] or {}).get("weekdays") == [1, 4], p and (p["dueAt"], p["recurrence"]))
t_mcp2 = new_task("MCP old rule")
err, text, data = tool(tok, "update_task_planning", {"taskID": t_mcp2, "dueAt": "2030-01-07T09:00:00Z", "recurrence": {"frequency": "daily", "interval": 2, "timeZone": "UTC"}})
check("MCP: old rule form answers with the old keys only", not err and set((data or {}).get("recurrence") or {}) == {"frequency", "interval", "timeZone"}, text[:300])
err, text, data = tool(tok, "update_task_planning", {"taskID": t_mcp2, "recurrence": None})
check("MCP: recurrence null clears the rule", not err and "recurrence" not in data and planning(t_mcp2).get("recurrence") is None, text[:300])

if failures:
    print(f"\n{len(failures)} check(s) failed"); sys.exit(1)
print("\nall checks passed")
