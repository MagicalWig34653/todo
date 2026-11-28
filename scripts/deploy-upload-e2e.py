#!/usr/bin/env python3
"""End-to-end check of deploy uploads to TEST targets (card 354ADE12, ADR 0044) against a running backend and the real SFTP and
FTPS servers in the test containers: plan, request, approval by a person, drift lock, backup, way back, links out of the base path.
Usage: deploy-upload-e2e.py BASE_URL SCRATCH_DIR BACKEND_LOG   (environment as set by deploy-upload-e2e.sh)
"""
import base64, hashlib, json, os, secrets, sqlite3, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

base, scratch, backend_log = sys.argv[1:4]
CERTS = os.environ["TODO_TEST_DEPLOY_DIR"]
PORTS = {"sftp": int(os.environ["TODO_TEST_DEPLOY_SFTP_PORT"]), "ftps": int(os.environ["TODO_TEST_DEPLOY_FTP_PORT"])}
CONTAINERS = {"sftp": "todo-deploy-test-sftp", "ftps": "todo-deploy-test-ftp"}
PASSWORDS = {"sftp": "sftp-Geheim-41d9", "ftps": "ftp-Geheim-83c2"}
failures, passed, transcript = [], 0, []


def check(name, cond, detail=""):
    global passed
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {str(detail)[:900]}"))
    if cond: passed += 1
    else: failures.append(name)


def sql(statement, args=()):
    with sqlite3.connect(os.environ["DB_NAME"], timeout=10) as db: return db.execute(statement, args).fetchall()


def account(name):
    user, token = str(uuid.uuid4()).upper(), secrets.token_hex(24)
    now = datetime.now(timezone.utc)
    sql("INSERT INTO users (id, display_name, is_admin, created_at) VALUES (?, ?, 0, ?)", (user, name, now.timestamp()))
    sql("INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
        (str(uuid.uuid4()).upper(), user, hashlib.sha256(token.encode()).hexdigest(), (now + timedelta(days=1)).timestamp(), now.timestamp()))
    return user, token


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
        with opener.open(req, timeout=180) as r: status, out = r.status, r.read()
    except urllib.error.HTTPError as e: status, out = e.code, e.read()
    transcript.append(out.decode(errors="replace"))
    try: return status, json.loads(out)
    except Exception: return status, out


def oauth_token(session, project, scope):
    st, b = http("POST", "/oauth/register", {"client_name": "Upload E2E", "redirect_uris": ["http://127.0.0.1:54321/callback"]})
    client = b["client_id"]
    verifier = "b" * 64
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
    if "result" not in b: return True, json.dumps(b), None   # JSON-RPC error, for example an unknown tool
    res = b["result"]; text = res["content"][0]["text"]
    try: parsed = json.loads(text)
    except Exception: parsed = None
    return res.get("isError", False), text, parsed


def server(kind, script):
    return subprocess.run(["docker", "exec", CONTAINERS[kind], "sh", "-c", script], check=True, capture_output=True, text=True).stdout


def snapshot(kind):
    """path -> sha256 of every file and `-> target` of every link below /home/deploy (the base path is /home/deploy/site)."""
    out = server(kind, "cd /home/deploy && find . -path ./.ssh -prune -o -type f -exec sha256sum {} + ; "
                       "find . -path ./.ssh -prune -o -type l -exec sh -c 'for f; do echo \"link:$(readlink \"$f\")  $f\"; done' _ {} +")
    result = {}
    for line in out.splitlines():
        value, path = line.split("  ", 1)
        result[path[2:]] = value
    return result


def sha(data): return hashlib.sha256(data).hexdigest()


def files_of(state, content_for=()):
    """The repo state as manifest; `content_for` = paths whose content is sent along (None = all)."""
    out = []
    for path, text in sorted(state.items()):
        data = text.encode()
        entry = {"path": path, "size": len(data), "sha256": sha(data)}
        if content_for is None or path in content_for: entry["content"] = base64.b64encode(data).decode()
        out.append(entry)
    return out


def reasons(plan, key="files"): return {f["serverPath"]: f["reason"] for f in plan.get(key, [])}


def plan(token, target, state):
    st, r = http("POST", f"/v1/deploy-targets/{target}/plans", {"files": files_of(state, None)}, token)
    check_ok = st == 200 and r.get("ok") is True
    if not check_ok: check("plan accepted", False, (st, r))
    return r.get("plan") or {}


def decide(token, plan_id, override=False):
    http("POST", f"/v1/deploy-plans/{plan_id}/request", {}, token)
    return http("POST", f"/v1/deploy-plans/{plan_id}/approve", {"overrideDrift": override}, token)


owner_id, session = account("Upload E2E")
st, p = http("POST", "/v1/projects", {"name": "Upload E2E"}, session); project = p["id"]
agent = oauth_token(session, project, "projects:read projects:write tasks:read")
agent_texts = []
NEW_NAME = "neu/Ordner mit Leerzeichen/Datei #1 [x] *ü*.txt"

for kind in ("sftp", "ftps"):
    print(f"=== {kind}")
    body = {"name": kind.upper() + " Test", "stage": "test", "protocol": kind, "host": "127.0.0.1", "port": PORTS[kind], "basePath": "site",
            "username": "deploy", "password": PASSWORDS[kind]}
    if kind == "ftps": body["tlsCertificate"] = open(os.path.join(CERTS, "ftp-cert.pem")).read()
    st, t = http("POST", f"/v1/projects/{project}/deploy-targets", body, session)
    check(f"{kind}: create target", st == 201, t)
    target = t["id"]
    if kind == "sftp":
        st, r = http("POST", f"/v1/deploy-targets/{target}/test", token=session)
        st, r = http("POST", f"/v1/deploy-targets/{target}/host-key", {"fingerprint": r["offeredHostKey"]["fingerprint"]}, session)
        check("sftp: host key confirmed", st == 200, r)
    start = snapshot(kind)

    # 1. The agent plans: first without content, then with it. The server already differs: the plan is locked.
    repo = {"index.php": "hi\n", "about.php": "neu aus dem Repo\n", NEW_NAME: "frisch\n", ".env": "SECRET=1\n"}
    err, text, r = tool(agent, "plan_deploy", {"targetID": target, "files": files_of(repo)}); agent_texts.append(text)
    check(f"{kind}: agent learns which content is missing", not err and r["code"] == "deploy_plan_content_missing" and r["missing"] == ["about.php", NEW_NAME], text)
    send = files_of(repo, ["about.php", NEW_NAME])
    err, text, r = tool(agent, "plan_deploy", {"targetID": target, "files": send, "ref": "commit-1"}); agent_texts.append(text)
    first = (r or {}).get("plan", {})
    check(f"{kind}: agent plan locked on the unknown server file", not err and reasons(first) == {"about.php": "drift", NEW_NAME: "new"}
          and reasons(first, "blockers") == {"about.php": "unknown_server_state"} and first["summary"]["unchanged"] == 1, text)
    err, text, r = tool(agent, "request_deploy", {"planID": first["id"], "note": "Karte fertig"}); agent_texts.append(text)
    check(f"{kind}: agent requests the upload", not err and r["state"] == "requested", text)
    st, r = http("POST", f"/v1/deploy-plans/{first['id']}/approve", {"overrideDrift": True}, agent)
    check(f"{kind}: agent token cannot approve", st == 401, (st, r))
    err, text, r = tool(agent, "approve_deploy", {"planID": first["id"]})
    check(f"{kind}: there is no MCP tool that uploads", err, text)
    st, r = http("POST", f"/v1/deploy-plans/{first['id']}/approve", {"overrideDrift": False}, session)
    check(f"{kind}: without override the lock holds", st == 409 and r["reason"] == "deploy_plan_blocked", (st, r))
    check(f"{kind}: nothing written so far", snapshot(kind) == start, set(snapshot(kind).items()) ^ set(start.items()))

    # 2. The person overrides: exactly the planned files change, temporary names are gone.
    st, run = http("POST", f"/v1/deploy-plans/{first['id']}/approve", {"overrideDrift": True}, session)
    after = snapshot(kind)
    expected = dict(start, **{"site/about.php": sha(repo["about.php"].encode()), "site/" + NEW_NAME: sha(repo[NEW_NAME].encode())})
    check(f"{kind}: run succeeded", st == 200 and run["state"] == "succeeded" and run["written"] == ["about.php", NEW_NAME], run)
    check(f"{kind}: server holds exactly the plan (secrets, designer files, links untouched, no temporary files)", after == expected,
          set(after.items()) ^ set(expected.items()))

    # 3. Someone edits on the server: the next plan is locked; a change between request and approval stops the run.
    server(kind, "printf 'DESIGNER-INHALT-77\\n' > /home/deploy/site/about.php")
    repo["about.php"] = "zweite Fassung\n"
    locked = plan(session, target, repo)
    check(f"{kind}: drift locks the plan", reasons(locked, "blockers") == {"about.php": "server_changed"}, locked)
    st, r = decide(session, locked["id"])
    check(f"{kind}: drift cannot be approved without override", st == 409 and r["reason"] == "deploy_plan_blocked", r)
    repo["about.php"] = "DESIGNER-INHALT-77\n"          # pulled into the repo
    repo["index.php"] = "HI\n"                          # same size as before: the rename must still happen
    merged = plan(session, target, repo)
    check(f"{kind}: after the pull nothing is locked", merged["blocked"] is False and reasons(merged) == {"index.php": "changed"}, merged)
    http("POST", f"/v1/deploy-plans/{merged['id']}/request", {}, session)
    server(kind, "printf 'dazwischen\\n' >> /home/deploy/site/index.php")
    before = snapshot(kind)
    st, r = http("POST", f"/v1/deploy-plans/{merged['id']}/approve", {"overrideDrift": True}, session)
    check(f"{kind}: a change after the plan stops the run", st == 200 and r["state"] == "failed" and r["code"] == "deploy_plan_stale", r)
    check(f"{kind}: and nothing was written", snapshot(kind) == before)
    server(kind, "printf 'hi\\n' > /home/deploy/site/index.php")

    # 4. Upload (same size), then the way back: the earlier state returns, new files vanish, others stay.
    repo["neu/zweite.txt"] = "zwei\n"
    before = snapshot(kind)
    upload = plan(session, target, repo)
    st, run = decide(session, upload["id"], override=upload["blocked"])
    check(f"{kind}: second upload succeeded", run["state"] == "succeeded" and run["canRollback"] is True, run)
    check(f"{kind}: same-size file replaced", snapshot(kind)["site/index.php"] == sha(b"HI\n"), snapshot(kind).get("site/index.php"))
    err, text, r = tool(agent, "plan_deploy_rollback", {"planID": run["id"]}); agent_texts.append(text)
    back = (r or {}).get("plan", {})
    check(f"{kind}: rollback plan restores and removes", not err and reasons(back) == {"index.php": "restore", "neu/zweite.txt": "remove"}
          and back["blocked"] is False, text)
    check(f"{kind}: the rollback plan writes nothing", snapshot(kind)["site/index.php"] == sha(b"HI\n"))
    tool(agent, "request_deploy", {"planID": back["id"]})
    st, undone = http("POST", f"/v1/deploy-plans/{back['id']}/approve", {}, session)
    check(f"{kind}: rollback succeeded", st == 200 and undone["state"] == "succeeded", undone)
    check(f"{kind}: server is byte for byte as before the upload", snapshot(kind) == before, set(snapshot(kind).items()) ^ set(before.items()))
    st, r = http("POST", f"/v1/deploy-plans/{run['id']}/rollback", {}, session)
    check(f"{kind}: only the latest run can be undone", st == 409 and r["reason"] == "deploy_rollback_not_latest", r)

    # A directory with non-ASCII characters that exists already (the link check has to walk into it).
    umlaut = {"Über uns/Büro/eins.txt": "eins\n"}
    made = plan(session, target, umlaut)
    st, r = decide(session, made["id"], override=made["blocked"])
    check(f"{kind}: new directory with umlauts", r["state"] == "succeeded" and snapshot(kind).get("site/Über uns/Büro/eins.txt") == sha(b"eins\n"), r)
    umlaut["Über uns/Büro/zwei.txt"] = "zwei\n"
    st, r = http("POST", f"/v1/deploy-targets/{target}/plans", {"files": files_of(umlaut, None)}, session)
    made = r.get("plan") or {}
    st, done = decide(session, made["id"], override=made.get("blocked", False)) if made else (st, r)
    check(f"{kind}: upload into an existing directory with umlauts", done.get("state") == "succeeded"
          and snapshot(kind).get("site/Über uns/Büro/zwei.txt") == sha(b"zwei\n"), (r, done))

    # A base path with umlauts works for the connection test, the plan and the upload.
    server(kind, "mkdir -p '/home/deploy/Größe' && chmod 777 '/home/deploy/Größe' && printf 'a\\n' > '/home/deploy/Größe/da.txt' && chmod 666 '/home/deploy/Größe/da.txt'")
    st, other_target = http("POST", f"/v1/projects/{project}/deploy-targets", dict(body, name=kind + " Umlaut", basePath="Größe"), session)
    uid = other_target["id"]
    if kind == "sftp":
        st, r = http("POST", f"/v1/deploy-targets/{uid}/test", token=session)
        http("POST", f"/v1/deploy-targets/{uid}/host-key", {"fingerprint": r["offeredHostKey"]["fingerprint"]}, session)
    st, r = http("POST", f"/v1/deploy-targets/{uid}/test", token=session)
    check(f"{kind}: connection test with a base path with umlauts", r.get("ok") is True and r.get("files") == 1, r)
    made = plan(session, uid, {"da.txt": "b\n"})
    st, r = decide(session, made["id"], override=True)
    check(f"{kind}: upload below a base path with umlauts", r["state"] == "succeeded" and snapshot(kind).get("Größe/da.txt") == sha(b"b\n"), r)
    server(kind, "rm -rf '/home/deploy/Größe'")

    # 5. Links on the way out of the base path: never written through, not even with override.
    server(kind, "set -e; mkdir -p /home/deploy/away && chmod 777 /home/deploy/away; printf 'aussen\\n' > /home/deploy/away.txt; "
                 "cd /home/deploy/site; ln -sfn ../away assets; ln -sfn ../away.txt file-link.txt; ln -sfn ../nirgends dangling-dir; "
                 "ln -sfn ../nirgends.txt dangling.txt; mkdir -p deep; ln -sfn ../../away deep/inner")
    before = snapshot(kind)
    for victim in ("assets/x.txt", "file-link.txt", "deep/inner/x.txt", "dangling.txt", "dangling-dir/x.txt"):
        st, r = http("POST", f"/v1/deploy-targets/{target}/plans", {"files": files_of({victim: "boese\n"}, None)}, session)
        made = r.get("plan") or {}
        if made:
            st2, done = decide(session, made["id"], override=True)
        else:
            st2, done = None, r
        now = snapshot(kind)
        outside = {k: v for k, v in now.items() if not k.startswith("site/")}
        refused = (reasons(made, "blockers").get(victim) == "symlink" and st2 == 409) if made else r.get("ok") is False
        if victim.startswith("dangling"):
            # Nothing exists behind the link: refusing or failing is fine, writing outside the base path is not.
            refused = refused or (done or {}).get("state") == "failed" or (victim == "dangling.txt" and (done or {}).get("state") == "succeeded")
        check(f"{kind}: no write through link {victim}", refused and outside == {k: v for k, v in before.items() if not k.startswith("site/")},
              (reasons(made, "blockers"), st2, done, set(now.items()) ^ set(before.items())))
        before = now
    server(kind, "cd /home/deploy/site && rm -rf assets file-link.txt dangling-dir dangling.txt deep; rm -rf /home/deploy/away /home/deploy/away.txt")

    # 6. Production is refused.
    st, r = http("PATCH", f"/v1/deploy-targets/{target}", {"stage": "prod"}, session)
    st, r = http("POST", f"/v1/deploy-targets/{target}/plans", {"files": files_of({"x.txt": "x\n"}, None)}, session)
    check(f"{kind}: production is refused", st == 400 and r["reason"] == "deploy_stage_not_supported", (st, r))
    check(f"{kind}: no temporary files left on the server", not any(k.endswith(".todolino.tmp") or k.endswith(".partial") for k in snapshot(kind)), snapshot(kind))

    stranger_id, stranger = account("Stranger " + kind)
    for method, path in (("GET", f"/v1/deploy-plans/{first['id']}"), ("POST", f"/v1/deploy-plans/{first['id']}/rollback"),
                         ("POST", f"/v1/deploy-plans/{upload['id']}/approve"), ("GET", f"/v1/deploy-targets/{target}/plans")):
        st, r = http(method, path, {} if method == "POST" else None, stranger)
        check(f"{kind}: another account gets 404 for {method} {path.split('/')[2]}", st == 404, (st, r))

everything = " ".join(transcript)
log = open(backend_log, errors="replace").read()
with sqlite3.connect(os.environ["DB_NAME"]) as db:
    stored = b"".join(bytes(v) if isinstance(v, bytes) else str(v).encode() for table in ("deploy_plans", "deploy_blobs")
                      for row in db.execute(f"SELECT * FROM {table}") for v in row)
    check("backups are stored", db.execute("SELECT COUNT(*) FROM deploy_blobs WHERE role = 'backup'").fetchone()[0] > 0)
for secret in (*PASSWORDS.values(), "DESIGNER-INHALT-77", "zweite Fassung", "E2E-GEHEIM-ENV"):
    check(f"'{secret}' is in no answer, log line or stored row", secret not in everything and secret not in log and secret.encode() not in stored)
check("agent answers carry no host, user or secret", not any(w in t for t in agent_texts for w in ("127.0.0.1", '"username"', "basePath", *PASSWORDS.values())))
check("backend log has no fatal error", "Fatal error" not in log)

print(f"{passed} ok, {len(failures)} failed")
sys.exit(1 if failures else 0)
