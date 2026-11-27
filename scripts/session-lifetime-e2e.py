#!/usr/bin/env python3
"""End-to-end check that sign-ins no longer end by themselves (card FFF3C6AB, ADR 0040) against a running backend.

Real HTTP, a real OAuth sign-in for /mcp, SQLite or MariaDB (accounts and "time passed" are written with SQL).
Usage: session-lifetime-e2e.py BASE_URL sqlite|mariadb BACKEND_LOG   (environment as set by session-lifetime-e2e.sh)
"""
import base64, concurrent.futures, email.utils, hashlib, json, os, secrets, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

base, db, backend_log = sys.argv[1:4]
failures, raw_tokens = [], []
DAY = 86_400


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {str(detail)[:400]}"))
    if not cond: failures.append(name)


def sql(statement):
    if db == "sqlite":
        cmd = ["sqlite3", "-cmd", ".timeout 5000", os.environ["DB_NAME"], statement]
    else:
        cmd = ["docker", "exec", os.environ["E2E_MARIADB_CONTAINER"], "mariadb", "-uroot", "-p" + os.environ["DB_PASSWORD"], "-N", "-B",
               os.environ["DB_NAME"], "-e", statement]
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode: raise SystemExit(f"sql failed ({done.returncode}): {done.stderr.strip()}")
    return done.stdout.strip()


def digest(raw): return hashlib.sha256(raw.encode()).hexdigest()
def db_uuid(u): return f"'{u.upper()}'" if db == "sqlite" else f"UNHEX('{u.replace('-', '')}')"
def db_time(t): return str(t.timestamp()) if db == "sqlite" else f"'{t.strftime('%Y-%m-%d %H:%M:%S')}'"
def now(): return datetime.now(timezone.utc)


def left(table, column, raw):
    """Seconds until the stored expiry of a session or token."""
    expr = "expires_at" if db == "sqlite" else "UNIX_TIMESTAMP(CONVERT_TZ(expires_at, '+00:00', @@session.time_zone))"
    return float(sql(f"SELECT {expr} FROM {table} WHERE {column} = '{digest(raw)}';")) - now().timestamp()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


opener = urllib.request.build_opener(NoRedirect)


def http(method, path, body=None, token=None, headers=None, with_headers=False):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None: data, h["Content-Type"] = json.dumps(body).encode(), "application/json"
    try:
        with opener.open(urllib.request.Request(base + path, method=method, data=data, headers=h), timeout=60) as r:
            status, out, got = r.status, r.read(), r.headers
    except urllib.error.HTTPError as e: status, out, got = e.code, e.read(), e.headers
    try: out = json.loads(out)
    except Exception: pass
    return (status, out, got) if with_headers else (status, out)


def session(user, lifetime):
    raw = secrets.token_hex(24)
    sql(f"INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ({db_uuid(str(uuid.uuid4()))}, {db_uuid(user)}, "
        f"'{digest(raw)}', {db_time(now() + timedelta(seconds=lifetime))}, {db_time(now())});")
    raw_tokens.append(raw)
    return raw


user = str(uuid.uuid4())
sql(f"INSERT INTO users (id, display_name, is_admin, created_at) VALUES ({db_uuid(user)}, 'Session E2E', 0, {db_time(now())});")
person = session(user, 40 * DAY)
st, p = http("POST", "/v1/projects", {"name": "Sessions E2E"}, person); project = p["id"]
resource = http("GET", "/.well-known/oauth-protected-resource/mcp")[1]["resource"]


def sign_in(name):
    st, b = http("POST", "/oauth/register", {"client_name": name, "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = b["client_id"]
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client, "redirect_uri": "http://127.0.0.1:54321/callback",
                                "scope": "projects:read tasks:read", "state": "s", "resource": resource,
                                "code_challenge": challenge, "code_challenge_method": "S256"})
    st, b = http("GET", "/oauth/authorize?" + q, token=person, headers={"Accept": "application/json"})
    if st != 200: raise SystemExit(f"authorize failed: {st} {b}")
    st, b = http("POST", "/oauth/consent", {"consent_token": b["consent_token"], "approve": True, "project_ids": [project]}, person)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(b["redirect_uri"]).query)["code"][0]
    st, b = http("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client, "resource": resource,
                                          "code": code, "redirect_uri": "http://127.0.0.1:54321/callback", "code_verifier": verifier})
    if st != 200: raise SystemExit(f"token failed: {st} {b}")
    raw_tokens.extend([b["access_token"], b["refresh_token"]])
    return client, b["access_token"], b["refresh_token"]


def refresh(client, raw):
    st, b = http("POST", "/oauth/token", {"grant_type": "refresh_token", "client_id": client, "resource": resource, "refresh_token": raw})
    if st == 200: raw_tokens.extend([b["access_token"], b["refresh_token"]])
    return st, b


def mcp_ok(access):
    st, b = http("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": {"name": "list_projects", "arguments": {}}}, access)
    return st == 200 and not b["result"].get("isError", False) and "Sessions E2E" in b["result"]["content"][0]["text"]


def age_use(raw, seconds):
    sql(f"UPDATE oauth_secrets SET consumed_at = {db_time(now() - timedelta(seconds=seconds))} WHERE hash = '{digest(raw)}';")


def grant_row(client):
    return sql("SELECT revoked, COALESCE(revoked_reason, '-') FROM oauth_grants WHERE client_id = " + db_uuid(client) + ";").replace("|", " ").split()


# The proven expiry (client logs, 26.11. evening): a rotation happens, its result is never stored, and minutes later the
# parallel sessions that share the store all send the previous token.
client, access, stored = sign_in("Claude Code (E2E)")
st, lost = refresh(client, stored)
check("rotation whose answer gets lost", st == 200, lost)
check("refresh token lasts 90 days", abs(left("oauth_secrets", "hash", lost["refresh_token"]) - 90 * DAY) < 600)
age_use(stored, 1089)
with concurrent.futures.ThreadPoolExecutor(8) as pool:
    answers = list(pool.map(lambda _: refresh(client, stored), range(8)))
check("8 parallel sessions with the stored token 18 min later all get tokens", [a[0] for a in answers] == [200] * 8, answers)
check("connection not revoked", grant_row(client) == ["0", "-"], grant_row(client))
check("MCP works with one of the new access tokens", mcp_ok(answers[3][1].get("access_token", "")))
age_use(stored, 10 * DAY)
st, late = refresh(client, stored)
check("still accepted ten days later while no result was ever used", st == 200, late)

# Theft detection stays: once the chain moved on, the old token ends the connection.
st, moved = refresh(client, late.get("refresh_token", ""))
check("the client goes on with a new token", st == 200, moved)
st, b = refresh(client, stored)
check("the old token after that is invalid_grant", st == 400 and b.get("error") == "invalid_grant", (st, b))
check("and revokes the connection as replay", grant_row(client) == ["1", "replay"], grant_row(client))
check("MCP is closed at once", not mcp_ok(moved.get("access_token", "")))

# Ending a connection by hand stays immediate.
client, access, stored = sign_in("Claude Code (E2E, by hand)")
check("second connection works", mcp_ok(access))
st, grants = http("GET", "/oauth/grants", token=person)
listed = grants if isinstance(grants, list) else grants.get("grants", grants.get("items", []))
mine = [g for g in listed if "by hand" in json.dumps(g)]
st, b = http("DELETE", f"/oauth/grants/{mine[0]['id']}", token=person) if mine else (0, grants)
check("person ends the connection", st in (200, 204), (st, b))
check("MCP closed after that", not mcp_ok(access))
st, b = refresh(client, stored)
check("refresh closed after that", st == 400, (st, b))

# PWA and app sessions: use moves the end; the cookie follows; signing out and ending by hand stay immediate.
browser = session(user, 3 * DAY)
st, _, got = http("GET", "/v1/me/sessions", headers={"Cookie": f"todo_session={browser}"}, with_headers=True)
cookie = next((c for c in got.get_all("Set-Cookie") or [] if browser in c), "")
check("a used browser session is renewed to 90 days", st == 200 and abs(left("sessions", "token_hash", browser) - 90 * DAY) < 600, (st, cookie))
expires = next((x.split("=", 1)[1] for x in cookie.split("; ") if x.lower().startswith("expires=")), None)
check("and the cookie follows with the same flags", expires is not None
      and abs((email.utils.parsedate_to_datetime(expires) - now()).total_seconds() - 90 * DAY) < 600
      and "HttpOnly" in cookie and "SameSite=Strict" in cookie, cookie.replace(browser, "…"))
st, _, got = http("GET", "/v1/me/sessions", headers={"Cookie": f"todo_session={browser}"}, with_headers=True)
check("no second renewal on the same day", st == 200 and not got.get_all("Set-Cookie"), st)
app = session(user, 10 * DAY)
st, _ = http("GET", "/v1/me/sessions", token=app)
check("an app (bearer) session is renewed too", st == 200 and abs(left("sessions", "token_hash", app) - 90 * DAY) < 600, st)
ended = session(user, -60)
st, _ = http("GET", "/v1/me/sessions", token=ended)
check("an ended session stays ended", st == 401, st)
st, _ = http("POST", "/v1/me/sessions/revoke-others", {}, app)
check("end all other sessions", st == 204, st)
st, _ = http("GET", "/v1/me/sessions", headers={"Cookie": f"todo_session={browser}"})
check("the ended browser session is closed at once", st == 401, st)

text = open(backend_log, errors="replace").read()
check("log names the replay reason", "oauth.replay_revoked" in text and "successor_used" in text)
check("log counts repeats", "oauth.refresh_repeated" in text)
check("no token value in the backend log", not any(t in text for t in raw_tokens))
print(f"session lifetime e2e ({db}): {len(failures)} failure(s)")
sys.exit(1 if failures else 0)
