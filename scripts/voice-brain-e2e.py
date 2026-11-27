#!/usr/bin/env python3
"""End-to-end check of the brain answer logic for spoken requests (ADR 0030, step 5) against a running backend.

Real HTTP only: a person (session), a simulated Mac runner (real paired device token), a real M4A recording and, for reading
the channel as the brain session, a real OAuth token for /mcp (list_channel_messages). Two accounts: the status answer of
account A must not leak anything to B.
Usage: voice-brain-e2e.py BASE_URL SESSION_A SESSION_B SPEECH_M4A
"""
import base64, hashlib, json, sys, urllib.error, urllib.parse, urllib.request

base, sess_a, sess_b, m4a_path = sys.argv[1:5]
audio = open(m4a_path, "rb").read()
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
        with opener.open(req) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def j(b):
    try: return json.loads(b)
    except Exception: return None

M = "/v1/channels/brain/messages"

def pair(session, label):
    st, b = http("POST", "/v1/agents/devices", {"label": label}, session)
    d = j(b); st2, b2 = http("POST", "/v1/runner/pair", {"code": d["code"]})
    return j(b2)["token"]

def upload_memo(session):
    body = {"filename": "memo.m4a", "role": "voice", "mediaType": "audio/mp4", "size": len(audio), "checksum": hashlib.sha256(audio).hexdigest()}
    st, b = http("POST", "/v1/attachments/begin", body, session)
    cap = j(b)
    st, _ = http("PUT", cap["uploadURL"], token=cap["token"], raw=audio, headers={"Content-Type": "application/octet-stream"})
    assert st == 204, st
    st, _ = http("POST", f"/v1/attachments/{cap['attachmentID']}/complete", token=session)
    assert st == 200, st
    return cap["attachmentID"]

def messages(session):
    st, b = http("GET", M + "?limit=100", token=session)
    return list(reversed(j(b)["items"])) if st == 200 else []

runner = pair(sess_a, "Mac E2E")
st, _ = http("POST", "/v1/runner/voice/heartbeat", {"capabilities": ["sprache"]}, runner)
check("runner reports the capability", st == 200, st)

# Board of account A: one open question, one review request, one running task; account B has a task of its own.
st, b = http("POST", "/v1/projects", {"name": "Garten"}, sess_a); project = j(b)["id"]
st, b = http("POST", "/v1/tasks", {"projectID": project, "title": "Beet anlegen"}, sess_a); t1 = j(b)["id"]
st, b = http("POST", "/v1/tasks", {"projectID": project, "title": "Zaun streichen"}, sess_a); t2 = j(b)["id"]
st, _ = http("POST", f"/v1/tasks/{t1}/questions", {"prompt": "Tomaten oder Gurken zuerst?", "options": ["Tomaten", "Gurken"], "blocking": True}, sess_a)
check("question created", st in (200, 201), st)
st, _ = http("POST", f"/v1/tasks/{t2}/review", {"summary": "Zaun ist gestrichen"}, sess_a)
check("review requested", st in (200, 201), st)
st, b = http("POST", "/v1/projects", {"name": "Geheim B"}, sess_b); pb = j(b)["id"]
st, b = http("POST", "/v1/tasks", {"projectID": pb, "title": "Nur fuer B"}, sess_b); tb = j(b)["id"]
http("POST", f"/v1/tasks/{tb}/questions", {"prompt": "Frage nur fuer B?"}, sess_b)

def say_and_claim():
    memo = upload_memo(sess_a)
    st, b = http("POST", M, {"kind": "voice_in", "attachmentID": memo}, sess_a)
    check("voice_in accepted", st == 201, (st, b[:200]))
    st, b = http("POST", "/v1/runner/voice/claim", token=runner)
    job = j(b)
    check("runner claims the job", st == 200 and job and job["generation"] >= 1, (st, b[:200]))
    return job["id"], job["generation"]

def transcript(job, gen, text):
    st, b = http("POST", f"/v1/runner/voice/jobs/{job}/transcript", {"generation": gen, "transcript": text}, runner)
    return st, j(b)

def finish(job, gen, text):
    st, b = http("POST", f"/v1/runner/voice/jobs/{job}/result", {"generation": gen, "transcript": text}, runner)
    return st, j(b)

# 1) Status request
job, gen = say_and_claim()
st, body = transcript(job, gen, "Wie steht es?")
check("status request is classified", st == 200 and body["intent"] == "status", (st, body))
text = body["replyText"]
check("status answer names the open question, the review and the task", all(p in text for p in
      ("1 offene Frage", "Tomaten oder Gurken zuerst?", "Beet anlegen", "1 Review", "Zaun ist gestrichen")), text)
check("status answer at most 4000 characters", len(text) <= 4000, len(text))
check("status answer has nothing of account B", "Geheim B" not in text and "Nur fuer B" not in text and "Frage nur fuer B" not in text, text)
st, _ = finish(job, gen, "Wie steht es?")
check("result without reply text writes the server answer", st == 200, st)
msgs = messages(sess_a)
check("channel: voice_in with transcript, then the status answer", [m["kind"] for m in msgs] == ["voice_in", "text"]
      and msgs[0]["text"] == "Wie steht es?" and msgs[1]["author"] == "agent" and "Tomaten oder Gurken zuerst?" in msgs[1]["text"], msgs)

# 2) Class C: nothing happens
job, gen = say_and_claim()
st, body = transcript(job, gen, "Lösche Projekt Garten")
check("delete request is refused", st == 200 and body["intent"] == "refused" and "App" in body["replyText"], (st, body))
finish(job, gen, "Lösche Projekt Garten")
st, b = http("GET", "/v1/projects", token=sess_a)
check("the project still exists", any(p["id"] == project for p in (j(b) if isinstance(j(b), list) else j(b).get("items", []))), b[:200])
st, b = http("GET", f"/v1/tasks/{t1}", token=sess_a)
st, b = http("GET", "/v1/command-center", token=sess_a)
check("both tasks still count", j(b)["summary"]["openQuestions"] == 1, b[:200])
st, b = http("GET", "/v1/action-requests?state=pending", token=sess_a)
pending = j(b) if st == 200 else []
check("at most one pending confirmation request, nothing executed", st in (200, 404) and (len(pending) <= 1 if isinstance(pending, list) else True), (st, b[:200]))

# 3) Everything else waits for the brain session
job, gen = say_and_claim()
st, body = transcript(job, gen, "Plane morgen den Einkauf für das Beet")
check("other request is forwarded", st == 200 and body["intent"] == "forwarded" and body["replyText"], (st, body))
finish(job, gen, "Plane morgen den Einkauf für das Beet")

# 4) The brain session reads the requests over MCP with a real OAuth token
def oauth_token(scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Voice Brain E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
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

tok = oauth_token("projects:read channels:read")
err, text, page = tool(tok, "list_channel_messages", {"limit": 100})
items = list(reversed(page["items"])) if not err else []
voice_in = [m["text"] for m in items if m["kind"] == "voice_in"]
check("MCP list_channel_messages shows the transcripts of all three requests", voice_in ==
      ["Wie steht es?", "Lösche Projekt Garten", "Plane morgen den Einkauf für das Beet"], (err, text[:300]))
check("MCP shows the answers (status, refusal, receipt) as agent text", [m["kind"] for m in items] == ["voice_in", "text"] * 3
      and all(m["author"] == "agent" for m in items if m["kind"] == "text"), [(m["kind"], m["author"]) for m in items])
check("no confirmation request or deletion came from speech", "gelöscht" not in " ".join(m["text"] or "" for m in items), text[:200])

# 5) Account B sees only its own channel (empty) and its own board in a status answer
check("account B has no messages", messages(sess_b) == [])

print(f"\n{len(failures)} failure(s)" if failures else "\nall ok")
sys.exit(1 if failures else 0)
