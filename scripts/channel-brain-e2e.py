#!/usr/bin/env python3
"""End-to-end check of channel #brain (ADR 0030, step 2) against a running backend: REST and MCP, two accounts.

Real HTTP, a real voice attachment (M4A from afconvert/ffmpeg) and a real OAuth token for /mcp (register, authorize, consent, PKCE token).
Usage: channel-brain-e2e.py BASE_URL SESSION_A SESSION_B SPEECH_M4A
"""
import base64, hashlib, json, os, sys, urllib.error, urllib.parse, urllib.request, uuid

base, sess_a, sess_b, m4a_path = sys.argv[1:5]
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)

def http(method, path, body=None, token=None, raw=None, headers=None):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = raw
    if body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with opener.open(req) as r: return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e: return e.code, e.read(), e.headers

def j(b):
    try: return json.loads(b)
    except Exception: return None

M = "/v1/channels/brain/messages"
def post(body, tok=sess_a): st, b, _ = http("POST", M, body, tok); return st, j(b)
def listing(query="", tok=sess_a): st, b, _ = http("GET", M + query, token=tok); return st, j(b)

# Empty channel before any message
st, body = listing()
check("empty channel lists no items", st == 200 and body["items"] == [] and not body.get("nextCursor"), (st, body))
st, _, _ = http("GET", M)
check("anonymous GET 401", st == 401, st)

# Text, idempotency
key = str(uuid.uuid4())
st, first = post({"kind": "text", "text": "Hallo Brain", "clientUUID": key})
check("POST text 201", st == 201 and first["author"] == "person" and first["kind"] == "text", (st, first))
st, again = post({"kind": "text", "text": "Hallo Brain", "clientUUID": key})
check("duplicate client UUID 200 and same id", st == 200 and again["id"] == first["id"], (st, again))
st, _ = post({"kind": "text", "text": "anders", "clientUUID": key})
check("same client UUID, other content 409", st == 409, st)
st, body = listing()
check("list shows exactly one message after duplicate", st == 200 and len(body["items"]) == 1, body)

# Validation
for label, payload, want in (
    ("voice_out via REST 400", {"kind": "voice_out", "text": "x"}, 400),
    ("status via REST 400", {"kind": "status", "text": "x"}, 400),
    ("empty text 400", {"kind": "text", "text": "  "}, 400),
    ("text over 4000 chars 400", {"kind": "text", "text": "a" * 4001}, 400),
    ("voice_in without attachment 400", {"kind": "voice_in"}, 400),
    ("voice_in with unknown attachment 404", {"kind": "voice_in", "attachmentID": str(uuid.uuid4())}, 404),
):
    st, _ = post(payload)
    check(label, st == want, st)

st, b, _ = http("POST", "/v1/projects", {"name": "Brain E2E"}, sess_a); project = j(b)["id"]  # the OAuth grant below needs a project
# Real voice attachment without a task (since T1-3 a voice_in attachment must not belong to a task)
data = open(m4a_path, "rb").read()
st, b, _ = http("POST", "/v1/attachments/begin", {"filename": "memo.m4a", "role": "voice", "mediaType": "audio/mp4",
    "size": len(data), "checksum": hashlib.sha256(data).hexdigest()}, sess_a)
cap = j(b)
check("voice attachment begin 200", st == 200, (st, b))
st, _, _ = http("PUT", cap["uploadURL"], token=cap["token"], raw=data, headers={"Content-Type": "application/octet-stream"})
check("voice attachment PUT 204", st == 204, st)
voice_id = cap["attachmentID"]
st, _ = post({"kind": "voice_in", "attachmentID": voice_id})
check("voice_in with attachment not yet complete 422", st == 422, st)
st, _, _ = http("POST", f"/v1/attachments/{voice_id}/complete", token=sess_a)
check("voice attachment complete 200", st == 200, st)
st, vin = post({"kind": "voice_in", "attachmentID": voice_id, "text": "Transkript", "clientUUID": str(uuid.uuid4())})
check("voice_in 201 with attachment and transcript", st == 201 and vin["attachmentID"].lower() == voice_id.lower() and vin["text"] == "Transkript", (st, vin))
st, _ = post({"kind": "voice_in", "attachmentID": voice_id}, sess_b)
check("foreign account cannot reference the attachment (404)", st == 404, st)

# Other account: empty, own channel, same client UUID allowed
st, body = listing(tok=sess_b)
check("foreign account sees an empty channel", st == 200 and body["items"] == [], body)
st, theirs = post({"kind": "text", "text": "mine", "clientUUID": key}, sess_b)
check("same client UUID in another account is a new message", st == 201 and theirs["id"] != first["id"], (st, theirs))
st, body = listing(tok=sess_a)
check("account A never sees B's message", all(m["text"] != "mine" for m in body["items"]), body)

# Pagination: 3 messages so far in A (text, voice_in, status) plus 6 more
# Since T1-3 a voice_in without a Mac runner also yields an automatic status message.
_, body = listing("?limit=100")
auto = [m["id"] for m in body["items"] if m["kind"] == "status"]
check("voice_in without runner adds one automatic status message", len(auto) == 1, body)
ids = [first["id"], vin["id"]] + auto
for i in range(6):
    st, m = post({"kind": "text", "text": f"p{i}"}); ids.append(m["id"])
seen, cursor, pages = [], None, 0
while True:
    st, body = listing("?limit=3" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else ""))
    seen += [m["id"] for m in body["items"]]; cursor = body.get("nextCursor"); pages += 1
    if not cursor or pages > 10: break
check("pagination: 9 messages over 3 pages, no gaps, no duplicates", pages == 3 and len(seen) == 9 and set(seen) == set(ids), (pages, len(seen)))
check("pagination: newest first", seen[0] == ids[-1] and seen[-1] == ids[0], seen)
for bad in ("limit=0", "limit=101", "cursor=garbage", "since=yesterday"):
    st, _ = listing("?" + bad)
    check(f"bad query {bad} 400", st == 400, st)
st, body = listing("?since=2000-01-01T00:00:00Z&limit=100")
check("since filter returns everything after the date", st == 200 and len(body["items"]) == 9, body)

# MCP with a real OAuth token
def oauth_token(scope):
    st, b, _ = http("POST", "/oauth/register", {"client_name": "Channel E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = j(b)["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    st, b, _ = http("GET", "/.well-known/oauth-protected-resource/mcp")
    resource = j(b)["resource"]  # the audience the server binds grants to
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

old = oauth_token("projects:read tasks:read")
st, body = rpc(old, "tools/list")
names = [t["name"] for t in body["result"]["tools"]]
check("old connection (no channel scopes) does not see the tools", "list_channel_messages" not in names and "post_channel_message" not in names and "list_projects" in names)
err, text, _ = tool(old, "list_channel_messages", {})
check("old connection call is insufficient_scope", err and text == "insufficient_scope", text)

full = oauth_token("projects:read channels:read channels:write")
st, body = rpc(full, "tools/list")
names = [t["name"] for t in body["result"]["tools"]]
check("new connection sees both tools", "list_channel_messages" in names and "post_channel_message" in names)
ckey = str(uuid.uuid4())
err, text, posted = tool(full, "post_channel_message", {"text": "Antwort vom Brain", "clientUUID": ckey})
check("MCP post text as agent", not err and posted["author"] == "agent" and posted["kind"] == "text", text)
err, text, replay = tool(full, "post_channel_message", {"text": "Antwort vom Brain", "clientUUID": ckey})
check("MCP post idempotent", not err and replay["id"] == posted["id"], text)
err, text, _ = tool(full, "post_channel_message", {"kind": "status", "text": "Mac offline"})
check("MCP post status", not err, text)
err, text, _ = tool(full, "post_channel_message", {"kind": "voice_in", "text": "x"})
check("MCP cannot write voice_in", err, text)
err, text, _ = tool(full, "post_channel_message", {"kind": "voice_out", "attachmentID": voice_id})
check("MCP voice_out with own finished voice attachment", not err, text)
err, text, page = tool(full, "list_channel_messages", {"limit": 4})
check("MCP list newest first with cursor", not err and len(page["items"]) == 4 and page["nextCursor"] and page["items"][0]["kind"] == "voice_out", text)
err, text, page2 = tool(full, "list_channel_messages", {"limit": 4, "cursor": page["nextCursor"]})
check("MCP page 2 differs", not err and {m["id"] for m in page["items"]}.isdisjoint({m["id"] for m in page2["items"]}), text)
st, body = listing("?limit=100")
check("REST shows the agent's messages too", any(m["author"] == "agent" for m in body["items"]), body)
st, body = listing(tok=sess_b)
check("account B still sees only its own message", [m["text"] for m in body["items"]] == ["mine"], body)

# createdAt carries milliseconds; two messages in the same second keep their order (REST and MCP)
import re
ms = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
_, m1 = post({"kind": "text", "text": "ms one"})
_, m2 = post({"kind": "text", "text": "ms two"})
check("POST createdAt has milliseconds", ms.match(m1["createdAt"]) and ms.match(m2["createdAt"]), (m1["createdAt"], m2["createdAt"]))
check("two quick messages: second createdAt not before first", m2["createdAt"] >= m1["createdAt"], (m1["createdAt"], m2["createdAt"]))
print("info same second:", m1["createdAt"][:19] == m2["createdAt"][:19], m1["createdAt"], m2["createdAt"])
st, body = listing("?limit=2")
check("REST list: newest first with ms createdAt", [m["id"] for m in body["items"]] == [m2["id"], m1["id"]] and all(ms.match(m["createdAt"]) for m in body["items"]), body)
err, text, page = tool(full, "list_channel_messages", {"limit": 2})
check("MCP list: newest first with ms createdAt", not err and [m["id"] for m in page["items"]] == [m2["id"], m1["id"]] and all(ms.match(m["createdAt"]) for m in page["items"]), text)

print(f"\n{len(failures)} failure(s)" if failures else "\nall ok")
sys.exit(1 if failures else 0)
