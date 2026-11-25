#!/usr/bin/env python3
"""End-to-end check of the card pipeline, stage 1 (card 74EC341D) against a running backend: REST and MCP.

Real HTTP and real OAuth tokens for /mcp: one connection plans and reports, a second one holds the brain mandate.
Usage: pipeline-e2e.py BASE_URL SESSION SQLITE_FILE
"""
import base64, hashlib, json, subprocess, sys, urllib.error, urllib.parse, urllib.request

base, sess, db_path = sys.argv[1:4]
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

def rest(method, path, body=None, token=sess):
    st, b = http(method, path, body, token)
    return st, j(b) if j(b) is not None else {}

def reason(answer):
    return (answer[0], answer[1].get("reason"))

st, project_body = rest("POST", "/v1/projects", {"name": "Pipeline E2E"})
project = project_body["id"]

def new_task(title):
    return rest("POST", "/v1/tasks", {"projectID": project, "title": title})[1]["id"]

def card(tid):
    t = rest("GET", f"/v1/planning/tasks/{tid}")[1]["task"]
    return {k: t.get(k) for k in ("status", "columnID", "version")}

def oauth_token(scope, name):
    st, b = http("POST", "/oauth/register", {"client_name": name, "redirect_uris": ["http://127.0.0.1:54321/callback"]})
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

def mcp(tok, method, params=None):
    st, b = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, tok)
    return j(b)["result"]

def tool(tok, name, args):
    res = mcp(tok, "tools/call", {"name": name, "arguments": args}); text = res["content"][0]["text"]
    return res.get("isError", False), text, j(text)

SCOPES = "projects:read tasks:read tasks:write"
agent = oauth_token(SCOPES, "Pipeline Agent")
brain = oauth_token(SCOPES, "Pipeline Brain")

def pipeline(tid):
    return rest("GET", f"/v1/tasks/{tid}/pipeline")[1]

def states(p):
    return [s["state"] for s in (p or {}).get("steps", [])]

def actions(p):
    return [e["action"] for e in p.get("events", [])]

def sql(query):
    return subprocess.run(["sqlite3", db_path, query], capture_output=True, text=True, check=True).stdout.strip()

def decide(tid, body):
    return rest("POST", f"/v1/tasks/{tid}/plan/decision", body)

# 1. Empty pipeline, anonymous callers.
task = new_task("Plan approval")
empty = pipeline(task)
check("empty: six steps in order, all pending", [s["step"] for s in empty.get("steps", [])] == ["planner", "approval", "developer", "validation", "tester", "review"] and states(empty) == ["pending"] * 6, empty)
check("empty: no plan, no events", empty.get("plan") is None and empty.get("events") == [], empty)
check("anonymous: 401", http("GET", f"/v1/tasks/{task}/pipeline")[0] == 401)
before = card(task)

# 2. The agent writes the plan over MCP and may not decide it.
names = {t["name"] for t in mcp(agent, "tools/list")["tools"]}
check("MCP: four pipeline tools listed", {"get_task_pipeline", "set_task_plan", "decide_plan", "set_pipeline_step"} <= names, len(names))
err, text, _ = tool(agent, "set_pipeline_step", {"taskID": task, "step": "planner", "state": "running", "agentName": "claude-code"})
check("MCP: planner running", not err, text[:200])
plan_text = "# Plan\n\n- Schritt eins\n- password=hunter2geheim\n" + "Zeile mit Text\n" * 400 + "Ende"
err, text, data = tool(agent, "set_task_plan", {"taskID": task, "plan": plan_text, "expectedVersion": 0, "agentName": "claude-code"})
plan = (data or {}).get("plan") or {}
check("MCP: plan version 1 proposed", not err and plan.get("version") == 1 and plan.get("state") == "proposed" and plan.get("authorType") == "integration" and plan.get("authorLabel") == "claude-code", text[:300])
check("MCP: long plan stored whole, secret masked", plan.get("body", "").endswith("Ende") and "hunter2geheim" not in plan.get("body", "") and plan.get("body", "").count("Zeile mit Text") == 400, plan.get("body", "")[:120])
check("secret is not in the database", sql("SELECT count(*) FROM task_plans WHERE body LIKE '%hunter2geheim%'") == "0")
check("steps: planner done, approval waiting", states(data) == ["done", "waiting", "pending", "pending", "pending", "pending"], states(data))
err, text, _ = tool(agent, "set_task_plan", {"taskID": task, "plan": plan_text, "expectedVersion": 0})
check("MCP: retry of the same plan is idempotent", not err and pipeline(task)["plan"]["version"] == 1 and actions(pipeline(task)).count("plan_written") == 1, text[:200])
err, text, _ = tool(agent, "decide_plan", {"taskID": task, "decision": "approve", "version": 1, "quote": "ja"})
check("MCP: own plan refused", err and text == "cannot_decide_own_plan", text)
err, text, _ = tool(brain, "decide_plan", {"taskID": task, "decision": "approve", "version": 1, "quote": "ja"})
check("MCP: integration without mandate refused", err and text == "brain_mandate_required", text)
err, text, _ = tool(agent, "set_pipeline_step", {"taskID": task, "step": "developer", "state": "running"})
check("MCP: developer locked before approval", err and text == "plan_not_approved", text)
check("still proposed after the refusals", pipeline(task)["plan"]["state"] == "proposed")

# 3. The person requests changes, the agent writes a new version, the person approves.
answer = decide(task, {"decision": "request_changes", "version": 1})
check("REST: request_changes needs a comment", reason(answer) == (400, "comment_required"), answer)
st, p = decide(task, {"decision": "request_changes", "version": 1, "comment": "Tests fehlen\n- E2E"})
check("REST: changes requested", st == 200 and p["plan"]["state"] == "changes_requested" and states(p)[:2] == ["pending", "changes_requested"] and p["plan"]["decidedByLabel"] == "Pipeline Person", p)
err, text, data = tool(agent, "get_task_pipeline", {"taskID": task})
check("MCP: agent reads the comment", not err and data["plan"]["decisionComment"] == "Tests fehlen\n- E2E", text[:200])
check("MCP: stale expected version refused", tool(agent, "set_task_plan", {"taskID": task, "plan": "# Neu", "expectedVersion": 0})[1] == "plan_changed")
err, text, data = tool(agent, "set_task_plan", {"taskID": task, "plan": "# Plan 2\n\n- E2E", "expectedVersion": 1, "agentName": "claude-code"})
check("MCP: version 2 proposed", not err and data["plan"]["version"] == 2 and data["plan"].get("decisionComment") is None and states(data)[:2] == ["done", "waiting"], text[:300])
answer = decide(task, {"decision": "approve", "version": 1})
check("REST: old version refused", reason(answer) == (409, "plan_changed"), answer)
token = tool(agent, "wait_for_events", {})[2]["token"]
st, p = decide(task, {"decision": "approve", "version": 2})
check("REST: approved by the person", st == 200 and p["plan"]["state"] == "approved" and states(p)[:2] == ["done", "done"], p)
err, text, data = tool(agent, "wait_for_events", {"since": token, "timeoutSeconds": 1})
check("MCP: wait_for_events hints the plan", not err and any(h["kind"] == "plan" and h.get("taskID", "").lower() == task.lower() for h in data["hints"]), text[:300])
answer = decide(task, {"decision": "approve", "version": 2})
check("REST: second decision refused", reason(answer) == (409, "plan_not_pending"), answer)

# 4. Step states over MCP and REST.
for step, state, note in [("developer", "running", None), ("developer", "done", "gebaut"), ("validation", "done", "swift test 0 Fehler"), ("tester", "skipped", None)]:
    args = {"taskID": task, "step": step, "state": state, "agentName": "dev@mac"}
    if note: args["note"] = note
    err, text, _ = tool(agent, "set_pipeline_step", args)
    check(f"MCP: {step} {state}", not err, text[:200])
st, p = rest("PUT", f"/v1/tasks/{task}/pipeline/steps/review", {"state": "running"})
check("REST: review running", st == 200 and states(p) == ["done", "done", "done", "done", "skipped", "running"], states(p))
count = len(p["events"])
st, p = rest("PUT", f"/v1/tasks/{task}/pipeline/steps/review", {"state": "running"})
check("REST: same state again adds no audit entry", st == 200 and len(p["events"]) == count, len(p["events"]))
answer = rest("PUT", f"/v1/tasks/{task}/pipeline/steps/approval", {"state": "done"})
check("REST: approval is managed", reason(answer) == (409, "step_managed"), answer)
answer = rest("PUT", f"/v1/tasks/{task}/pipeline/steps/deploy", {"state": "done"})
check("REST: unknown step", reason(answer) == (400, "invalid_step"), answer)

# 5. Audit trail, activity of the card, card untouched.
p = pipeline(task)
check("audit: newest first with every change", actions(p) == ["step_changed"] * 5 + ["plan_approved", "plan_written", "plan_changes_requested", "plan_written", "step_changed"], actions(p))
check("audit: actors", p["events"][0]["actorType"] == "person" and p["events"][1]["actorType"] == "integration" and p["events"][1]["actorLabel"] == "dev@mac", p["events"][:2])
st, body = http("GET", f"/v1/tasks/{task}/activity?limit=100", token=sess)
for kind in ["plan.written", "plan.approved", "plan.changes_requested", "pipeline.step"]:
    check(f"activity: {kind}", f'"{kind}"' in body.decode(), (st, body[:200]))
check("card status, column and version unchanged", card(task) == before, (before, card(task)))

# 6. A second card: the mandated connection decides in the person's words.
second = new_task("Brain decides")
tool(agent, "set_task_plan", {"taskID": second, "plan": "Plan"})
st, connections = rest("GET", f"/v1/projects/{project}/connections")
rows = connections if isinstance(connections, list) else []
grant = next((c.get("grantID") or c.get("id") for c in rows if "Pipeline Brain" in json.dumps(c)), None)
st, m = rest("PUT", "/v1/settings/brain-mandate", {"grantID": grant, "projectIDs": [project]})
check("mandate granted", st == 200, (st, m, connections))
check("MCP: quote required", tool(brain, "decide_plan", {"taskID": second, "decision": "approve", "version": 1})[1] == "quote_required")
err, text, data = tool(brain, "decide_plan", {"taskID": second, "decision": "approve", "version": 1, "quote": "Passt so"})
check("MCP: mandated decision", not err and data["plan"]["state"] == "approved" and data["plan"]["decidedByLabel"] == "Pipeline Brain", text[:300])
audit = rest("GET", "/v1/settings/brain-mandate/audit")[1].get("items", [])
check("brain audit row", [(x["kind"], x["quote"]) for x in audit] == [("plan.approved", "Passt so")], audit)

# 7. Deleting the card removes its pipeline.
st, _ = http("DELETE", f"/v1/tasks/{second}", token=sess)
tables = ("task_plans", "task_pipeline_steps", "task_pipeline_events")
left = [sql(f"SELECT count(*) FROM {t} WHERE lower(task_id) = lower('{second}')") for t in tables]
kept = [sql(f"SELECT count(*) FROM {t} WHERE lower(task_id) = lower('{task}')") for t in tables]
check("delete removes plan, steps and events", st == 204 and left == ["0", "0", "0"], (st, left))
check("the other card keeps its pipeline (rows found by the same query)", all(int(n) > 0 for n in kept) and pipeline(task)["plan"]["version"] == 2, kept)

if failures:
    print(f"\n{len(failures)} check(s) failed"); sys.exit(1)
print("\nall checks passed")
