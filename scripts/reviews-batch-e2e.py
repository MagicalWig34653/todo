#!/usr/bin/env python3
"""End-to-end check of the review bulk decision (POST /v1/reviews/decisions) against a running backend.

Real HTTP, three accounts (owner A, stranger B, read-only collaborator C), 12 reviews, partial results, idempotency, the ceiling of 50,
the rate limit, and the derived brainRecommended field (the agent comment is inserted into the scratch SQLite, as the MCP path would).
Usage: reviews-batch-e2e.py BASE_URL SESSION_A SESSION_B SESSION_C USER_ID_C SQLITE_PATH
"""
import json, subprocess, sys, time, urllib.error, urllib.request, uuid

base, tok_a, tok_b, tok_c, uid_c, db = sys.argv[1:7]
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

def http(method, path, body=None, token=None):
    h = {}
    if token: h["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with urllib.request.urlopen(req) as r: raw, st, hd = r.read(), r.status, r.headers
    except urllib.error.HTTPError as e: raw, st, hd = e.read(), e.code, e.headers
    try: return st, json.loads(raw), hd
    except Exception: return st, None, hd

def batch(ids, decision="accept", note=None, token=tok_a):
    body = {"decisions": [{"reviewID": i} for i in ids], "decision": decision}
    if note is not None: body["note"] = note
    return http("POST", "/v1/reviews/decisions", body, token)

def codes(body): return [r["result"] for r in body["results"]]

st, p, _ = http("POST", "/v1/projects", {"name": "Batch E2E"}, tok_a); project = p["id"]
st, _, _ = http("PUT", f"/v1/projects/{project}/grants", {"principalType": "person", "principalID": uid_c, "role": "read"}, tok_a)
check("read grant for C", st == 200, st)

tasks, reviews = [], []
for n in range(12):
    st, t, _ = http("POST", "/v1/tasks", {"projectID": project, "title": f"Aufgabe {n:02d}"}, tok_a)
    st, r, _ = http("POST", f"/v1/tasks/{t['id']}/review", {"summary": f"Ergebnis {n}"}, tok_a)
    tasks.append(t["id"]); reviews.append(r["id"])
st, pending, _ = http("GET", "/v1/reviews", token=tok_a)
check("12 pending reviews", st == 200 and len(pending) == 12, (st, len(pending or [])))
check("every listed review carries brainRecommended=false", all(r.get("brainRecommended") is False for r in pending), pending[:1])

# Anonymous and invalid requests
st, _, _ = http("POST", "/v1/reviews/decisions", {"decisions": [{"reviewID": reviews[0]}], "decision": "accept"})
check("anonymous 401", st == 401, st)
st, b, _ = batch(reviews[:1], "approve")
check("unknown decision 400 invalid_decision", st == 400 and b.get("reason") == "invalid_decision", (st, b))
st, b, _ = batch([])
check("empty list 400 no_reviews", st == 400 and b.get("reason") == "no_reviews", (st, b))
st, b, _ = batch([str(uuid.uuid4()) for _ in range(51)])
check("51 ids 400 too_many_reviews", st == 400 and b.get("reason") == "too_many_reviews", (st, b))

# Foreign accounts: stranger sees nothing, reader may not decide; nothing changes
st, b, _ = batch(reviews[:3], token=tok_b)
check("stranger: all not_found", st == 200 and codes(b) == ["not_found"] * 3, (st, b))
st, b, _ = batch(reviews[:3], token=tok_c)
check("read-only collaborator: all forbidden", st == 200 and codes(b) == ["forbidden"] * 3, (st, b))
st, still, _ = http("GET", "/v1/reviews", token=tok_a)
check("still 12 pending after the refused attempts", len(still) == 12, len(still))

# Partial result: 4 ok, one already decided, one unknown, one malformed in one call; the ok ones stay decided
st, b, _ = http("POST", f"/v1/tasks/{tasks[4]}/review/decision", {"decision": "accept"}, tok_a)
check("single decision (existing path) 200", st == 200, st)
mixed = reviews[0:4] + [reviews[4], str(uuid.uuid4()), "not-a-uuid"]
st, b, _ = batch(mixed, note="Muendlich freigegeben")
check("partial result codes", st == 200 and codes(b) == ["ok"] * 4 + ["already_decided", "not_found", "invalid"], (st, codes(b) if b else b))
check("summary counts", b["summary"] == {"ok": 4, "forbidden": 0, "notFound": 1, "alreadyDecided": 1, "invalid": 1}, b["summary"])
check("ok entries carry the decided ReviewDTO with the note", all(r["review"]["state"] == "accepted" and r["review"]["decisionNote"] == "Muendlich freigegeben" for r in b["results"][:4]), b["results"][0])
for tid in tasks[0:5]:
    st, t, _ = http("GET", f"/v1/tasks/{tid}/context", token=tok_a)
    check(f"task {tid[:8]} is done", t["task"]["status"] == "done", t["task"]["status"])

# Idempotent repeat: already_decided, no second audit event
def events(kind):
    return int(subprocess.check_output(["sqlite3", db, f"SELECT count(*) FROM activity_events WHERE kind = '{kind}'"]).decode().strip())
accepted_events = events("review.accepted")
check("one review.accepted event per accepted review (5)", accepted_events == 5, accepted_events)
st, b, _ = batch(reviews[0:4], "changes_requested", note="egal")
check("repeat answers already_decided", codes(b) == ["already_decided"] * 4, codes(b))
check("repeat writes no audit event", events("review.accepted") == accepted_events and events("review.changes_requested") == 0, (events("review.accepted"), events("review.changes_requested")))

# changes_requested with a shared note
st, b, _ = batch(reviews[5:8], "changes_requested", note="Bitte nacharbeiten")
check("changes_requested ok x3", codes(b) == ["ok"] * 3, b)
st, t, _ = http("GET", f"/v1/tasks/{tasks[5]}/context", token=tok_a)
check("task back in progress", t["task"]["status"] == "in_progress", t["task"]["status"])
check("3 review.changes_requested events", events("review.changes_requested") == 3, events("review.changes_requested"))

# brainRecommended: an agent comment labelled brain in the chat of the review (inserted like the MCP add_comment path stores it)
rid, tid = reviews[8], tasks[8]
subprocess.check_call(["sqlite3", db,
    f"INSERT INTO comments (id, task_id, author_id, body, version, review_id, author_kind, author_label, created_at) "
    f"VALUES ('{str(uuid.uuid4()).upper()}', '{tid.upper()}', (SELECT user_id FROM sessions LIMIT 1), 'Empfehlung: annehmen', 1, '{rid.upper()}', 'agent', 'brain', {int(time.time())})"])
st, lst, _ = http("GET", "/v1/reviews", token=tok_a)
flags = {r["id"]: r["brainRecommended"] for r in lst}
check("brainRecommended true only for the brain review", flags.get(rid) is True and sum(flags.values()) == 1, flags)
st, only, _ = http("GET", "/v1/reviews?brainRecommended=true", token=tok_a)
check("filter true returns exactly that review", [r["id"] for r in only] == [rid], only)
st, rest, _ = http("GET", "/v1/reviews?brainRecommended=false", token=tok_a)
check("filter false returns the others (3)", len(rest) == 3 and rid not in [r["id"] for r in rest], len(rest))
st, _, _ = http("GET", "/v1/reviews?brainRecommended=maybe", token=tok_a)
check("bad filter value 400", st == 400, st)
st, other, _ = http("GET", "/v1/reviews", token=tok_b)
check("stranger sees no reviews", st == 200 and other == [], other)

# Ceiling: exactly 50 ids go through (all unknown here), then the rate limit
st, b, _ = batch([str(uuid.uuid4()) for _ in range(50)])
check("50 ids accepted", st == 200 and len(b["results"]) == 50, (st, len(b["results"]) if b else b))
limited = None
for _ in range(30):
    st, b, hd = batch([reviews[0]])
    if st == 429: limited = (b, hd); break
check("rate limit reached with 429 review_batch_rate_limited", limited is not None and limited[0].get("reason") == "review_batch_rate_limited", limited)
check("Retry-After header set", limited is not None and limited[1].get("Retry-After") == "600", limited and limited[1].get("Retry-After"))
st, b, _ = batch([reviews[0]], token=tok_b)
check("limit is per account (B unaffected)", st == 200, st)

print(f"\n{'FAILED: ' + ', '.join(failures) if failures else 'all checks passed'}")
sys.exit(1 if failures else 0)
