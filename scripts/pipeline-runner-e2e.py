#!/usr/bin/env python3
"""End-to-end check of pipeline stage 3 (card F5DD1C00) through the REAL todo-runner binary against a running backend.

The runner is paired over the real pairing code and runs with its own state folder. `claude` is a fake script written here:
it prints deterministic stream-json result lines and logs its argv, so every claude start of the runner is visible.
The validation and budget commands are local scripts configured with the runner CLI.
Usage: pipeline-runner-e2e.py BASE_URL SESSION SCRATCH_DIR   (env E2E_RUNNER_BIN: the built todo-runner)
"""
import json, os, re, signal, subprocess, sys, time, urllib.error, urllib.request

base, sess, scratch = sys.argv[1:4]
runner_bin = os.environ["E2E_RUNNER_BIN"]
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

def http(method, path, body=None, token=sess):
    h = {}
    if token: h["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with urllib.request.urlopen(req) as r: raw = r.read(); status = r.status
    except urllib.error.HTTPError as e: raw = e.read(); status = e.code
    try: return status, json.loads(raw)
    except Exception: return status, {}

def why(answer): return (answer[0], answer[1].get("reason"))

def wait_for(cond, timeout=45, step=0.4):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if cond(): return True
        except Exception: pass
        time.sleep(step)
    return False

# --- local world: repo folder, control files, fake claude, validation and budget commands -----------------------------
home, repo, ctl = (os.path.join(scratch, d) for d in ("runner-home", "repo", "ctl"))
for d in (home, repo, ctl): os.makedirs(d, exist_ok=True)
claude_log = os.path.join(ctl, "claude.log")
fake = os.path.join(scratch, "fake-claude")
with open(fake, "w") as f: f.write(r'''#!/usr/bin/env python3
import json, os, sys, time
ctl, a = %r, sys.argv[1:]
def val(flag): return a[a.index(flag) + 1] if flag in a else None
schema = json.loads(val("--json-schema") or "{}")
required = schema.get("required", [])
prompt = val("-p") or ""
step = next((s for s in ("planner", "developer", "tester", "review") if "Pipeline step: " + s in prompt), "manual")
session = val("--resume") or val("--session-id")
tools = (val("--allowedTools") or "").split(",")
with open(os.path.join(ctl, "claude.log"), "a") as f:
    f.write(json.dumps({"step": step, "session": session, "resume": "--resume" in a, "tools": tools, "required": required,
                        "model": val("--model"), "effort": val("--effort"), "cwd": os.getcwd(), "argv": a, "prompt": prompt}) + "\n")
def control(name, default):
    try: return open(os.path.join(ctl, name)).read().strip() or default
    except OSError: return default
time.sleep(float(control("claude-delay", "0.3")))
out = {"text": "fake " + step + " done"}
if step == "planner": out["plan"] = "# Plan vom Runner\n\n- schritt eins\n- schritt zwei"
if step == "developer":
    with open(os.path.join(os.getcwd(), "dev-" + str(int(time.time() * 1000)) + ".txt"), "w") as f: f.write("written by fake claude\n")
if "verdict" in required: out["verdict"] = control("verdict-" + step, "passed")
print(json.dumps({"type": "system", "subtype": "init", "session_id": session}))
print(json.dumps({"type": "result", "subtype": "success", "session_id": session, "is_error": False, "result": out["text"], "structured_output": out}))
''' % ctl)
os.chmod(fake, 0o755)

def script(name, body):
    path = os.path.join(scratch, name)
    with open(path, "w") as f: f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)
    return path
validation_sh = script("validate.sh", f'echo run >> "{ctl}/validation.log"\necho VALIDATION-SECRET-OUTPUT\nexit $(cat "{ctl}/validation-exit" 2>/dev/null || echo 0)')
budget_sh = script("budget.sh", f'cat "{ctl}/budget.json"')
def control(name, text):
    with open(os.path.join(ctl, name), "w") as f: f.write(text)
control("budget.json", '{"ampel":"gruen","allowed":true}')

def invocations(): 
    try: return [json.loads(l) for l in open(claude_log) if l.strip()]
    except OSError: return []
def validations():
    try: return len([l for l in open(os.path.join(ctl, "validation.log")) if l.strip()])
    except OSError: return 0

env = dict(os.environ, TODO_RUNNER_HOME=home, TODO_RUNNER_SECRETS="file", TODO_RUNNER_CLAUDE=fake, TODO_RUNNER_INTERVAL="1")
def cli(*args, check_rc=True):
    r = subprocess.run([runner_bin, *args], env=env, capture_output=True, text=True, timeout=60)
    if check_rc and r.returncode != 0: raise SystemExit(f"todo-runner {args[0]} failed rc={r.returncode}: {r.stdout}{r.stderr}")
    return r

# --- server world ---------------------------------------------------------------------------------------------------------
project = http("POST", "/v1/projects", {"name": "Runner E2E"})[1]["id"]
pairing = http("POST", "/v1/agents/devices", {"label": "E2E runner"})[1]
cli("pair", base, pairing["code"])
approved = cli("approve", repo).stdout
repo_key = re.search(r"Repository-UUID: ([0-9a-f-]{36})", approved).group(1)
binding = http("POST", "/v1/agents/bindings", {"projectID": project, "deviceID": pairing["deviceID"], "repositoryKey": repo_key, "label": "e2e repo"})[1]["id"]
cli("validation", repo, "--timeout", "60", "--", validation_sh)
cli("budget", "--", budget_sh)
status_text = cli("status").stdout
check("runner CLI: status shows the local validation and budget commands", "Kontingent-Bremse: " + budget_sh in status_text and "Validierung (repo): " + validation_sh in status_text, status_text)
device_token = open(os.path.join(home, "secret-device-token-" + pairing["deviceID"].lower())).read().strip()

def settings(patch):
    cur = http("GET", f"/v1/projects/{project}/pipeline-settings")[1]
    return http("PATCH", f"/v1/projects/{project}/pipeline-settings", {"revision": cur["revision"], **patch})
st, cfg = settings({"steps": {s: True for s in ("planner", "approval", "developer", "validation", "tester", "review")},
                    "roles": {"developer": {"model": "sonnet", "effort": "high"}}, "maxFixRounds": 2})
check("settings: all steps on, developer model and effort", st == 200 and cfg["roles"]["developer"]["model"] == "sonnet", cfg)

def new_task(title): return http("POST", "/v1/tasks", {"projectID": project, "title": title, "description": "Runner end to end"})[1]["id"]
def pipeline(t): return http("GET", f"/v1/tasks/{t}/pipeline")[1]
def execution(t): return pipeline(t).get("execution") or {}
def start(t, n): return http("POST", f"/v1/tasks/{t}/pipeline/execution", {"id": f"eeeeeeee-0000-4000-8000-{n:012d}", "bindingID": binding})
def approve(t, v=None):
    return http("POST", f"/v1/tasks/{t}/plan/decision", {"decision": "approve", "version": v or pipeline(t)["plan"]["version"]})
def job_state(job_id): return http("GET", f"/v1/agents/jobs/{job_id}")[1].get("job", {}).get("state")
def retry(t, step): return http("POST", f"/v1/tasks/{t}/pipeline/steps/{step}/retry", {})
def steps_seen(since=0): return [i["step"] for i in invocations()[since:]]
def settle(seconds=4): time.sleep(seconds)   # several runner ticks (interval 1 s): the runner must stay idle

runner = subprocess.Popen([runner_bin, "run"], env=env, stdout=open(os.path.join(scratch, "runner.out"), "w"), stderr=subprocess.STDOUT,
                          start_new_session=True)
try:
    # === A: planner, approval gate, developer resume, validation, tester failed, retry, review ============================
    ta = new_task("Runner A")
    st, p = start(ta, 1)
    check("A: execution started", st == 200 and p["execution"]["state"] == "running" and p["execution"]["step"] == "planner", p)
    check("A: planner ran once through the runner and the plan was written",
          wait_for(lambda: execution(ta).get("state") == "waiting_approval") and steps_seen() == ["planner"], (execution(ta), steps_seen()))
    planner_call = invocations()[0]
    pl = pipeline(ta)["plan"]
    check("A: plan stored by the runner (author run) with the claude text", pl["authorType"] == "run" and pl["body"].startswith("# Plan vom Runner") and pl["version"] == 1, pl)
    check("A: planner is read-only and used the plan schema", "Edit" not in planner_call["tools"] and "Write" not in planner_call["tools"] and "plan" in planner_call["required"], planner_call["tools"])
    check("A: execution reports a pipeline-capable runner", execution(ta).get("runnerSupportsPipeline") is True, execution(ta))
    settle()
    check("A: nothing runs while waiting for approval", steps_seen() == ["planner"] and validations() == 0 and execution(ta)["state"] == "waiting_approval", (steps_seen(), validations()))

    control("verdict-tester", "failed")
    check("A: plan approved", approve(ta)[0] == 200)
    check("A: developer, validation and tester ran, then blocked", wait_for(lambda: execution(ta).get("state") == "blocked"), execution(ta))
    seen = invocations()
    check("A: order developer, tester (validation without claude)", steps_seen() == ["planner", "developer", "tester"] and validations() == 1, (steps_seen(), validations()))
    dev = seen[1]
    check("A: developer resumes the planner session", dev["resume"] and dev["session"] == planner_call["session"], (dev["session"], planner_call["session"]))
    check("A: developer has edit tools, model and effort", "Edit" in dev["tools"] and dev["model"] == "sonnet" and dev["effort"] == "high" and "Pipeline step: developer" in dev["prompt"] and "Plan vom Runner" in dev["prompt"], dev)
    check("A: the developer's fake claude ran in the approved folder", os.path.realpath(dev["cwd"]) == os.path.realpath(repo) and any(f.startswith("dev-") for f in os.listdir(repo)), dev["cwd"])
    tester = seen[2]
    check("A: tester starts a fresh session with a verdict field", not tester["resume"] and tester["session"] != planner_call["session"] and "verdict" in tester["required"], tester)
    ex = execution(ta)
    check("A: failed tester blocks the execution", (ex["state"], ex.get("reason"), ex["step"]) == ("blocked", "step_failed", "tester"), ex)
    settle()
    check("A: nothing further runs after the failure", steps_seen() == ["planner", "developer", "tester"] and validations() == 1, (steps_seen(), validations()))
    steps = {s["step"]: s["state"] for s in pipeline(ta)["steps"]}
    check("A: step states on the card", steps["planner"] == "done" and steps["developer"] == "done" and steps["validation"] == "done" and steps["tester"] == "failed" and steps["review"] == "pending", steps)

    control("verdict-tester", "passed")
    before = len(invocations())
    check("A: retry accepted", retry(ta, "tester")[0] == 200)
    check("A: retry runs the tester again and then the review, completing the execution",
          wait_for(lambda: execution(ta).get("state") == "completed"), execution(ta))
    check("A: after retry only tester and review started (no developer, no validation)", steps_seen(before) == ["tester", "review"] and validations() == 1, (steps_seen(before), validations()))
    review = invocations()[-1]
    check("A: review is read-only with a verdict", "Edit" not in review["tools"] and "Write" not in review["tools"] and "verdict" in review["required"], review)
    ex = execution(ta)
    check("A: final review pending, execution completed", ex["state"] == "completed" and ex.get("jobState") == "awaiting_review" and job_state(ex["jobID"]) == "awaiting_review", ex)
    settle(3)
    check("A: idle after completion", steps_seen(before) == ["tester", "review"], steps_seen(before))

    # === B: fix round limit =============================================================================================
    check("B: maxFixRounds 1", settings({"maxFixRounds": 1})[0] == 200)
    control("verdict-tester", "failed")
    tb = new_task("Runner B")
    start(tb, 2)
    wait_for(lambda: execution(tb).get("state") == "waiting_approval")
    approve(tb)
    check("B: first tester failure blocks", wait_for(lambda: execution(tb).get("state") == "blocked"), execution(tb))
    n = len(invocations())
    check("B: retry 1 accepted", retry(tb, "tester")[0] == 200)
    check("B: tester failed again", wait_for(lambda: execution(tb).get("state") == "blocked" and steps_seen(n) == ["tester"]), (execution(tb), steps_seen(n)))
    check("B: second retry refused, fix rounds exhausted", why(retry(tb, "tester")) == (409, "fix_rounds_exhausted"))
    print("info B: blocked reason after the last failure:", execution(tb).get("reason"))
    settle(3)
    check("B: nothing else runs", steps_seen(n) == ["tester"], steps_seen(n))
    http("POST", f"/v1/tasks/{tb}/pipeline/execution/stop", {})
    control("verdict-tester", "passed")
    settings({"maxFixRounds": 2})

    # === C: budget brake (red) ==========================================================================================
    control("budget.json", '{"ampel":"rot","allowed":true}')
    tc = new_task("Runner C")
    n = len(invocations())
    start(tc, 3)
    hold = "Kontingent-Bremse: "
    check("C: job stays queued with the hold text", wait_for(lambda: execution(tc).get("jobState") == "queued" and (execution(tc).get("jobProgress") or "").startswith(hold)), execution(tc))
    settle()
    ex = execution(tc)
    check("C: no claim and no claude start under the brake", ex["jobState"] == "queued" and steps_seen(n) == [], (ex, steps_seen(n)))
    print("info C: hold text:", ex.get("jobProgress"))
    old_style = http("GET", "/v1/runner/jobs", token=device_token)
    check("old runner poll (no ?pipeline=1) sees no pipeline job", old_style == (200, []) or (old_style[0] == 200 and all("pipelineStep" not in j for j in (old_style[1] or []))), old_style)
    new_style = http("GET", "/v1/runner/jobs?pipeline=1", token=device_token)[1]
    check("pipeline poll sees the held planner job", [j.get("pipelineStep") for j in new_style] == ["planner"], new_style)
    check("old style claim refused", why(http("POST", f"/v1/runner/jobs/{new_style[0]['id']}/claim", token=device_token)) == (409, "pipeline_runner_required"))
    control("budget.json", '{"ampel":"gruen","allowed":true}')
    check("C: lifting the brake lets the planner run", wait_for(lambda: execution(tc).get("state") == "waiting_approval" and steps_seen(n) == ["planner"]), (execution(tc), steps_seen(n)))
    http("POST", f"/v1/tasks/{tc}/pipeline/execution/stop", {})

    # === D: validation still runs under the brake ======================================================================
    st, cfg = settings({"steps": {"planner": False, "developer": False, "tester": False, "review": False}})
    check("D: only validation switched on", st == 200 and cfg["steps"]["validation"] is True and cfg["steps"]["developer"] is False, (st, cfg))
    control("budget.json", '{"ampel":"rot"}')
    control("validation-exit", "0")
    td = new_task("Runner D")
    n, v = len(invocations()), validations()
    st, p = start(td, 4)
    check("D: execution started with validation first", st == 200 and p["execution"]["step"] == "validation", p)
    check("D: validation ran under the red brake, without claude", wait_for(lambda: validations() == v + 1 and execution(td).get("state") == "completed"), (execution(td), validations()))
    check("D: claude was not invoked", steps_seen(n) == [], steps_seen(n))
    secret_hits = subprocess.run(["sqlite3", os.path.join(scratch, "e2e.sqlite"), ".dump"], capture_output=True, text=True).stdout
    check("validation output stays on the Mac (not in the server database)", "VALIDATION-SECRET-OUTPUT" not in secret_hits and validation_sh not in secret_hits and repo not in secret_hits)
    out_dir = os.path.join(home, "validation-output")
    logs = os.listdir(out_dir) if os.path.isdir(out_dir) else []
    check("validation output kept in a local 0600 file", len(logs) == 1 and (os.stat(os.path.join(out_dir, logs[0])).st_mode & 0o777) == 0o600 and "VALIDATION-SECRET-OUTPUT" in open(os.path.join(out_dir, logs[0])).read(), logs)
    control("budget.json", '{"ampel":"gruen"}')

    # === E: failing validation =========================================================================================
    control("validation-exit", "3")
    te = new_task("Runner E")
    start(te, 5)
    check("E: failing validation blocks the execution", wait_for(lambda: execution(te).get("state") == "blocked"), execution(te))
    st_e = {s["step"]: s for s in pipeline(te)["steps"]}
    check("E: validation step failed with exit code and duration only", st_e["validation"]["state"] == "failed" and "Exit-Code 3" in (st_e["validation"].get("note") or "") and "VALIDATION-SECRET" not in (st_e["validation"].get("note") or ""), st_e["validation"])
    check("E: claude never invoked for validation", steps_seen(n) == [], steps_seen(n))
finally:
    runner.send_signal(signal.SIGTERM)
    try: runner.wait(timeout=10)
    except subprocess.TimeoutExpired: runner.kill()

log = open(os.path.join(scratch, "runner.out")).read()
check("runner process printed no crash", "Fatal error" not in log and "Segmentation" not in log, log[-300:])
print(f"{len(failures)} failure(s)" if failures else "all checks passed")
sys.exit(1 if failures else 0)
