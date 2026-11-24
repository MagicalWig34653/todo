#!/usr/bin/env python3
"""End-to-end check of project lists changed by a mandated connection (card E71B0FF1, ADR 0032 addendum 24.11.2026) against a
running backend: REST for the person (session), MCP over HTTP with real OAuth tokens for the brain and the watcher connection,
a second account as the owner of a foreign connection.
Usage: connection-projects-e2e.py BASE_URL SESSION_PERSON SESSION_STRANGER
"""
import base64, hashlib, json, sys, urllib.error, urllib.parse, urllib.request

base, sess, sess_other = sys.argv[1:4]
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

def project(name, session):
    st, b = http("POST", "/v1/projects", {"name": name}, session)
    assert st in (200, 201), (st, b)
    return j(b)["id"]

SCOPES = "projects:read projects:write tasks:read tasks:write comments:write"
resource = j(http("GET", "/.well-known/oauth-protected-resource/mcp")[1])["resource"]

def connect(session, name, project_ids, scope=SCOPES):
    """Real OAuth: register, authorize, consent (with the connection name), PKCE token. Returns (access token, grant id)."""
    st, b = http("POST", "/oauth/register", {"client_name": "Connection E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = j(b)["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client, "redirect_uri": "http://127.0.0.1:54321/callback", "scope": scope,
        "state": "s", "resource": resource, "code_challenge": challenge, "code_challenge_method": "S256"})
    st, b = http("GET", "/oauth/authorize?" + q, token=session, headers={"Accept": "application/json"})
    if st != 200: raise SystemExit(f"authorize failed: {st} {b[:200]}")
    st, b = http("POST", "/oauth/consent", {"consent_token": j(b)["consent_token"], "approve": True, "project_ids": project_ids, "connection_name": name}, session)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(j(b)["redirect_uri"]).query)["code"][0]
    st, b = http("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client, "resource": resource, "code": code,
        "redirect_uri": "http://127.0.0.1:54321/callback", "code_verifier": verifier})
    token = j(b)["access_token"]
    st, b = http("GET", "/oauth/grants", token=session)
    grant = next(g["id"] for g in j(b) if g.get("name") == name)
    return token, grant

def rpc(tok, method, params=None):
    st, b = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, tok)
    return st, j(b)

def tool(tok, name, args):
    st, body = rpc(tok, "tools/call", {"name": name, "arguments": args})
    res = body["result"]; text = res["content"][0]["text"]
    return res.get("isError", False), text, j(text)

p1, p2, p3 = project("E2E Eins", sess), project("E2E Zwei", sess), project("E2E Drei", sess)
foreign_project = project("E2E Fremd", sess_other)
brain, brain_grant = connect(sess, "Brain", [p1])
watcher, watcher_grant = connect(sess, "Wächter (Mac)", [p1])
_, foreign_grant = connect(sess_other, "Fremd", [foreign_project])

def project_ids(tok):
    err, text, body = tool(tok, "list_projects", {})
    return {p["id"] for p in body} if not err else set()

check("watcher sees only its first project", project_ids(watcher) == {p1}, project_ids(watcher))

# Without a mandate nothing works.
err, text, _ = tool(brain, "list_connections", {})
check("list_connections without mandate is brain_mandate_required", err and text == "brain_mandate_required", text)
err, text, _ = tool(brain, "set_connection_projects", {"grantID": watcher_grant, "addProjectIDs": [p2], "quote": "Lino: ja"})
check("set_connection_projects without mandate is brain_mandate_required", err and text == "brain_mandate_required", text)

# The person gives the mandate (REST, session only); OAuth tokens may not.
st, b = http("PUT", "/v1/settings/brain-mandate", {"grantID": brain_grant, "projectIDs": [p1, p2]}, brain)
check("an OAuth token cannot give a mandate", st == 401, st)
st, b = http("PUT", "/v1/settings/brain-mandate", {"grantID": brain_grant, "projectIDs": [p1, p2]}, sess)
check("person gives the mandate 200", st == 200, (st, b))
st, mandates_before = http("GET", "/v1/settings/brain-mandate", token=sess)

# Reading.
err, text, body = tool(brain, "list_connections", {})
ids = [c["grantID"] for c in body] if not err else []
check("list_connections shows the watcher only (not itself, not the stranger's)", ids == [watcher_grant], text)
check("watcher entry lists only mandate projects", not err and [p["id"] for p in body[0]["projects"]] == [p1] and body[0]["name"] == "Wächter (Mac)", text)

# Setting.
err, text, body = tool(brain, "set_connection_projects", {"grantID": watcher_grant, "addProjectIDs": [p2], "quote": "Lino: gib dem Waechter Projekt Zwei frei"})
check("add a mandate project", not err and body["added"] == [p2], text)
check("watcher now sees the project through its own token", project_ids(watcher) == {p1, p2}, project_ids(watcher))
err, text, _ = tool(brain, "set_connection_projects", {"grantID": watcher_grant, "addProjectIDs": [p2], "quote": "Lino: nochmal"})
check("adding again is idempotent", not err, text)
err, text, _ = tool(brain, "set_connection_projects", {"grantID": watcher_grant, "addProjectIDs": [p2, p3], "quote": "Lino: ja"})
check("a project outside the mandate refuses the whole call", err and text == "outside_brain_mandate", text)
check("nothing was applied partially", project_ids(watcher) == {p1, p2})
err, text, _ = tool(brain, "set_connection_projects", {"grantID": brain_grant, "addProjectIDs": [p2], "quote": "Lino: ja"})
check("own connection is refused", err and text == "cannot_change_own_connection", text)
err, text, _ = tool(brain, "set_connection_projects", {"grantID": foreign_grant, "addProjectIDs": [p2], "quote": "Lino: ja"})
err2, text2, _ = tool(brain, "set_connection_projects", {"grantID": "00000000-0000-4000-8000-000000000000", "addProjectIDs": [p2], "quote": "Lino: ja"})
check("a foreign person's connection is not_found, like an unknown one", err and text == "not_found" and text == text2, (text, text2))
err, text, _ = tool(brain, "set_connection_projects", {"grantID": watcher_grant, "removeProjectIDs": [p2]})
check("a quote is mandatory", err and text == "quote_required", text)
err, text, body = tool(brain, "set_connection_projects", {"grantID": watcher_grant, "removeProjectIDs": [p2], "quote": "Lino: wieder weg"})
check("remove a mandate project", not err and body["removed"] == [p2], text)
check("watcher lost the project again", project_ids(watcher) == {p1}, project_ids(watcher))

# Audit and mandates.
st, b = http("GET", "/v1/settings/brain-mandate/audit", token=sess)
items = j(b)["items"]
kinds = [i["kind"] for i in items]
check("audit lists both changes, newest first", kinds == ["connection.project_removed", "connection.project_added"], kinds)
check("audit entry carries quote, acting and changed connection", items[1]["quote"] == "Lino: gib dem Waechter Projekt Zwei frei"
      and items[1]["grantID"].lower() == brain_grant.lower() and items[1]["subjectID"].lower() == watcher_grant.lower() and items[1].get("taskID") is None, items[1])
st, mandates_after = http("GET", "/v1/settings/brain-mandate", token=sess)
check("mandates are unchanged by all of this", [(m["grantID"], m["projectIDs"], m["active"]) for m in j(mandates_before)["mandates"]]
      == [(m["grantID"], m["projectIDs"], m["active"]) for m in j(mandates_after)["mandates"]])
st, b = rpc(brain, "tools/list")
names = [t["name"] for t in b["result"]["tools"]]
check("no MCP tool changes a mandate", not [n for n in names if "mandate" in n], names)

# Revoke wins immediately.
st, _ = http("DELETE", f"/v1/settings/brain-mandate/{brain_grant}", token=sess)
check("person revokes the mandate 204", st == 204, st)
err, text, _ = tool(brain, "set_connection_projects", {"grantID": watcher_grant, "addProjectIDs": [p2], "quote": "Lino: ja"})
check("after the revoke the same token is refused", err and text == "brain_mandate_required", text)
check("watcher stayed as it was", project_ids(watcher) == {p1})

print("FAILURES: " + ", ".join(failures) if failures else "all checks passed")
sys.exit(1 if failures else 0)
