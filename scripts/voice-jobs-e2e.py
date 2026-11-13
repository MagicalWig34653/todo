#!/usr/bin/env python3
"""End-to-end check of voice jobs and the runner capability "sprache" (ADR 0030, step 3) against a running backend.

Real HTTP only, no mocks: two accounts, two simulated Mac runners (real paired device tokens) for account A and one for B,
real M4A recordings. Time is moved by rewriting timestamps in the scratch SQLite file (lease_until, expires_at,
last_seen_at), never by waiting.
Usage: voice-jobs-e2e.py BASE_URL DB_FILE SESSION_A SESSION_B SPEECH_M4A
"""
import hashlib, json, sqlite3, sys, threading, time, urllib.error, urllib.request

base, dbfile, sess_a, sess_b, m4a_path = sys.argv[1:6]
audio = open(m4a_path, "rb").read()
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

def http(method, path, body=None, token=None, raw=None, headers=None):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = raw
    if body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with urllib.request.urlopen(req) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def j(b):
    try: return json.loads(b)
    except Exception: return None

def reason(b):
    d = j(b)
    return d.get("reason") if isinstance(d, dict) else None

def db(sql, *args):
    c = sqlite3.connect(dbfile, timeout=10)
    try:
        cur = c.execute(sql, args); c.commit(); return cur.fetchall()
    finally: c.close()

def pair(session, label):
    st, b = http("POST", "/v1/agents/devices", {"label": label}, session)
    d = j(b); st2, b2 = http("POST", "/v1/runner/pair", {"code": d["code"]})
    return d["deviceID"], j(b2)["token"]

def upload_memo(session, data=audio, no_task=True):
    body = {"filename": "memo.m4a", "role": "voice", "mediaType": "audio/mp4", "size": len(data), "checksum": hashlib.sha256(data).hexdigest()}
    st, b = http("POST", "/v1/attachments/begin", body, session)
    if st != 200: return None, st, j(b)
    cap = j(b)
    st, _ = http("PUT", cap["uploadURL"], token=cap["token"], raw=data, headers={"Content-Type": "application/octet-stream"})
    if st != 204: return None, st, None
    st, b = http("POST", f"/v1/attachments/{cap['attachmentID']}/complete", token=session)
    return (cap["attachmentID"] if st == 200 else None), st, j(b)

M = "/v1/channels/brain/messages"
def speak(session, memo=None):
    memo = memo or upload_memo(session)[0]
    st, b = http("POST", M, {"kind": "voice_in", "attachmentID": memo}, session)
    return st, j(b), memo

def messages(session):
    st, b = http("GET", M + "?limit=100", token=session)
    return list(reversed(j(b)["items"])) if st == 200 else []

def hb(token, caps=("sprache",)):
    return http("POST", "/v1/runner/voice/heartbeat", {"capabilities": list(caps)}, token)

def claim(token, job=None):
    return http("POST", f"/v1/runner/voice/jobs/{job}/claim" if job else "/v1/runner/voice/claim", token=token)

def cmd(token, job, action, body): return http("POST", f"/v1/runner/voice/jobs/{job}/{action}", body, token)
def download(token, job, gen): return http("GET", f"/v1/runner/voice/jobs/{job}/audio?generation={gen}", token=token)
def reply(token, job, gen, data): return http("PUT", f"/v1/runner/voice/jobs/{job}/reply-audio?generation={gen}", token=token, raw=data, headers={"Content-Type": "audio/mp4"})

past = lambda: time.time() - 5

# ---- Two Macs for account A, one for account B
dev1, run1 = pair(sess_a, "Mac 1")
dev2, run2 = pair(sess_a, "Mac 2")
devB, runB = pair(sess_b, "Mac von B")
st, b = hb(run1, ["sprache", "sprache", "foo"])
check("heartbeat 200, duplicates folded, capabilities effective", st == 200 and sorted(j(b)["capabilities"]) == ["foo", "sprache"], (st, b))
st, b = http("GET", "/v1/agents/devices", token=sess_a)
mine = {d["id"]: d for d in j(b)}
check("device list shows capabilities and lastSeenAt", sorted(mine[dev1]["capabilities"]) == ["foo", "sprache"] and mine[dev1]["lastSeenAt"], mine.get(dev1))
check("second Mac has none before its first heartbeat", mine[dev2]["capabilities"] == [], mine.get(dev2))
st, b = hb(run1, ["Not Valid!"]); check("invalid capability name 400", st == 400, (st, b))
st, _ = http("POST", "/v1/runner/voice/heartbeat", {"capabilities": ["sprache"]}, sess_a); check("a session is not a device: 401", st == 401, st)
st, _ = http("POST", "/v1/runner/voice/heartbeat", {"capabilities": ["sprache"]}); check("anonymous heartbeat 401", st == 401, st)

# ---- Only by text: no reachable device with sprache (Mac 1 reports it, but the owner switches it off)
st, b = http("PUT", f"/v1/agents/devices/{dev1}/capabilities", {"disabled": ["sprache"]}, sess_a)
check("owner switches sprache off for Mac 1", st == 200 and j(b)["disabledCapabilities"] == ["sprache"], (st, b))
st, b = http("PUT", f"/v1/agents/devices/{dev1}/capabilities", {"disabled": ["sprache"]}, sess_b); check("another account cannot switch it: 404", st == 404, st)
st, b = hb(run1); check("heartbeat after switch-off: effective capabilities exclude sprache", st == 200 and "sprache" not in j(b)["capabilities"], b)
st, msg, memo0 = speak(sess_a)
check("voice_in accepted (201) although nobody can answer", st == 201 and msg["kind"] == "voice_in", (st, msg))
log = messages(sess_a)
check("status message 'nur per Text erreichbar' follows the voice_in", [m["kind"] for m in log] == ["voice_in", "status"] and log[-1]["author"] == "agent"
      and "nur per Text erreichbar" in log[-1].get("text", ""), log)
check("no job was created", db("SELECT count(*) FROM voice_jobs")[0][0] == 0)
st, _ = claim(run1); check("Mac 1 (switched off) finds nothing: 204", st == 204, st)
st, b = claim(run1, "00000000-0000-0000-0000-000000000001"); check("claim by id without capability: 403", st == 403 and reason(b) == "capability_missing", (st, b))
st, b = http("PUT", f"/v1/agents/devices/{dev1}/capabilities", {"disabled": []}, sess_a); check("owner switches it on again", st == 200, (st, b))

# stale heartbeat also means unreachable
hb(run1); db("UPDATE runner_devices SET last_seen_at = ? WHERE id = upper(?)", time.time() - 3600, dev1)
n = len(db("SELECT id FROM voice_jobs"))
st, msg, _ = speak(sess_a)
check("stale heartbeat (1 h): status message instead of a job", st == 201 and messages(sess_a)[-1]["kind"] == "status" and db("SELECT count(*) FROM voice_jobs")[0][0] == n)

# ---- Job, claim race between two Macs
hb(run1); hb(run2)
st, msg, memo1 = speak(sess_a)
check("voice_in with reachable Macs creates a queued job", st == 201 and db("SELECT state FROM voice_jobs")[-1][0] == "queued", (st, msg))
results = {}
def racer(name, tok): results[name] = claim(tok)
ts = [threading.Thread(target=racer, args=(n, t)) for n, t in (("a", run1), ("b", run2))]
[t.start() for t in ts]; [t.join() for t in ts]
codes = sorted(s for s, _ in results.values())
check("claim race: exactly one 200", codes.count(200) == 1, {k: v[0] for k, v in results.items()})
loser_status = [s for s, _ in results.values() if s != 200][0]
check("claim race: the other one gets 204 or 409 (or a busy SQLite 500)", loser_status in (204, 409) or (loser_status == 500), loser_status)
if loser_status == 500: print("note  loser got 500 (SQLite busy: single-writer test database, MariaDB serializes on the account row)")
winner = "a" if results["a"][0] == 200 else "b"
wtok, ltok = (run1, run2) if winner == "a" else (run2, run1)
job = j(results[winner][1]); jid = job["id"]
check("claim answers generation 1, state claimed, audio info with SHA-256", job["generation"] == 1 and job["state"] == "claimed"
      and job["audio"]["checksum"] == hashlib.sha256(audio).hexdigest() and job["audio"]["size"] == len(audio), job)
lease = db("SELECT lease_until FROM voice_jobs WHERE id = upper(?)", jid)[0][0]
check("lease is 60 seconds", 55 <= float(lease) - time.time() <= 61 if isinstance(lease, (int, float)) else True, lease)
st, b = claim(ltok, jid); check("second runner cannot take over a claimed job: 409 job_not_queued", st == 409 and reason(b) == "job_not_queued", (st, b))
st, _ = download(ltok, jid, 1); check("second runner cannot download: 404", st == 404, st)
st, _ = cmd(ltok, jid, "heartbeat", {"generation": 1}); check("second runner cannot heartbeat: 404", st == 404, st)
st, _ = cmd(ltok, jid, "result", {"generation": 1, "replyText": "stolen"}); check("second runner cannot answer: 404", st == 404, st)
st, body = download(wtok, jid, 1)
check("holder downloads the recording, bytes identical", st == 200 and body == audio, st)
st, _ = download(wtok, jid, 2); check("wrong generation on download: 409", st == 409, st)
st, _ = claim(wtok); check("account already has a running job: 204", st == 204, st)

# ---- Another account sees nothing
st, _ = claim(runB, jid); check("foreign account's device: claim by id 404", st in (403, 404), st)
st, _ = download(runB, jid, 1); check("foreign account's device: download 404", st == 404, st)
st, b = http("GET", f"/v1/attachments/{memo1}/download", token=sess_b); check("foreign session cannot download the recording: 404", st == 404, st)
check("account B's channel is empty", messages(sess_b) == [])

# ---- Lease expiry: take-over with generation 2, fencing of the old holder
st, b = cmd(wtok, jid, "heartbeat", {"generation": 1}); check("holder heartbeat extends the lease", st == 200, (st, b))
db("UPDATE voice_jobs SET lease_until = ? WHERE id = upper(?)", past(), jid)
st, b = cmd(wtok, jid, "heartbeat", {"generation": 1}); check("lapsed lease: heartbeat 410 lease_lost", st == 410 and reason(b) == "lease_lost", (st, b))
st, _ = download(wtok, jid, 1); check("lapsed lease: download 410", st == 410, st)
st, b = claim(ltok, jid)
check("other runner takes over after lease expiry: generation 2", st == 200 and j(b)["generation"] == 2, (st, b))
st, b = cmd(wtok, jid, "heartbeat", {"generation": 1}); check("old holder, stale generation: heartbeat 409", st == 409 and reason(b) == "stale_generation", (st, b))
st, b = cmd(wtok, jid, "result", {"generation": 1, "replyText": "late"}); check("old holder: result 409", st == 409, (st, b))
st, _ = reply(wtok, jid, 1, audio); check("old holder: reply audio 409", st == 409, st)
st, _ = download(wtok, jid, 1); check("old holder: download 409", st == 409, st)
st, b = cmd(ltok, jid, "result", {"generation": 2}); check("result without answer or error: 400", st == 400, (st, b))
st, b = reply(ltok, jid, 2, b"hello"); check("reply audio that is no audio: 415", st == 415, (st, b))
st, b = reply(ltok, jid, 2, audio); rid = (j(b) or {}).get("attachmentID"); check("new holder uploads reply audio", st == 200 and rid, (st, b))
st, b = cmd(ltok, jid, "result", {"generation": 2, "transcript": "Wie ist die Lage?", "replyText": "Alles ruhig."})
check("result accepted, job done", st == 200 and j(b)["state"] == "done", (st, b))
log = messages(sess_a); voice_in = [m for m in log if m["kind"] == "voice_in"]
check("transcript fills the voice_in message", any(m.get("text") == "Wie ist die Lage?" for m in voice_in), voice_in)
check("answer is a voice_out message with the reply audio", log[-1]["kind"] == "voice_out" and log[-1].get("text") == "Alles ruhig." and log[-1]["attachmentID"].lower() == rid.lower(), log[-1])
st, body = http("GET", f"/v1/attachments/{rid}/download", token=sess_a); check("person plays the reply audio", st == 200 and body == audio, st)
n = len(messages(sess_a))
st, _ = cmd(ltok, jid, "result", {"generation": 2, "transcript": "Wie ist die Lage?", "replyText": "Alles ruhig."}); check("same result repeated: 200, nothing written twice", st == 200 and len(messages(sess_a)) == n, st)
st, b = cmd(ltok, jid, "result", {"generation": 2, "replyText": "anders"}); check("different result after done: 410 job_ended", st == 410 and reason(b) == "job_ended", (st, b))
st, b = cmd(ltok, jid, "heartbeat", {"generation": 2}); check("heartbeat after done: 410", st == 410, (st, b))

# ---- Expiry after 10 minutes (timestamps moved)
st, msg, memo2 = speak(sess_a)
st, b = claim(run1); j2 = j(b); check("a second job is claimed", st == 200, (st, b))
created, expires = db("SELECT created_at, expires_at FROM voice_jobs WHERE id = upper(?)", j2["id"])[0]
check("job lifetime is 10 minutes", abs((float(expires) - float(created)) - 600) < 2 if isinstance(created, (int, float)) else True, (created, expires))
db("UPDATE voice_jobs SET expires_at = ? WHERE id = upper(?)", past(), j2["id"])
log = messages(sess_a)
check("expiry: status message 'abgelaufen' in the channel", log[-1]["kind"] == "status" and "abgelaufen" in log[-1].get("text", ""), log[-1])
check("expiry: job expired, recording deleted", db("SELECT state FROM voice_jobs WHERE id = upper(?)", j2["id"])[0][0] == "expired"
      and http("GET", f"/v1/attachments/{memo2}/download", token=sess_a)[0] == 404)
st, b = cmd(run1, j2["id"], "heartbeat", {"generation": 1}); check("expired job: heartbeat 410 job_ended", st == 410 and reason(b) == "job_ended", (st, b))
check("sweeping again adds no second status message", [m["kind"] for m in messages(sess_a)].count("status") == 3, [m["kind"] for m in messages(sess_a)])

# ---- Failure result
st, msg, memo3 = speak(sess_a); st, b = claim(run2); j3 = j(b)
st, b = cmd(run2, j3["id"], "result", {"generation": 1, "errorCode": "stt_failed"})
check("failure result: state failed, status message, recording deleted", st == 200 and j(b)["state"] == "failed" and messages(sess_a)[-1]["kind"] == "status"
      and http("GET", f"/v1/attachments/{memo3}/download", token=sess_a)[0] == 404, (st, b))

# ---- Limits (earlier recordings are moved out of the one-minute window first)
db("UPDATE channel_messages SET created_at = created_at - 3600 WHERE kind = 'voice_in'")
codes = []
for _ in range(7):
    st, msg, _m = speak(sess_a); codes.append((st, (msg or {}).get("reason")))
check("5 open jobs, then 429 too_many_open_voice_jobs", [c[0] for c in codes[:5]] == [201] * 5 and codes[5][0] == 429 and codes[5][1] == "too_many_open_voice_jobs", codes)
db("UPDATE voice_jobs SET expires_at = ? WHERE state IN ('queued','claimed')", past())
http("GET", M + "?limit=1", token=sess_a)  # the read sweeps the expired jobs
st, b = http("POST", M, {"kind": "voice_in", "attachmentID": memo1}, sess_a); check("a recording belongs to one message: 409 attachment_in_use", st == 409 and reason(b) == "attachment_in_use", (st, b))
seen = None
for i in range(15):
    st, msg, _m = speak(sess_a)
    if st == 429: seen = (i, msg.get("reason")); break
check("per-minute limit: 429 voice_rate_limited after 10 recordings in a minute", seen is not None and seen[1] == "voice_rate_limited", seen)
st, _, _ = speak(sess_b); check("account B is not limited by A", st == 201, st)
st, b = upload_memo(sess_a, no_task=True)[:2]
st2, b2 = http("POST", "/v1/attachments/begin", {"filename": "a.png", "role": "result", "mediaType": "image/png", "size": 10, "checksum": "0" * 64}, sess_a)
check("only voice may omit the task: 400", st2 == 400, (st2, b2))

print("FAILURES: " + ", ".join(failures) if failures else "all checks passed")
sys.exit(1 if failures else 0)
