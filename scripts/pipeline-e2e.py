#!/usr/bin/env python3
"""End-to-end check of the card pipeline, stages 1 to 3 (cards 74EC341D, B926E7D8, F5DD1C00) against a running backend: REST, MCP and runner protocol.

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

SCOPES = "projects:read projects:write tasks:read tasks:write"
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

# 8. Stage 2 (card B926E7D8): project settings, switched off steps, plan version, retry and the waiting plan in "Für dich".
st, cfg = rest("GET", f"/v1/projects/{project}/pipeline-settings")
check("settings: defaults without a row", st == 200 and cfg.get("revision") == 0 and cfg.get("maxFixRounds") == 3 and all(cfg["steps"].values()) and len(cfg["steps"]) == 6 and cfg.get("history") == [], cfg)
check("settings: no row written by reading", sql("SELECT count(*) FROM project_pipeline_settings") == "0")
check("settings: anonymous 401", http("GET", f"/v1/projects/{project}/pipeline-settings")[0] == 401)
names2 = {t["name"] for t in mcp(agent, "tools/list")["tools"]}
check("MCP: three stage 2 tools listed", {"get_pipeline_settings", "update_pipeline_settings", "retry_pipeline_step"} <= names2, sorted(names2)[:5])
for body, why in [({"revision": 0}, "no field"), ({"revision": 0, "maxFixRounds": 11}, "11 rounds"), ({"revision": 0, "roles": {"developer": {"model": "no good"}}}, "model"),
                  ({"revision": 0, "roles": {"developer": {"effort": "ultra"}}}, "effort")]:
    check(f"settings: refused ({why})", rest("PATCH", f"/v1/projects/{project}/pipeline-settings", body)[0] == 400)
st, cfg = rest("PATCH", f"/v1/projects/{project}/pipeline-settings", {"revision": 0, "steps": {"tester": False}, "roles": {"developer": {"model": "sonnet", "effort": "high"}}, "maxFixRounds": 1})
check("settings: partial update, revision 1, history", st == 200 and cfg["revision"] == 1 and cfg["steps"]["tester"] is False and cfg["roles"]["developer"] == {"model": "sonnet", "effort": "high"} and len(cfg["history"]) == 1, cfg)
check("settings: stale revision 409", reason(rest("PATCH", f"/v1/projects/{project}/pipeline-settings", {"revision": 0, "maxFixRounds": 2})) == (409, "revision_conflict"))
st, again = rest("PATCH", f"/v1/projects/{project}/pipeline-settings", {"revision": 1, "maxFixRounds": 1})
check("settings: same content changes nothing", st == 200 and again["revision"] == 1 and len(again["history"]) == 1, again)
err, text, data = tool(agent, "get_pipeline_settings", {"projectID": project})
check("MCP: get_pipeline_settings", not err and data["revision"] == 1 and data["roles"]["developer"]["model"] == "sonnet", text[:200])
err, text, _ = tool(agent, "update_pipeline_settings", {"projectID": project, "revision": 1, "maxFixRounds": 2, "quote": "ja"})
check("MCP: update without mandate refused", err and text == "brain_mandate_required", text)
err, text, _ = tool(brain, "update_pipeline_settings", {"projectID": project, "revision": 1, "maxFixRounds": 2})
check("MCP: update without quote refused", err and text == "quote_required", text)
err, text, data = tool(brain, "update_pipeline_settings", {"projectID": project, "revision": 1, "roles": {"developer": {"effort": None}}, "maxFixRounds": 2, "quote": "Zwei Runden reichen"})
check("MCP: mandated update", not err and data["revision"] == 2 and data["maxFixRounds"] == 2 and "effort" not in data["roles"]["developer"] and data["history"][0]["actorType"] == "integration", text[:300])
audit = rest("GET", "/v1/settings/brain-mandate/audit")[1].get("items", [])
check("brain audit: pipeline.settings with the quote", any(x["kind"] == "pipeline.settings" and x["quote"] == "Zwei Runden reichen" and x["projectID"].lower() == project.lower() and "taskID" not in x for x in audit), audit)

# A card with the plan approved, tester switched off, a step bound to the plan version and a counted retry.
t2 = new_task("Stage two")
check("pipeline: settings and per-step fields", (lambda p: p["settings"]["revision"] == 2 and p["fixRounds"] == {"used": 0, "max": 2, "remaining": 2} and p["waitingApproval"] is False and all("enabled" in s for s in p["steps"])
      and [s["step"] for s in p["steps"] if s.get("role") is not None] == ["planner", "developer", "tester", "review"])(pipeline(t2)), pipeline(t2))
check("pipeline: tester is off and shown as skipped", (lambda s: s["enabled"] is False and s["state"] == "skipped")(pipeline(t2)["steps"][4]))
tool(agent, "set_task_plan", {"taskID": t2, "plan": "# Stage two\nerste Zeile", "expectedVersion": 0})
check("pipeline: waitingApproval after writing", pipeline(t2)["waitingApproval"] is True)
st, feed = rest("GET", "/v1/feed")
item = next((x for x in feed.get("needsYou", []) if x.get("kind") == "plan" and x["taskID"].lower() == t2.lower()), None)
check("feed: needsYou item kind plan with both actions", item is not None and item["id"].lower() == f"plan:{t2}:1".lower() and [a["key"] for a in item["actions"]] == ["approve", "request_changes"], item)
st, center = rest("GET", "/v1/command-center?view=list")
card2 = next((c for c in center.get("items", []) if c["task"]["id"].lower() == t2.lower()), {})
check("command center: planWaiting and plansWaiting", card2.get("planWaiting") is True and center["summary"]["plansWaiting"] >= 1, (card2.get("planWaiting"), center["summary"].get("plansWaiting")))
action = (item or {"actions": [{}]})["actions"][0]
st, p = rest(action.get("method", "POST"), action.get("path", "/"), action.get("body"))
check("feed: the approve action works as sent", st == 200 and p["plan"]["state"] == "approved", (st, p))
st, feed = rest("GET", "/v1/feed")
check("feed: the decided plan is gone", not any(x.get("kind") == "plan" and x["taskID"].lower() == t2.lower() for x in feed.get("needsYou", [])))
err, text, _ = tool(agent, "set_pipeline_step", {"taskID": t2, "step": "developer", "state": "running", "planVersion": 2})
check("MCP: stale planVersion refused", err and text == "plan_changed", text)
err, text, data = tool(agent, "set_pipeline_step", {"taskID": t2, "step": "developer", "state": "failed", "planVersion": 1, "note": "rot"})
check("MCP: step bound to plan version 1", not err and data["steps"][2]["state"] == "failed" and data["steps"][2]["planVersion"] == 1, text[:200])
err, text, _ = tool(agent, "set_pipeline_step", {"taskID": t2, "step": "tester", "state": "running", "planVersion": 1})
check("MCP: switched off step refused", err and text == "step_disabled", text)
check("REST: retry of a pending step refused", reason(rest("POST", f"/v1/tasks/{t2}/pipeline/steps/validation/retry", {}))== (409, "step_not_failed"))
err, text, data = tool(agent, "retry_pipeline_step", {"taskID": t2, "step": "developer", "planVersion": 1, "agentName": "runner@mac"})
check("MCP: retry puts only the failed step back, one round used", not err and data["steps"][2]["state"] == "pending" and data["fixRounds"] == {"used": 1, "max": 2, "remaining": 1} and data["events"][0]["action"] == "step_retried", text[:300])
rest("PUT", f"/v1/tasks/{t2}/pipeline/steps/developer", {"state": "failed"})
st, p = rest("POST", f"/v1/tasks/{t2}/pipeline/steps/developer/retry", {})
check("REST: second retry uses the last round", st == 200 and p["fixRounds"]["remaining"] == 0, p)
rest("PUT", f"/v1/tasks/{t2}/pipeline/steps/developer", {"state": "failed"})
check("REST: no round left", reason(rest("POST", f"/v1/tasks/{t2}/pipeline/steps/developer/retry", {})) == (409, "fix_rounds_exhausted"))
check("migrations: stage 2 tables and column exist", sql("SELECT count(*) FROM project_pipeline_settings") == "1" and sql("SELECT count(*) FROM project_pipeline_settings_events") == "2"
      and sql("SELECT count(*) FROM pragma_table_info('task_pipeline_steps') WHERE name = 'plan_version'") == "1")

# 9. Stage 3 (card F5DD1C00): this script plays the Mac runner over HTTP.
st, cfg = rest("PATCH", f"/v1/projects/{project}/pipeline-settings", {"revision": 2, "steps": {"tester": True}, "maxFixRounds": 2})
check("stage 3: tester switched on again", st == 200 and cfg["steps"]["tester"] is True, cfg)
pairing = rest("POST", "/v1/agents/devices", {"label": "E2E Mac"})[1]
runner = rest("POST", "/v1/runner/pair", {"code": pairing["code"]}, None)[1]["token"]
binding = rest("POST", "/v1/agents/bindings", {"projectID": project, "deviceID": pairing["deviceID"],
    "repositoryKey": "11111111-2222-3333-4444-555555555555", "label": "e2e checkout"})[1]["id"]

def jobs(query="?pipeline=1"):
    return rest("GET", "/v1/runner/jobs" + query, token=runner)[1] or []

def claim(job):
    return rest("POST", f"/v1/runner/jobs/{job}/claim?pipeline=1", token=runner)

def cmd(run, action, body=None):
    return rest("POST", f"/v1/runner/runs/{run}/{action}", {"generation": 1, **(body or {})}, runner)

def result(outcome, plan=None, summary="done"):
    body = {"result": {"summary": summary, "references": [], "checks": [], "limitations": []}, "outcome": outcome}
    if plan: body["plan"] = plan
    return body

def queued_step(name):
    found = jobs()
    ok = [x.get("pipelineStep") for x in found] == [name]
    check(f"stage 3: one queued job for {name}", ok, found)
    return found[0]["id"] if found else "missing"

def run_step(name, outcome="passed", plan=None):
    job = queued_step(name)
    st, run = claim(job)
    check(f"stage 3: claim {name}", st == 200, run)
    st, done = cmd(run.get("id"), "submit", result(outcome, plan))
    check(f"stage 3: submit {name} {outcome}", st == 200, done)
    return job, done

def execution(tid):
    return pipeline(tid).get("execution") or {}

t3 = new_task("Stage three")
check("stage 3: no execution before the start", "execution" not in pipeline(t3))
check("stage 3: anonymous start 401", http("POST", f"/v1/tasks/{t3}/pipeline/execution", {"id": "x", "bindingID": binding})[0] == 401)
exec_id = "aaaaaaaa-0000-4000-8000-000000000001"
st, p = rest("POST", f"/v1/tasks/{t3}/pipeline/execution", {"id": exec_id, "bindingID": binding})
check("stage 3: started, planner queued", st == 200 and p["execution"]["state"] == "running" and p["execution"]["step"] == "planner" and p["execution"]["runnerSupportsPipeline"] is False, p)
st, p = rest("POST", f"/v1/tasks/{t3}/pipeline/execution", {"id": exec_id, "bindingID": binding})
check("stage 3: same id is idempotent", st == 200 and p["execution"]["id"].lower() == exec_id, p)
check("stage 3: second start refused", reason(rest("POST", f"/v1/tasks/{t3}/pipeline/execution", {"id": "aaaaaaaa-0000-4000-8000-000000000002", "bindingID": binding})) == (409, "execution_active"))
check("stage 3: old runner sees no pipeline job", jobs("") == [])
planner = queued_step("planner")
check("stage 3: runner support remembered", execution(t3).get("runnerSupportsPipeline") is True)
check("stage 3: claim without parameter refused", reason(rest("POST", f"/v1/runner/jobs/{planner}/claim", token=runner)) == (409, "pipeline_runner_required"))
st, held = rest("POST", f"/v1/runner/jobs/{planner}/hold", {"reason": "Kontingent-Bremse: rot"}, runner)
check("stage 3: hold shows as progress", st == 200 and held["progress"] == "Kontingent-Bremse: rot" and execution(t3).get("jobProgress") == "Kontingent-Bremse: rot", held)
st, run = claim(planner)
check("stage 3: planner claimed, progress cleared", st == 200 and run["job"]["progress"] == "" and run["job"]["mode"] == "clarify", run)
cmd(run["id"], "checkpoint", {"checkpoint": {"contextRevision": run["job"]["taskRevision"], "sessionReference": "bbbbbbbb-0000-4000-8000-000000000001", "nextStep": "plan"}})
check("stage 3: outcome required", reason(cmd(run["id"], "submit", {"result": result("passed")["result"]})) == (400, "outcome_required"))
check("stage 3: plan required", reason(cmd(run["id"], "submit", result("passed"))) == (400, "plan_required"))
st, done = cmd(run["id"], "submit", result("passed", "# Plan vom Runner"))
check("stage 3: plan submitted, waiting for approval", st == 200 and done["job"]["state"] == "succeeded" and execution(t3)["state"] == "waiting_approval" and pipeline(t3)["plan"]["authorType"] == "run", done)
decide(t3, {"decision": "approve", "version": 1})
developer = queued_step("developer")
st, run = claim(developer)
info = rest("GET", f"/v1/runner/jobs/{developer}", token=runner)[1].get("pipeline") or {}
check("stage 3: developer resumes the planner session with plan and model", info.get("planBody") == "# Plan vom Runner" and info.get("resumeSessionReference") == "bbbbbbbb-0000-4000-8000-000000000001" and info.get("model") == "sonnet", info)
cmd(run["id"], "submit", result("passed"))
run_step("validation")
run_step("tester", "failed")
check("stage 3: blocked after the failed tester", (execution(t3)["state"], execution(t3).get("reason"), execution(t3)["step"]) == ("blocked", "step_failed", "tester") and jobs() == [], execution(t3))
err, text, _ = tool(agent, "retry_pipeline_step", {"taskID": t3, "step": "tester"})
check("stage 3: retry by a connection starts nothing", not err and execution(t3).get("reason") == "continue_required" and jobs() == [], text[:200])
st, p = rest("POST", f"/v1/tasks/{t3}/pipeline/execution/continue", {"planVersion": 1})
check("stage 3: continued by the person", st == 200 and p["execution"]["state"] == "running", p)
run_step("tester")
job, done = run_step("review")
check("stage 3: last step waits for review, execution completed", done["job"]["state"] == "awaiting_review" and execution(t3)["state"] == "completed", done)
check("stage 3: audit of the execution", [a for a in actions(pipeline(t3)) if a.startswith("execution_")] == ["execution_completed", "execution_continued", "execution_started"], actions(pipeline(t3)))
check("stage 3: stop without execution", reason(rest("POST", f"/v1/tasks/{t3}/pipeline/execution/stop", {})) == (409, "no_execution"))
check("stage 3: nothing to run", reason(rest("POST", f"/v1/tasks/{t3}/pipeline/execution", {"id": "aaaaaaaa-0000-4000-8000-000000000003", "bindingID": binding})) == (409, "nothing_to_run"))

# MCP start needs runs:write; stop ends the job.
t4 = new_task("Stage three MCP")
err, text, _ = tool(agent, "start_pipeline_execution", {"taskID": t4, "bindingID": binding})
check("stage 3: MCP start without runs scope refused", err, text[:200])
starter = oauth_token(SCOPES + " runs:read runs:write", "Pipeline Starter")
err, text, data = tool(starter, "start_pipeline_execution", {"taskID": t4, "bindingID": binding})
check("stage 3: MCP start", not err and data["execution"]["state"] == "running", text[:300])
st, p = rest("POST", f"/v1/tasks/{t4}/pipeline/execution/stop", {})
check("stage 3: stopped by the person", st == 200 and p["execution"]["state"] == "stopped" and jobs() == [], p)
check("stage 3: migration", sql("SELECT count(*) FROM task_pipeline_executions") == "2"
      and sql("SELECT count(*) FROM pragma_table_info('agent_jobs') WHERE name LIKE 'pipeline_%'") == "3"
      and sql("SELECT count(*) FROM pragma_table_info('runner_devices') WHERE name = 'pipeline_seen_at'") == "1")

if failures:
    print(f"\n{len(failures)} check(s) failed"); sys.exit(1)
print("\nall checks passed")
