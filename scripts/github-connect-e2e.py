#!/usr/bin/env python3
"""End-to-end check of GitHub per person (card E51E8B8C, ADR 0042 addendum) against a running backend and fake-github-hub.py.

Two people, each with an own installation of the one app: connect through the browser redirects, map projects, and prove that
neither sees or uses the other one's installation. With a real SFTP server (E2E_SFTP_PORT, scripts/github-e2e.sh) each of them
also opens a pull request from their own server into their own repository, and revoked rights stop it.
Usage: github-connect-e2e.py BASE_URL SCRATCH   (SCRATCH has config.json, github-journal.jsonl, backend.log, the bare repositories)
"""
import hashlib, json, os, secrets, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

base, scratch = sys.argv[1:3]
config = json.load(open(os.path.join(scratch, "config.json")))
github = config["githubURL"]
SFTP_PORT, SFTP_CONTAINER = os.environ.get("E2E_SFTP_PORT"), os.environ.get("E2E_SFTP_CONTAINER")
SFTP_PASSWORD = "sftp-Geheim-41d9"
failures, transcript = [], []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {str(detail)[:600]}"))
    if not cond: failures.append(name)


def run(*args, cwd=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0: raise SystemExit(f"{args}: {r.stderr}")
    return r.stdout


def sql(statement): return run("sqlite3", "-cmd", ".timeout 5000", os.environ["DB_NAME"], statement).strip()


def account(name):
    user, token = str(uuid.uuid4()).upper(), secrets.token_hex(24)
    now = datetime.now(timezone.utc)
    sql(f"INSERT INTO users (id, display_name, is_admin, created_at) VALUES ('{user}', '{name}', 0, {now.timestamp()});")
    sql(f"INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES ('{str(uuid.uuid4()).upper()}', '{user}', "
        f"'{hashlib.sha256(token.encode()).hexdigest()}', {(now + timedelta(days=1)).timestamp()}, {now.timestamp()});")
    return user, token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


opener = urllib.request.build_opener(NoRedirect)


def raw(method, url, body=None, headers=None):
    data = None
    h = dict(headers or {})
    if body is not None: data, h["Content-Type"] = json.dumps(body).encode(), "application/json"
    try:
        with opener.open(urllib.request.Request(url, method=method, data=data, headers=h), timeout=120) as r: return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e: return e.code, e.read(), e.headers


def http(method, path, body=None, token=None):
    status, out, _ = raw(method, base + path, body, {"Authorization": f"Bearer {token}"} if token else None)
    transcript.append(out.decode(errors="replace"))
    try: return status, json.loads(out)
    except Exception: return status, out


def query(url): return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))


def browser(url, login, kind):
    """What the person's browser does on "GitHub": open the page, pick the own account, follow the redirect back to Todolino."""
    status, page, _ = raw("GET", url)
    check(f"{login}: GitHub shows the {kind} page", status == 200 and f"Als {login} ".encode() in page, (status, url))
    state = query(url)["state"]
    step = "install" if kind == "installation" else "authorize"
    status, _, headers = raw("GET", f"{github}/fake/{step}?" + urllib.parse.urlencode({"user": login, "state": state}))
    back = headers.get("Location", "")
    check(f"{login}: back to the callback of Todolino", status == 302 and back.startswith(config["callback"] + "?"), (status, back))
    return query(back)


def admin(body):
    status, out, _ = raw("POST", github + "/fake/admin", body)
    assert status == 200, out


def journal():
    path = os.path.join(scratch, "github-journal.jsonl")
    return [json.loads(l) for l in open(path)] if os.path.exists(path) else []


def refs(repo):
    text = run("git", "--git-dir", config["repositories"][repo]["bare"], "for-each-ref", "--format=%(objectname) %(refname)")
    return {name: sha for sha, name in (l.split(" ", 1) for l in text.split("\n") if l)}


class Person:
    def __init__(self, login, name):
        self.login, self.repo = login, f"{login}/site"
        self.id, self.session = account(name)
        st, p = http("POST", "/v1/projects", {"name": f"Projekt {name}"}, self.session); self.project = p["id"]
        # The own repository: main equals the own server.
        work = os.path.join(scratch, f"work-{login}"); os.makedirs(os.path.join(work, "css"))
        run("git", "init", "-q", "-b", "main", cwd=work)
        for path, text in (("index.php", "hi\n"), ("css/app.css", "a{}\nb{}\n"), ("about.php", "alt\n")):
            open(os.path.join(work, path), "wb").write(text.encode())
        identity = ["-c", "user.name=E2E", "-c", "user.email=e2e@example.invalid", "-c", "core.autocrlf=false"]
        run("git", *identity, "add", "-A", cwd=work); run("git", *identity, "commit", "-q", "-m", "Stand im Repo", cwd=work)
        run("git", "push", "-q", config["repositories"][self.repo]["bare"], "main", cwd=work)
        self.main = refs(self.repo)["refs/heads/main"]
        self.manifest = [{"path": p, "size": len(t), "sha256": hashlib.sha256(t.encode()).hexdigest(), "eol": "lf"}
                         for p, t in (("index.php", "hi\n"), ("css/app.css", "a{}\nb{}\n"), ("about.php", "alt\n"))]


alice, bob = Person("alice", "Alice"), Person("bob", "Bob")

# --- Connect: both through the browser redirects of the app -------------------------------------------------------------------
for p, other in ((alice, bob), (bob, alice)):
    st, o = http("GET", "/v1/github", token=p.session)
    check(f"{p.login}: the operator app is available, nothing connected", st == 200 and o == {"available": True, "connections": []}, o)
    st, start = http("POST", "/v1/github/connect", {"mode": "install"}, p.session)
    check(f"{p.login}: connect leads to the installation page of the app",
          st == 200 and start["url"].startswith(f"{github}/apps/{config['slug']}/installations/new?state="), start)
    back = browser(start["url"], p.login, "installation")
    st, r = http("POST", "/v1/github/setup", {"state": back["state"], "installationID": back["installation_id"], "code": back["code"]}, other.session)
    check(f"{other.login}: cannot finish {p.login}'s connection", st == 400 and r["reason"] == "github_state_invalid", (st, r))
    st, r = http("POST", "/v1/github/setup", {"state": back["state"], "installationID": back["installation_id"], "code": back["code"]}, p.session)
    check(f"{p.login}: connected", st == 200 and [c["accountLogin"] for c in r["connections"]] == [p.login], (st, r))
    p.connection = r["connections"][0]["id"]
    st, r = http("POST", "/v1/github/setup", {"state": back["state"], "installationID": back["installation_id"], "code": back["code"]}, p.session)
    check(f"{p.login}: the state works once", st == 400 and r["reason"] == "github_state_invalid", (st, r))

# A forged installation id: bob names alice's installation after authorising as himself.
st, start = http("POST", "/v1/github/connect", {"mode": "install"}, bob.session)
back = browser(start["url"], "bob", "installation")
st, r = http("POST", "/v1/github/setup", {"state": back["state"], "installationID": "111", "code": back["code"]}, bob.session)
check("bob cannot claim alice's installation id", st == 403 and r["reason"] == "github_installation_not_yours", (st, r))
# The second way (setup URL, then authorization) for an existing installation.
st, start = http("POST", "/v1/github/connect", {"mode": "existing"}, alice.session)
back = browser(start["url"], "alice", "authorization")
st, r = http("POST", "/v1/github/callback", {"state": back["state"], "code": back["code"]}, alice.session)
check("alice takes over the existing installation: still one connection", st == 200 and len(r["connections"]) == 1, (st, r))

# --- Seeing and using ---------------------------------------------------------------------------------------------------------
for p, other in ((alice, bob), (bob, alice)):
    st, o = http("GET", "/v1/github", token=p.session)
    check(f"{p.login}: sees only the own connection", [c["id"] for c in o["connections"]] == [p.connection], o)
    st, r = http("GET", f"/v1/github/connections/{p.connection}/repositories", token=p.session)
    check(f"{p.login}: sees only own repositories", r["ok"] is True and [i["repository"] for i in r["items"]] == [p.repo], r)
    for method, path in (("GET", f"/v1/github/connections/{other.connection}/repositories"), ("DELETE", f"/v1/github/connections/{other.connection}"),
                         ("GET", f"/v1/projects/{other.project}/github-repositories")):
        st, r = http(method, path, {} if method == "DELETE" else None, p.session)
        check(f"{p.login}: {method} of {other.login}'s {path.split('/')[2]} is 404", st == 404, (st, r))
    st, r = http("POST", f"/v1/projects/{p.project}/github-repositories", {"connectionID": other.connection, "repository": other.repo}, p.session)
    check(f"{p.login}: cannot map through {other.login}'s connection", st == 404, (st, r))
    st, r = http("POST", f"/v1/projects/{p.project}/github-repositories", {"connectionID": p.connection, "repository": other.repo}, p.session)
    check(f"{p.login}: cannot reach {other.repo} through the own one", st == 403 and r["reason"] == "deploy_github_repository_not_allowed", (st, r))
    st, r = http("POST", f"/v1/projects/{other.project}/github-repositories", {"connectionID": p.connection, "repository": p.repo}, p.session)
    check(f"{p.login}: cannot map into {other.login}'s project", st == 404, (st, r))
for p in (alice, bob):
    st, r = http("POST", f"/v1/projects/{p.project}/github-repositories", {"connectionID": p.connection, "repository": p.repo}, p.session)
    check(f"{p.login}: maps the own repository", st == 201 and r["repository"] == p.repo and r["mine"] is True and r["active"] is True, (st, r))
    st, r = http("GET", f"/v1/projects/{p.project}/github-repositories", token=p.session)
    check(f"{p.login}: the project lists exactly that", [i["repository"] for i in r["items"]] == [p.repo], r)

# --- Pull requests from the own server (needs the SFTP container) --------------------------------------------------------------
if SFTP_PORT:
    def on_server(command): run("docker", "exec", SFTP_CONTAINER, "sh", "-c", command)

    for p in (alice, bob):
        site = f"/home/{p.login}/site"
        st, t = http("POST", f"/v1/projects/{p.project}/deploy-targets",
                     {"name": f"Server {p.login}", "stage": "test", "protocol": "sftp", "host": "127.0.0.1", "port": int(SFTP_PORT),
                      "basePath": "site", "username": p.login, "password": SFTP_PASSWORD}, p.session)
        check(f"{p.login}: create SFTP target", st == 201, (st, t))
        p.target = t["id"]
        st, r = http("POST", f"/v1/deploy-targets/{p.target}/test", token=p.session)
        st, r = http("POST", f"/v1/deploy-targets/{p.target}/host-key", {"fingerprint": r["offeredHostKey"]["fingerprint"]}, p.session)
        check(f"{p.login}: confirm host key", st == 200, (st, r))
        on_server(f'printf "vom Server von {p.login}\\r\\n" > {site}/about.php')

    def publish(p, target=None, as_person=None, **extra):
        return http("POST", f"/v1/deploy-targets/{target or p.target}/pull-request",
                    {"files": p.manifest, "baseCommit": p.main, **extra}, (as_person or p).session)

    st, r = publish(alice, as_person=bob)
    check("bob cannot publish alice's target", st == 404, (st, r))
    st, r = publish(bob, repository=alice.repo)
    check("bob cannot name alice's repository", r.get("code") == "deploy_github_repository_not_allowed", r)
    for p, other, installation in ((alice, bob, "111"), (bob, alice, "222")):
        before, count = refs(other.repo), len(journal())
        st, r = publish(p)
        check(f"{p.login}: pull request in the own repository", st == 200 and r.get("ok") is True and r.get("repository") == p.repo, (st, r))
        branch = r.get("branch", "")
        head = refs(p.repo).get("refs/heads/" + branch, "")
        shown = run("git", "--git-dir", config["repositories"][p.repo]["bare"], "show", head + ":about.php") if head else ""
        check(f"{p.login}: the branch holds the own server's change, main untouched",
              shown == f"vom Server von {p.login}\n" and refs(p.repo)["refs/heads/main"] == p.main, (shown, refs(p.repo)))
        used = {e["installation"] for e in journal()[count:] if e["installation"]}
        check(f"{p.login}: only the own installation was used", used == {installation}, used)
        check(f"{p.login}: nothing changed in {other.login}'s repository", refs(other.repo) == before, refs(other.repo))
        p.published = {k for k in refs(p.repo)}

    # --- Revoked on GitHub: checked again on every use, the other person is not affected -----------------------------------------
    def refused(p, code, why):
        st, r = publish(p)
        check(f"{p.login}: {why} -> {code}, nothing written", r.get("ok") is False and r.get("code") == code and set(refs(p.repo)) == p.published, r)

    admin({"permission": [alice.repo, "alice", "read"]})
    refused(alice, "deploy_github_repository_access_lost", "write permission removed")
    admin({"permission": [alice.repo, "alice", "admin"]})
    admin({"suspend": [111, True]})
    refused(alice, "deploy_github_installation_suspended", "installation suspended")
    admin({"suspend": [111, False]})
    admin({"uninstall": 111})
    refused(alice, "deploy_github_installation_removed", "app uninstalled")
    st, r = http("GET", f"/v1/github/connections/{alice.connection}/repositories", token=alice.session)
    check("alice: the connection says it is gone", r["ok"] is False and r["code"] == "deploy_github_installation_removed", r)
    st, r = publish(bob)
    check("bob is not affected", r.get("ok") is True and r.get("repository") == bob.repo, r)
    st, r = http("DELETE", f"/v1/github/connections/{alice.connection}", {}, alice.session)
    check("alice removes the connection", st == 204, (st, r))
    st, r = publish(alice)
    check("alice: afterwards the project writes nowhere", r.get("code") == "deploy_github_repository_not_allowed", r)
else:
    print("note: no SFTP server (E2E_SFTP_PORT), pull requests not covered in this run")
    st, r = http("DELETE", f"/v1/github/connections/{alice.connection}", {}, alice.session)
    check("alice removes the connection and its mapping", st == 204, (st, r))
    st, r = http("GET", f"/v1/projects/{alice.project}/github-repositories", token=alice.session)
    check("alice: no mapping left", r["items"] == [], r)
    st, r = http("GET", f"/v1/projects/{bob.project}/github-repositories", token=bob.session)
    check("bob keeps his", [i["repository"] for i in r["items"]] == [bob.repo], r)

# --- Secrets ----------------------------------------------------------------------------------------------------------------------
key_lines = [l for l in open(os.path.join(scratch, "app.pem")).read().split("\n") if l and not l.startswith("-----")]
log = open(os.path.join(scratch, "backend.log"), errors="replace").read()
database = sql(".dump github_connections github_connect_states github_project_repositories")
check("the database dump holds the connection of bob", "'bob'" in database, database[:300])
for label, haystack in (("answer", "\n".join(transcript).replace("\\/", "/")), ("backend log", log), ("database", database)):
    found = [w[:12] for w in ["PRIVATE KEY", "ghs_E2E", "ghu_E2E", "eyJhbGciOi", config["clientSecret"], SFTP_PASSWORD, *key_lines] if w in haystack]
    check(f"no key, token, secret or password in any {label}", not found, found)
print(f"github connect e2e: {len(failures)} failure(s)")
sys.exit(1 if failures else 0)
