#!/usr/bin/env python3
"""End-to-end check of project onboarding against a running backend (ADR 0018).

Drives the real HTTP surface: OAuth (dynamic client registration, authorize, consent, PKCE token) and MCP JSON-RPC.
Simulates what an agent does after /setup_project: reads a sample repository (README + plan file), imports the plan twice,
records the sync and checks the command center. Staleness is simulated by moving last_synced_at back through the
database command given in --age-cmd. Usage: onboarding-e2e.py BASE_URL SESSION_TOKEN SAMPLE_REPO AGE_CMD
(AGE_CMD is a shell command that receives the project id in $PROJECT_ID and ages the sync by 4 days.)
"""
import base64, hashlib, json, os, re, secrets, subprocess, sys, urllib.parse, urllib.request

base, session, repo, age_cmd = sys.argv[1:5]
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

def http(method, path, body=None, token=None, raw=False):
    req = urllib.request.Request(base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req) as r: data = r.read()
        return r.status, (data if raw else json.loads(data or b"null"))
    except urllib.error.HTTPError as e:
        data = e.read()
        try: return e.code, json.loads(data)
        except Exception: return e.code, data

# --- OAuth like an MCP client (RFC 7591 + PKCE) ---------------------------------------------------------------------
redirect = "http://127.0.0.1:54321/callback"
_, client = http("POST", "/oauth/register", {"client_name": "Onboarding E2E", "redirect_uris": [redirect]})
verifier = secrets.token_urlsafe(48)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
scope = "projects:read projects:write tasks:read tasks:write comments:write attachments:read agents:read"
_, meta = http("GET", "/.well-known/oauth-protected-resource/mcp")
resource = meta["resource"]
q = urllib.parse.urlencode({"response_type": "code", "client_id": client["client_id"], "redirect_uri": redirect, "scope": scope,
                            "state": "s", "resource": resource, "code_challenge": challenge, "code_challenge_method": "S256"})
st, auth = http("GET", "/oauth/authorize?" + q, token=session)
check("authorize shows consent data", st == 200 and "consent_token" in auth, auth)
# projects:write lets a connection start without any pre-selected project.
st, consent = http("POST", "/oauth/consent", {"consent_token": auth["consent_token"], "approve": True, "project_ids": []}, token=session)
check("consent without projects accepted with projects:write", st == 200, consent)
code = urllib.parse.parse_qs(urllib.parse.urlparse(consent["redirect_uri"]).query)["code"][0]
st, tok = http("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client["client_id"], "resource": resource,
                                       "code": code, "redirect_uri": redirect, "code_verifier": verifier})
check("token exchange", st == 200, tok)
access = tok["access_token"]

n = 0
def rpc(method, params=None):
    global n; n += 1
    st, r = http("POST", "/mcp", {"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}, token=access)
    return r
def tool(name, args):
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    text = r["content"][0]["text"]
    try: return r["isError"], json.loads(text)
    except Exception: return r["isError"], text

# --- MCP handshake and prompts --------------------------------------------------------------------------------------
init = rpc("initialize", {"protocolVersion": "2025-11-25"})["result"]
check("server advertises prompts", "prompts" in init["capabilities"])
prompts = {p["name"] for p in rpc("prompts/list")["result"]["prompts"]}
check("three prompts", prompts == {"setup_project", "sync_project", "session_start"}, prompts)
text = rpc("prompts/get", {"name": "setup_project", "arguments": {"name": "Sample"}})["result"]["messages"][0]["content"]["text"]
steps = re.findall(r"`(find_project_by_repository|create_project|import_plan|set_agent_brief|record_sync)", text)
order = [s for i, s in enumerate(steps) if s not in steps[:i]]
check("prompt orders the tools find -> create -> import -> brief -> record_sync",
      order == ["find_project_by_repository", "create_project", "import_plan", "set_agent_brief", "record_sync"], order)

# --- the agent's work, following the prompt ---------------------------------------------------------------------------
remote = subprocess.run(["git", "-C", repo, "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
head = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
err, found = tool("find_project_by_repository", {"repository": remote})
check("repository not known yet", not err and found["found"] is False and found["matches"] == [], found)

items, current = [], None
for line in open(os.path.join(repo, "docs/ARBEITSPLAN.md"), encoding="utf-8"):
    m = re.match(r"^## (.+)", line)
    if m:
        current = {"externalKey": "docs/ARBEITSPLAN.md#" + re.sub(r"[^a-z0-9]+", "-", m.group(1).lower()).strip("-"), "title": m.group(1), "children": []}
        items.append(current); continue
    m = re.match(r"^- \[( |x)\] (.+)", line)
    if m and current is not None:
        title = m.group(2)
        current["children"].append({"externalKey": current["externalKey"] + "/" + re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-"),
                                    "title": title, "status": "done" if m.group(1) == "x" else "open"})
items = [i for i in items if i["children"]]
check("sample plan parsed", len(items) == 2 and sum(len(i["children"]) for i in items) == 5, items)

err, created = tool("create_project", {"name": "Sample", "description": "E2E sample", "repository": remote})
check("create_project binds the repository", not err and created["sync"]["bound"] and created["sync"]["state"] == "never", created)
pid = created["project"]["id"]
err, again = tool("find_project_by_repository", {"repository": remote.replace("https://", "git@").replace(".com/", ".com:")})
check("another URL form of the same repository finds the project", not err and again["found"] and again["matches"][0]["projectID"] == pid, again)
err, dup = tool("create_project", {"name": "Duplicate", "repository": remote})
check("duplicate project for the repository rejected", err and dup == "repository_already_bound", dup)

plan = {"projectID": pid, "applyWorkflowColumns": True, "items": items}
err, first = tool("import_plan", plan)
check("first import creates 7 items (2 features + 5 subtasks)", not err and first["created"] == 7 and first["columnsCreated"], first)
err, second = tool("import_plan", plan)
check("second import is a no-op", not err and second["created"] == 0 and second["updated"] == 0 and second["unchanged"] == 7, second)
err, structure = tool("get_project_structure", {"projectID": pid})
check("standard columns exist", not err and structure["template"]["complete"], structure)
err, _ = tool("set_agent_brief", {"projectID": pid, "text": "## Goals\nKeep Todolino current.", "version": structure["brief"]["version"]})
check("agent brief written", not err)

def center():
    _, c = tool("get_command_center", {"projectID": pid})
    entry = next(p for p in c["projects"] if p["projectID"] == pid)
    return entry["sync"], c["summary"]
sync, summary = center()
check("before record_sync the project is 'never' and counted stale", sync["state"] == "never" and summary["staleProjects"] == 1, (sync, summary))
err, rec = tool("record_sync", {"projectID": pid, "summary": "Initial setup from ARBEITSPLAN.md", "repoRef": f"main@{head}", "agentName": "e2e-agent"})
check("record_sync -> fresh", not err and rec["state"] == "fresh" and rec["repoRef"] == f"main@{head}", rec)
sync, summary = center()
check("command center shows fresh and 0 stale", sync["state"] == "fresh" and summary["staleProjects"] == 0 and sync["lastSyncedBy"] == "e2e-agent", (sync, summary))

subprocess.run(age_cmd, shell=True, check=True, env={**os.environ, "PROJECT_ID": pid})
sync, summary = center()
check("after 4 simulated days: stale, daysSince 4, counted", sync["state"] == "stale" and sync["daysSince"] == 4 and summary["staleProjects"] == 1, (sync, summary))
err, stale = tool("get_stale_projects", {})
check("get_stale_projects lists it", not err and [s["projectID"] for s in stale] == [pid], stale)
err, _ = tool("record_sync", {"projectID": pid, "summary": "Reconciled again"})
sync, _ = center()
check("a new record_sync makes it fresh again", sync["state"] == "fresh", sync)

# Foreign / ungranted access is a 404, also for brand-new ids.
err, nf = tool("get_sync_status", {"projectID": "00000000-0000-4000-8000-000000000000"})
check("unknown project -> not_found", err and nf == "not_found", nf)

print("\nRESULT:", "FAILED " + ", ".join(failures) if failures else "all checks passed")
sys.exit(1 if failures else 0)
