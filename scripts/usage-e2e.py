#!/usr/bin/env python3
"""End-to-end check of the cost efficiency server part (ADR 0038) against a running backend and a real database.

Real HTTP, a real OAuth token for /mcp, SQLite or MariaDB (accounts are seeded with SQL, everything else goes through the API).
Usage: usage-e2e.py BASE_URL sqlite|mariadb APP_BINARY   (environment as set by usage-e2e.sh)
"""
import base64, concurrent.futures, hashlib, json, os, secrets, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

base, db, native = sys.argv[1:4]
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {str(detail)[:400]}"))
    if not cond: failures.append(name)


def near(a, b): return isinstance(a, (int, float)) and abs(a - b) < 1e-9


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
    return user, token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


opener = urllib.request.build_opener(NoRedirect)


def http(method, path, body=None, token=None, headers=None, raw=None):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = raw
    if body is not None: data = json.dumps(body).encode()
    if data is not None: h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with opener.open(req) as r: status, out = r.status, r.read()
    except urllib.error.HTTPError as e: status, out = e.code, e.read()
    try: return status, json.loads(out)
    except Exception: return status, out


user_a, sess_a = account("Usage A")
user_b, sess_b = account("Usage B")
today = datetime.now(timezone.utc).date()
day = lambda n: (today - timedelta(days=n)).isoformat()

st, p = http("POST", "/v1/projects", {"name": "Usage E2E"}, sess_a); project = p["id"]
st, p = http("POST", "/v1/projects", {"name": "Outside grant"}, sess_a); other = p["id"]
st, p = http("POST", "/v1/projects", {"name": "Geheim von B"}, sess_b); foreign = p["id"]


def done_card(title, changed=None):
    st, t = http("POST", "/v1/tasks", {"projectID": project, "title": title}, sess_a)
    st, u = http("PATCH", f"/v1/tasks/{t['id']}", {"version": t["version"], "status": "done"}, sess_a)
    check(f"card {title} done", st == 200 and u["status"] == "done", u)
    if changed: sql(f"UPDATE tasks SET updated_at = {db_time(changed)} WHERE id = {db_uuid(t['id'])};")


def row(d, session, model, provider="claude", i=0, o=0, w=0, r=0, **extra):
    return {"day": d, "sessionKey": session, "model": model, "provider": provider, "inputTokens": i, "outputTokens": o,
            "cacheWriteTokens": w, "cacheReadTokens": r, **extra}


# Hand calculation (default prices): opus s1 = 1M*4 + (1.5M*5 + 0.5M*8) + 7M*0.2 + 0.1M*20 = 4 + 11.5 + 1.4 + 2 = 18.9
# sonnet s2 = 0.5M*2 + 4.5M*0.1 + 0.2M*10 = 3.45; codex s3 = unpriced; previous p1 = 5M*4 = 20. Total 22.35.
rows = [
    row(day(2), "thread/s1", "claude-opus-5-5", i=1_000_000, o=100_000, w=2_000_000, r=7_000_000, cacheWrite1hTokens=500_000,
        turns=100, maxContextTokens=150_000, projectID=project, commits=2, cardUpdates=1),
    row(day(1), "thread/s2", "claude-sonnet-5-5-20260101", i=500_000, o=200_000, r=4_500_000, subagent=True, commits=0, cardUpdates=0),
    row(day(1), "thread/s3", "gpt-6-codex", "codex", i=1_000_000, o=100_000, r=1_000_000, turns=10),
    row(day(9), "thread/p1", "claude-opus-5-5", i=5_000_000, turns=50, projectID=project),
]
done_card("one"); done_card("two")
done_card("before", datetime.combine(today - timedelta(days=9), datetime.min.time(), timezone.utc) + timedelta(hours=12))

st, r = http("POST", "/v1/usage", {"rows": rows}, sess_a)
check("first report creates four rows", st == 200 and (r["created"], r["updated"], r["stored"]) == (4, 0, 4) and r["unassigned"] == [], r)
check("report cost is the hand calculation", near(r["costUSD"], 42.35) and r["unpricedModels"] == ["gpt-6-codex"], r)
st, r = http("POST", "/v1/usage", {"rows": rows}, sess_a)
check("second report only updates", st == 200 and (r["created"], r["updated"]) == (0, 4), r)
check("no duplicate rows in the database", sql("SELECT COUNT(*) FROM usage_daily;") == "4")


def summary(token=sess_a):
    st, s = http("GET", "/v1/usage/summary?days=7", token=token)
    check("summary 200", st == 200, s)
    return s


def metric(s, key): return next(m for m in s["metrics"] if m["id"] == key)


s = summary()
check("total and previous total", near(s["totalCostUSD"], 22.35) and near(s["previousCostUSD"], 20) and s["partial"] is True, s)
expected = {"costPerDay": (11.175, "good"), "cacheHitRate": (12.5 / 17, "bad"), "cacheWriteCostShare": (11.5 / 22.35, "medium"),
            "outputShare": (0.4 / 17.4, "info"), "contextPerTurn": (12_000_000 / 110, "medium"), "opusCostShare": (18.9 / 22.35, "info"),
            "costPerDoneCard": (9.45, "good"), "idleCostShare": (3.45 / 22.35, "bad")}
for key, (value, rating) in expected.items():
    m = metric(s, key)
    check(f"metric {key} = {value:.6f} {rating}", near(m.get("value"), value) and m["rating"] == rating, m)
check("previous cost per card", near(metric(s, "costPerDoneCard").get("previous"), 20), metric(s, "costPerDoneCard"))
check("verdict", s["verdict"] == {"rating": "bad", "best": "costPerDay", "worst": "cacheHitRate", "lever": "cacheHitRate"}, s["verdict"])
check("series has 7 days with parts", len(s["series"]) == 7 and near(s["series"][4]["costUSD"], 18.9) and near(s["series"][4]["parts"]["cacheWrite"], 11.5)
      and near(s["series"][5]["costUSD"], 3.45), s["series"])
check("model mix", [m["family"] for m in s["models"]] == ["opus", "sonnet", "codex"] and s["models"][0]["tokens"] == 10_100_000, s["models"])
check("sessions and idle flag", [x["sessionKey"] for x in s["sessions"]] == ["thread/s1", "thread/s2", "thread/s3"]
      and [x["idle"] for x in s["sessions"]] == [False, True, False], s["sessions"])
check("projects", s["projects"][0]["projectName"] == "Usage E2E" and s["projects"][0]["doneCards"] == 2
      and near(s["projects"][0]["costPerDoneCard"], 9.45) and "projectID" not in s["projects"][1], s["projects"])

st, r = http("PUT", "/v1/usage/settings", {"prices": [{"model": "gpt-6-codex", "input": 1, "cacheWrite": 0, "cacheWrite1h": 0, "cacheRead": 0.1, "output": 8}],
             "thresholds": {"cacheHitGoodPercent": 70, "cacheHitMediumPercent": 60, "opusTargetPercent": 80, "idleGoodPercent": 20, "idleBadPercent": 30}}, sess_a)
check("settings saved", st == 200 and len(r["prices"]) == 5 and r["thresholds"]["opusTargetPercent"] == 80, r)
s = summary()
check("prices apply retroactively", near(s["totalCostUSD"], 24.25) and s["unpricedModels"] == [], s["totalCostUSD"])
check("thresholds recalculate", metric(s, "cacheHitRate")["rating"] == "good" and metric(s, "idleCostShare")["rating"] == "good"
      and s["verdict"]["rating"] == "medium", s["verdict"])
st, r = http("PUT", "/v1/usage/settings", {}, sess_a)
check("empty settings restore defaults", st == 200 and len(r["prices"]) == 4 and near(summary()["totalCostUSD"], 22.35), r)

# Replacement, not addition.
changed = dict(rows[1], inputTokens=1_000_000)
st, r = http("POST", "/v1/usage", {"rows": [changed]}, sess_a)
check("changed row replaces", st == 200 and r["updated"] == 1 and near(summary()["totalCostUSD"], 23.35), r)
http("POST", "/v1/usage", {"rows": [rows[1]]}, sess_a)

# Validation, rights, size.
st, r = http("POST", "/v1/usage", {"rows": [rows[0], rows[0]]}, sess_a)
check("duplicate row is 400", st == 400 and r["reason"] == "duplicate_row", r)
st, r = http("POST", "/v1/usage", {"rows": [dict(rows[0], title="x")]}, sess_a)
check("unknown field is 400", st == 400 and r["reason"] == "unknown_field", r)
st, r = http("POST", "/v1/usage", {"rows": [row(day(1), "b1", "claude-opus-5-5", i=1, projectID=foreign),
                                            row(day(1), "b2", "claude-opus-5-5", i=1, projectID=str(uuid.uuid4()))]}, sess_a)
check("foreign and unknown projects are unassigned alike", st == 200 and [u["index"] for u in r["unassigned"]] == [0, 1]
      and set(r["unassigned"][0]) == set(r["unassigned"][1]), r)
check("foreign project name never appears", "Geheim" not in json.dumps(summary()))
check("other account sees nothing", summary(sess_b)["hasAnyData"] is False)
st, r = http("POST", "/v1/usage", {"rows": [rows[0]]})
check("no session is 401", st == 401, r)
big = [row(day(3), f"{i:0128d}", "m" * 80, i=10**12, o=10**12, w=10**12, r=10**12, repository="github.com/e/" + "r" * 180) for i in range(500)]
st, r = http("POST", "/v1/usage", {"rows": big}, sess_b)
check("500 large rows fit", st == 200 and r["created"] == 500, r)
try:
    st, r = http("POST", "/v1/usage", token=sess_a, raw=b" " * (3 * 1024 * 1024))
except (urllib.error.URLError, ConnectionError) as error:  # the server may close while the client still sends
    st, r = (413 if "Broken pipe" in str(error) or "reset" in str(error).lower() else 0), str(error)
check("oversized body is 413", st == 413, r)

# Parallel identical reports against the real database.
parallel = [row(day(4), f"par{i}", "claude-opus-5-5", i=1000) for i in range(100)]
with concurrent.futures.ThreadPoolExecutor(8) as pool:
    results = list(pool.map(lambda _: http("POST", "/v1/usage", {"rows": parallel}, sess_a), range(16)))
check("16 parallel identical reports all succeed", all(st == 200 for st, _ in results), [x for x in results if x[0] != 200][:1])
check("exactly one of them created the rows", sorted(r.get("created") for _, r in results) == [0] * 15 + [100], [r.get("created") for _, r in results])
check("no duplicates after parallel reports", sql("SELECT COUNT(*) FROM usage_daily WHERE session_key LIKE 'par%';") == "100")


# MCP with a real OAuth token; the grant lists only `project`.
def oauth_token(scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Usage E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = b["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    resource = http("GET", "/.well-known/oauth-protected-resource/mcp")[1]["resource"]
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client, "redirect_uri": "http://127.0.0.1:54321/callback", "scope": scope,
                                "state": "s", "resource": resource, "code_challenge": challenge, "code_challenge_method": "S256"})
    st, b = http("GET", "/oauth/authorize?" + q, token=sess_a, headers={"Accept": "application/json"})
    if st != 200: raise SystemExit(f"authorize failed: {st} {b}")
    st, b = http("POST", "/oauth/consent", {"consent_token": b["consent_token"], "approve": True, "project_ids": [project]}, sess_a)
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


tok = oauth_token("projects:read tasks:read tasks:write")
st, listed = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, tok)
check("report_usage is listed", "report_usage" in [t["name"] for t in listed["result"]["tools"]])
before = int(sql("SELECT COUNT(*) FROM usage_daily;"))
mcp_rows = [row(day(5), "mcp1", "claude-sonnet-5-5", i=1_000_000, projectID=project),
            row(day(5), "mcp2", "claude-sonnet-5-5", i=3_000_000_000, projectID=other)]
err, text, data = tool(tok, "report_usage", {"rows": mcp_rows})
check("MCP report_usage stores, cost 6002", not err and data["created"] == 2 and near(data["costUSD"], 6002), text)
check("MCP assigns only projects in the grant", not err and [u["index"] for u in data["unassigned"]] == [1], text)
total = summary()["totalCostUSD"]
err, text, data = tool(tok, "report_usage", {"rows": mcp_rows})
check("MCP repeat updates only", not err and (data["created"], data["updated"]) == (0, 2), text)
check("no double counting after MCP repeat", near(summary()["totalCostUSD"], total) and int(sql("SELECT COUNT(*) FROM usage_daily;")) == before + 2)
st, r = http("POST", "/v1/usage", {"rows": [mcp_rows[0]]}, sess_a)
check("REST and MCP share the key", st == 200 and r["updated"] == 1, r)
err, text, _ = tool(oauth_token("projects:read tasks:read"), "report_usage", {"rows": mcp_rows})
check("MCP without tasks:write refused", err and text == "insufficient_scope", text)

st, export = http("GET", "/v1/me/export", token=sess_a)
check("export contains usage", st == 200 and len(export["usage"]) == int(sql(f"SELECT COUNT(*) FROM usage_daily WHERE user_id = {db_uuid(user_a)};")), st)
st, _ = http("PUT", "/v1/usage/settings", {"thresholds": {"idleBadPercent": 30}}, sess_a)
subprocess.run([native, "delete-account", user_a, "--yes"], check=True, capture_output=True)
check("account deletion removes rows and settings",
      sql("SELECT COUNT(*) FROM usage_daily;") == "500" and sql("SELECT COUNT(*) FROM usage_settings;") == "0")

if failures:
    print(f"\n{len(failures)} check(s) failed"); sys.exit(1)
print("\nall checks passed")
