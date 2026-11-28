#!/usr/bin/env python3
"""End-to-end check of responsibility (cards 8B4BAC2E and E9300901, ADR 0043) against a running backend and a real database.

Real HTTP and a real OAuth token for /mcp, SQLite or MariaDB (accounts are seeded with SQL, everything else goes through the API).
Usage: assignment-e2e.py BASE_URL sqlite|mariadb   (environment as set by assignment-e2e.sh)
"""
import base64, hashlib, json, os, secrets, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

base, db = sys.argv[1:3]
failures = []
passed = 0


def check(name, cond, detail=""):
    global passed
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {str(detail)[:400]}"))
    if cond: passed += 1
    else: failures.append(name)


def sql(statement):
    if db == "sqlite":
        cmd = ["sqlite3", "-cmd", ".timeout 5000", os.environ["DB_NAME"], statement]
    else:
        cmd = ["docker", "exec", os.environ["E2E_MARIADB_CONTAINER"], "mariadb", "-uroot", "-p" + os.environ["DB_PASSWORD"], "-N", "-B",
               os.environ["DB_NAME"], "-e", statement]
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def db_uuid(u): return f"'{u.upper()}'" if db == "sqlite" else f"UNHEX('{u.replace('-', '')}')"
def db_time(t): return str(t.timestamp()) if db == "sqlite" else f"'{t.strftime('%Y-%m-%d %H:%M:%S')}'"


def account(name):
    user, token = str(uuid.uuid4()), secrets.token_hex(24)
    now = datetime.now(timezone.utc)
    sql(f"INSERT INTO users (id, display_name, is_admin, created_at) VALUES ({db_uuid(user)}, '{name}', 0, {db_time(now)});")
    sql(f"INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ({db_uuid(str(uuid.uuid4()))}, {db_uuid(user)}, "
        f"'{hashlib.sha256(token.encode()).hexdigest()}', {db_time(now + timedelta(days=1))}, {db_time(now)});")
    return user.upper(), token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


opener = urllib.request.build_opener(NoRedirect)


def http(method, path, body=None, token=None, headers=None):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with opener.open(req) as r: status, out = r.status, r.read()
    except urllib.error.HTTPError as e: status, out = e.code, e.read()
    try: return status, json.loads(out)
    except Exception: return status, out


owner, owner_s = account("Owner E2E")
designer, designer_s = account("Designer E2E")
other, other_s = account("Other E2E")
stranger, stranger_s = account("Stranger E2E")
reader, reader_s = account("Reader E2E")

st, p = http("POST", "/v1/projects", {"name": "Assignment E2E"}, owner_s); project = p["id"]
st, p = http("POST", "/v1/projects", {"name": "Outside grant"}, owner_s); outside = p["id"]
grants = {}
for who in (designer, other):
    st, g = http("PUT", f"/v1/projects/{project}/grants", {"principalType": "person", "principalID": who, "role": "edit"}, owner_s)
    check("grant", st == 200, g); grants[who] = g["id"]
st, g = http("PUT", f"/v1/projects/{project}/grants", {"principalType": "person", "principalID": reader, "role": "read"}, owner_s)
check("read grant", st == 200, g)
st, b = http("PATCH", f"/v1/projects/{project}/pipeline-settings", {"revision": 0, "notifyOnWaitingApproval": True}, owner_s)
check("waiting plans are announced", st == 200, b)


def card(title):
    st, t = http("POST", "/v1/tasks", {"projectID": project, "title": title}, owner_s)
    return t["id"]


def oauth_token(session, scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Assignment E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = b["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    resource = http("GET", "/.well-known/oauth-protected-resource/mcp")[1]["resource"]
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client, "redirect_uri": "http://127.0.0.1:54321/callback", "scope": scope,
                                "state": "s", "resource": resource, "code_challenge": challenge, "code_challenge_method": "S256"})
    st, b = http("GET", "/oauth/authorize?" + q, token=session, headers={"Accept": "application/json"})
    if st != 200: raise SystemExit(f"authorize failed: {st} {b}")
    st, b = http("POST", "/oauth/consent", {"consent_token": b["consent_token"], "approve": True, "project_ids": [project]}, session)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(b["redirect_uri"]).query)["code"][0]
    st, b = http("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client, "resource": resource, "code": code,
                                          "redirect_uri": "http://127.0.0.1:54321/callback", "code_verifier": verifier})
    return b["access_token"]


def tool(tok, name, args):
    st, b = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}, tok)
    res = b["result"]; text = res["content"][0]["text"]
    try: parsed = json.loads(text)
    except Exception: parsed = None
    return res.get("isError", False), text, parsed


# The agent works with the owner's connection.
agent = oauth_token(owner_s, "projects:read tasks:read tasks:write")
st, listed = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, agent)
names = [t["name"] for t in listed["result"]["tools"]]
check("new tools are listed", {"list_assignees", "set_assignee", "list_for_me"} <= set(names), names)

err, text, data = tool(agent, "list_assignees", {"projectID": project})
people = {p["userID"]: p for p in (data or {}).get("items", [])}
check("agent sees the four people of the project", not err and set(people) == {owner, designer, other, reader}, text)
check("only name, id, kinds and isMe", all(set(p) == {"userID", "displayName", "assignableTo", "isMe"} for p in people.values()), text)
check("isMe is the person of the connection", people.get(owner, {}).get("isMe") is True and people.get(designer, {}).get("isMe") is False, text)

design_card, open_card = card("Colours"), card("Release")
err, text, data = tool(agent, "set_assignee", {"taskID": design_card, "assigneeID": designer})
check("MCP set_assignee on a card", not err and data["assigneeID"] == designer, text)
err, text, question = tool(agent, "ask_question", {"taskID": open_card, "prompt": "Which blue?", "options": ["A", "B"], "assigneeID": designer})
check("MCP ask_question with assignee", not err and question["assigneeID"] == designer, text)
err, text, review = tool(agent, "request_review", {"taskID": open_card, "summary": "Look at the colours", "assigneeID": designer})
check("MCP request_review with assignee", not err and review["assigneeID"] == designer and review["reviewerID"] == designer, text)
err, text, _ = tool(agent, "ask_question", {"taskID": open_card, "prompt": "For a stranger?", "assigneeID": stranger})
check("MCP refuses a stranger", err and text == "invalid_assignee", text)
err, text, _ = tool(agent, "set_assignee", {"taskID": design_card, "assigneeID": str(uuid.uuid4())})
check("MCP refuses an unknown account the same way", err and text == "invalid_assignee", text)
st, outside_task = http("POST", "/v1/tasks", {"projectID": outside, "title": "Hidden"}, owner_s)
err, text, _ = tool(agent, "set_assignee", {"taskID": outside_task["id"], "assigneeID": owner})
check("MCP outside the grant is not_found", err and text == "not_found", text)


def for_me(session):
    st, b = http("GET", "/v1/for-me", token=session)
    check("for-me 200", st == 200, b)
    return ({t["id"] for t in b["tasks"]}, {q["id"] for q in b["questions"]}, {r["id"] for r in b["reviews"]})


check("designer sees exactly the assigned items", for_me(designer_s) == ({design_card}, {question["id"]}, {review["id"]}), for_me(designer_s))
for label, session in (("owner", owner_s), ("other editor", other_s), ("stranger", stranger_s)):
    check(f"{label} sees nothing of it", for_me(session) == (set(), set(), set()))
err, text, data = tool(agent, "list_for_me", {"projectID": project})
check("MCP list_for_me of the owner's connection is empty", not err and data["tasks"] == data["questions"] == data["reviews"] == [], text)
designer_agent = oauth_token(designer_s, "projects:read tasks:read")
err, text, data = tool(designer_agent, "list_for_me", {"projectID": project})
check("MCP list_for_me of the designer's connection", not err and [t["id"] for t in data["tasks"]] == [design_card]
      and [q["id"] for q in data["questions"]] == [question["id"]] and [r["id"] for r in data["reviews"]] == [review["id"]]
      and data["currentProject"]["id"] == project, text)
st, listed = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, designer_agent)
check("read-only connection cannot assign or list people",
      not {"set_assignee", "list_assignees"} & {t["name"] for t in listed["result"]["tools"]}, listed)

st, b = http("PUT", f"/v1/reviews/{review['id']}/assignee", {"assigneeID": other}, other_s)
check("another editor cannot take the named review", st == 403 and b["reason"] == "not_the_reviewer", b)
st, b = http("POST", f"/v1/tasks/{open_card}/review/decision", {"decision": "accept"}, other_s)
check("another editor cannot decide it", st == 403 and b["reason"] == "not_the_reviewer", b)
st, b = http("PUT", f"/v1/questions/{question['id']}/assignee", {}, owner_s)
check("an empty body never clears", st == 400 and b["reason"] == "assignee_required", b)

# Unassigned stays what it was: visible to everybody in the lists, in nobody's "for me".
err, text, free = tool(agent, "ask_question", {"taskID": open_card, "prompt": "For anybody?"})
st, b = http("GET", f"/v1/questions?projectID={project}", token=other_s)
check("unassigned question is listed for everybody with access", st == 200 and free["id"] in {q["id"] for q in b}, b)
check("unassigned question is in nobody's for-me", all(free["id"] not in for_me(s)[1] for s in (owner_s, designer_s, other_s)))

# Card E9300901: names for readers, "does it concern me".
st, b = http("PUT", f"/v1/tasks/{design_card}/plan", {"body": "Plan"}, owner_s)
check("plan written", st == 200, b)


def context(card_id, session):
    st, b = http("GET", f"/v1/tasks/{card_id}/context", token=session)
    check("context 200", st == 200, b)
    return b


c = context(open_card, reader_s)
named_q = [q for q in c["questions"] if q["id"] == question["id"]][0]
check("reader sees the name on question and review",
      named_q.get("assigneeName") == "Designer E2E" and c["review"].get("assigneeName") == "Designer E2E", c)
check("reader sees the name on the card", context(design_card, reader_s)["task"].get("assigneeName") == "Designer E2E")
for path in ("/v1/questions", "/v1/reviews"):
    st, b = http("GET", f"{path}?projectID={project}", token=reader_s)
    check(f"reader sees the name in {path}", st == 200 and "Designer E2E" in [x.get("assigneeName") for x in b], b)


def center(session):
    st, b = http("GET", f"/v1/command-center?projectID={project}", token=session)
    check("command center 200", st == 200, b)
    return b


def counts(session):
    s = center(session)["summary"]
    return tuple(s.get(k) for k in ("openQuestions", "pendingReviews", "plansWaiting", "concerningQuestions", "concerningReviews",
                                    "concerningPlans"))


for label, session, expected in (("designer", designer_s, (2, 1, 1, 2, 1, 1)), ("other editor", other_s, (2, 1, 1, 1, 0, 0)),
                                 ("reader", reader_s, (2, 1, 1, 1, 0, 0))):
    got = counts(session)
    check(f"{label} counts", got == expected, got)
cards = [c for lane in center(reader_s)["lanes"] for c in lane["cards"] if c["task"]["id"] == open_card]
check("command center cards name the person for the reader",
      bool(cards) and cards[0]["pendingReview"].get("assigneeName") == "Designer E2E"
      and "Designer E2E" in [q.get("assigneeName") for q in cards[0]["questions"]], cards)


def needs(session):
    st, b = http("GET", f"/v1/feed?projectID={project}", token=session)
    check("feed 200", st == 200, b)
    return {(n["kind"], n.get("questionID") or n.get("reviewID") or n["taskID"]): n for n in b["needsYou"]}


n = needs(other_s)
check("somebody else's question does not concern the other editor",
      n[("question", question["id"])]["concernsMe"] is False and n[("question", question["id"])].get("assigneeName") == "Designer E2E"
      and n[("question", question["id"])].get("assigneeID") == designer, n)
check("the unassigned question concerns everybody", n[("question", free["id"])]["concernsMe"] is True, n)
check("the plan on the designer's card concerns only the designer",
      n[("plan", design_card)]["concernsMe"] is False and needs(designer_s)[("plan", design_card)]["concernsMe"] is True, n)
check("the named review stays with the designer",
      ("review", review["id"]) not in n and needs(designer_s)[("review", review["id"])]["concernsMe"] is True, n)
st, b = http("GET", "/v1/me/push-prefs", token=designer_s)
check("assignment notifications are off by default", st == 200 and b["categories"]["assignments"] is False, b)

st, b = http("DELETE", f"/v1/projects/{project}/grants/{grants[designer]}", token=owner_s)
check("grant revoked", st == 204, b)
check("revoked designer sees nothing", for_me(designer_s) == (set(), set(), set()))
c = context(design_card, reader_s)["task"]
check("a revoked person keeps the id but loses the name", c.get("assigneeID") == designer and "assigneeName" not in c, c)
err, text, _ = tool(agent, "set_assignee", {"questionID": question["id"], "assigneeID": designer})
check("revoked person cannot be assigned again", err and text == "invalid_assignee", text)
err, text, data = tool(designer_agent, "list_for_me", {})
check("the revoked person's connection sees nothing", not err and data["tasks"] == data["questions"] == data["reviews"] == [], text)

st, b = http("POST", f"/v1/questions/{free['id']}/answer", {"answer": "yes"}, owner_s)
check("answering still works", st == 200, b)

print(f"{passed} checks ok, {len(failures)} failed")
sys.exit(1 if failures else 0)
