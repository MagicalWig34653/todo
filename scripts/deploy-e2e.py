#!/usr/bin/env python3
"""End-to-end check of deploy targets, phase 1a (ADR 0039) against a running backend, a real database and real SFTP/FTPS servers.

Real HTTP, a real OAuth token for /mcp, SQLite or MariaDB (accounts are seeded with SQL, everything else goes through the API).
Usage: deploy-e2e.py BASE_URL sqlite|mariadb blocked|full SCRATCH   (environment as set by deploy-e2e.sh / test-deploy-servers.sh)
"""
import base64, glob, hashlib, json, os, secrets, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

base, db, mode, scratch = sys.argv[1:5]
failures = []
SFTP_PASSWORD, FTP_PASSWORD = "sftp-Geheim-41d9", "ftp-Geheim-83c2"
SFTP_PORT = int(os.environ.get("TODO_TEST_DEPLOY_SFTP_PORT", "24822"))
FTP_PORT = int(os.environ.get("TODO_TEST_DEPLOY_FTP_PORT", "24821"))
CERTS = os.environ["TODO_TEST_DEPLOY_DIR"]
transcript = []   # every answer of the backend, searched for secrets at the end


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {str(detail)[:600]}"))
    if not cond: failures.append(name)


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
    return token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


opener = urllib.request.build_opener(NoRedirect)


def http(method, path, body=None, token=None, headers=None):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None: data, h["Content-Type"] = json.dumps(body).encode(), "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with opener.open(req, timeout=120) as r: status, out = r.status, r.read()
    except urllib.error.HTTPError as e: status, out = e.code, e.read()
    transcript.append(out.decode(errors="replace"))
    try: return status, json.loads(out)
    except Exception: return status, out


session = account("Deploy A " + mode)
st, p = http("POST", "/v1/projects", {"name": "Deploy E2E " + mode}, session); project = p["id"]


def target(name, protocol, port, password, **extra):
    return {"name": name, "stage": "test", "protocol": protocol, "host": "127.0.0.1", "port": port, "basePath": "site",
            "username": "deploy", "password": password, **extra}


if mode == "blocked":
    st, r = http("POST", f"/v1/projects/{project}/deploy-targets", target("SFTP", "sftp", SFTP_PORT, SFTP_PASSWORD), session)
    check("default server refuses a loopback target", st == 400 and r["reason"] == "deploy_target_blocked", r)
    sys.exit(1 if failures else 0)


def entry(path, text):
    data = text.encode()
    return {"path": path, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


manifest = [entry("index.php", "hi\n"), entry("css/app.css", "a{}\nb{}\n"), entry("about.php", "neu\n"), entry("contact.php", "kontakt\n")]
expected = {"index.php": "same", "css/app.css": "same", "about.php": "changed", "contact.php": "new", "designer.html": "serverOnly"}


def statuses(r): return {f["path"]: f["status"] for f in r.get("files") or []}


def server_state():
    """Names, sizes, times and checksums of everything on both servers: a read-only compare must leave it untouched."""
    cmd = "cd /home/deploy && find . -path './.ssh' -prune -o -printf '%p %s %T@ %y\\n' 2>/dev/null | sort; find . -type f -exec sha256sum {} + | sort"
    alpine = "cd /home/deploy && find . | sort | while read f; do stat -c '%n %s %Y %F' \"$f\"; done; find . -type f -exec sha256sum {} + | sort"
    return (subprocess.run(["docker", "exec", "todo-deploy-test-sftp", "sh", "-c", alpine], check=True, capture_output=True, text=True).stdout,
            subprocess.run(["docker", "exec", "todo-deploy-test-ftp", "sh", "-c", cmd], check=True, capture_output=True, text=True).stdout)


before = server_state()

# --- REST, SFTP ---------------------------------------------------------------------------------------------------------
st, sftp = http("POST", f"/v1/projects/{project}/deploy-targets", target("SFTP", "sftp", SFTP_PORT, SFTP_PASSWORD), session)
check("create SFTP target", st == 201 and sftp["hostKey"]["confirmed"] is False and "password" not in sftp, sftp)
sid = sftp["id"]
st, r = http("POST", f"/v1/deploy-targets/{sid}/test", token=session)
check("test before confirmation does not log in", r["ok"] is False and r["code"] == "deploy_host_key_unconfirmed", r)
fingerprint = r["offeredHostKey"]["fingerprint"]
scan = subprocess.run(["ssh-keyscan", "-p", str(SFTP_PORT), "-t", "ed25519", "127.0.0.1"], capture_output=True, text=True).stdout
own = subprocess.run(["ssh-keygen", "-lf", "-"], input=scan, capture_output=True, text=True).stdout.split()
check("offered fingerprint equals ssh-keygen of the server", len(own) > 1 and own[1] == fingerprint, (own, fingerprint))
st, r = http("POST", f"/v1/deploy-targets/{sid}/host-key", {"fingerprint": "SHA256:wrong"}, session)
check("wrong fingerprint is not pinned", st == 409 and r["reason"] == "deploy_host_key_changed", r)
st, r = http("POST", f"/v1/deploy-targets/{sid}/host-key", {"fingerprint": fingerprint}, session)
check("confirm host key", st == 200 and r["hostKey"]["confirmed"] is True, r)
st, r = http("POST", f"/v1/deploy-targets/{sid}/test", token=session)
check("SFTP connection test", r.get("ok") is True and r.get("files") == 4, r)
st, r = http("POST", f"/v1/deploy-targets/{sid}/compare", {"files": manifest}, session)
check("SFTP compare statuses", r.get("ok") is True and statuses(r) == expected, r)
check("SFTP compare does not show symlinks or what they point to", not any(w in json.dumps(r) for w in ("link.txt", "etclink", "outside", "passwd")), r)

# --- REST, FTPS ---------------------------------------------------------------------------------------------------------
cert = open(os.path.join(CERTS, "ftp-cert.pem")).read()
other = open(os.path.join(CERTS, "other-cert.pem")).read()
st, ftps = http("POST", f"/v1/projects/{project}/deploy-targets", target("FTPS", "ftps", FTP_PORT, FTP_PASSWORD, tlsCertificate=cert), session)
check("create FTPS target", st == 201 and ftps["tlsCertificatePinned"] is True, ftps)
fid = ftps["id"]
st, r = http("POST", f"/v1/deploy-targets/{fid}/compare", {"files": manifest}, session)
statuses_ftps = statuses(r)
check("FTPS compare statuses", r.get("ok") is True and all(statuses_ftps.get(k) == v for k, v in expected.items()), r)

# --- MCP ----------------------------------------------------------------------------------------------------------------


def oauth_token(scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Deploy E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
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


agent = oauth_token("projects:read tasks:read")
agent_texts = []
err, text, r = tool(agent, "list_deploy_targets", {"projectID": project}); agent_texts.append(text)
check("agent lists id, name, stage, protocol only", not err and sorted(r["targets"][0]) == ["hostKeyConfirmed", "id", "name", "protocol", "stage"], text)
for tid, label in ((sid, "SFTP"), (fid, "FTPS")):
    err, text, r = tool(agent, "test_deploy_target", {"targetID": tid}); agent_texts.append(text)
    check(f"agent connection test {label}", not err and r["ok"] is True, text)
    err, text, r = tool(agent, "compare_deploy_target", {"targetID": tid, "files": manifest}); agent_texts.append(text)
    check(f"agent compare {label}", not err and r["ok"] is True and all(statuses(r).get(k) == v for k, v in expected.items()), text)
check("agent answers carry no host, user or secret",
      not any(w in t for t in agent_texts for w in ("127.0.0.1", "deploy\"", SFTP_PASSWORD, FTP_PASSWORD, fingerprint, "BEGIN CERTIFICATE")), agent_texts)
st, r = http("POST", f"/v1/projects/{project}/deploy-targets", target("Agent", "sftp", SFTP_PORT, "x"), agent)
check("agent token cannot create a target", st == 401, (st, r))
st, r = http("PATCH", f"/v1/deploy-targets/{sid}", {"name": "Agent"}, agent)
check("agent token cannot change a target", st == 401, (st, r))
st, r = http("GET", f"/v1/deploy-targets/{sid}", token=agent)
check("agent token cannot read the person view", st == 401, (st, r))

stranger = account("Deploy B")
st, r = http("GET", f"/v1/deploy-targets/{sid}", token=stranger)
check("another account sees 404", st == 404, (st, r))
st, r = http("POST", f"/v1/deploy-targets/{sid}/compare", {"files": manifest}, stranger)
check("another account cannot compare", st == 404, (st, r))

check("servers unchanged after test and compare (read only)", server_state() == before)

# --- Refusals -----------------------------------------------------------------------------------------------------------
st, r = http("PATCH", f"/v1/deploy-targets/{fid}", {"tlsCertificate": other}, session)
st, r = http("POST", f"/v1/deploy-targets/{fid}/test", token=session)
check("wrong FTPS certificate is refused", r.get("code") == "deploy_tls_untrusted", r)
sql(f"UPDATE deploy_targets SET host_key_base64 = 'AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C7okWi4dh2l9GKJl' WHERE id = {db_uuid(sid)};")
st, r = http("POST", f"/v1/deploy-targets/{sid}/compare", {"files": manifest}, session)
check("wrong SFTP host key is refused", r.get("ok") is False and r.get("code") == "deploy_host_key_mismatch" and "files" not in r, r)
st, r = http("PATCH", f"/v1/deploy-targets/{sid}", {"host": "localhost"}, session)
check("a new host needs new credentials", st == 400 and r["reason"] == "deploy_credentials_required", r)
st, r = http("PATCH", f"/v1/deploy-targets/{sid}", {"basePath": "site/../.."}, session)
check("base path cannot leave the cage", st == 400 and r["reason"] == "deploy_base_path_invalid", r)
sql(f"UPDATE deploy_targets SET host = 'localhost' WHERE id = {db_uuid(sid)};")
st, r = http("POST", f"/v1/deploy-targets/{sid}/test", token=session)
check("a secret does not follow an endpoint changed behind its back", r.get("code") == "deploy_secret_unreadable", r)

# --- Secrets ------------------------------------------------------------------------------------------------------------
answers = "\n".join(transcript)
check("no password in any answer", SFTP_PASSWORD not in answers and FTP_PASSWORD not in answers)
log = open(os.path.join(scratch, "backend.log"), errors="replace").read()
check("no password or key in the backend log", SFTP_PASSWORD not in log and FTP_PASSWORD not in log and "PRIVATE KEY" not in log, log[-600:])
stored = sql("SELECT secret_ciphertext, host, username, rules FROM deploy_targets;")
check("database holds only ciphertext", "v1." in stored and SFTP_PASSWORD not in stored and FTP_PASSWORD not in stored)
left = [d for root in {tempfile.gettempdir(), os.environ.get("TMPDIR", "/tmp"),
                       subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip() or "/tmp"}
        for d in glob.glob(os.path.join(root, "todolino-deploy-*"))]
check("no temporary run directory left", left == [], left)
st, r = http("DELETE", f"/v1/deploy-targets/{sid}", token=session)
check("delete target", st == 204, (st, r))

print(f"deploy e2e ({db}): {len(failures)} failure(s)")
sys.exit(1 if failures else 0)
