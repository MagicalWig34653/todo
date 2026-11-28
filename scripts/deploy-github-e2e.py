# Phase 2b of deploy targets (card 354ADE12, ADR 0042): a file changed on a real SFTP server becomes a branch `server/*`, one commit
# and a pull request in a real git repository behind scripts/fake-github-api.py. Not run on its own: deploy-e2e.py executes it in its
# "github" mode (it provides http, check, tool, oauth_token, target, session, project, scratch, ...).
bare = os.path.join(scratch, "github.git")
journal_path = os.path.join(scratch, "github-journal.jsonl")
key_path = os.path.join(scratch, "github-app.pem")
SFTP_CONTAINER = "todo-deploy-test-sftp"


def run(*args, cwd=None, data=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, input=data)
    if r.returncode != 0: raise SystemExit(f"{args}: {r.stderr}")
    return r.stdout


def gh(*args): return run("git", "--git-dir", bare, *args)
def refs(): return dict(reversed(l.split(" ", 1)) for l in gh("for-each-ref", "--format=%(objectname) %(refname)").split("\n") if l)
def journal(): return [json.loads(l) for l in open(journal_path)] if os.path.exists(journal_path) else []
def writes(): return [e for e in journal() if e["method"] != "GET" and not e["path"].endswith("/access_tokens")]
def on_server(command): run("docker", "exec", SFTP_CONTAINER, "sh", "-c", command)
def server_sums(): return run("docker", "exec", SFTP_CONTAINER, "sh", "-c", "cd /home/deploy/site && find . | sort && find . -type f -exec sha256sum {} + | sort")


# The repository on "GitHub": main equals the server, plus an unfinished foreign branch.
work = os.path.join(scratch, "github-work")
os.makedirs(work)
run("git", "init", "-q", "-b", "main", cwd=work)
for name, text in (("index.php", "hi\n"), ("css/app.css", "a{}\nb{}\n"), ("about.php", "alt\n"), ("designer.html", "<p>vom Designer</p>\n")):
    os.makedirs(os.path.dirname(os.path.join(work, name)), exist_ok=True)
    open(os.path.join(work, name), "wb").write(text.encode())
identity = ["-c", "user.name=E2E", "-c", "user.email=e2e@example.invalid", "-c", "core.autocrlf=false"]
run("git", *identity, "add", "-A", cwd=work); run("git", *identity, "commit", "-q", "-m", "Stand im Repo", cwd=work)
run("git", *identity, "switch", "-q", "-c", "feature/designer", cwd=work)
open(os.path.join(work, "wip.txt"), "w").write("unfertig\n")
run("git", *identity, "add", "-A", cwd=work); run("git", *identity, "commit", "-q", "-m", "unfertig", cwd=work)
run("git", "push", "-q", bare, "main", "feature/designer", cwd=work)
main_sha, feature_sha = refs()["refs/heads/main"], refs()["refs/heads/feature/designer"]
manifest = []
for name in gh("ls-tree", "-r", "--name-only", main_sha).split():
    data = subprocess.run(["git", "--git-dir", bare, "show", f"{main_sha}:{name}"], capture_output=True, check=True).stdout
    manifest.append({"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "eol": "lf"})

st, t = http("POST", f"/v1/projects/{project}/deploy-targets", target("Kubus Test", "sftp", SFTP_PORT, SFTP_PASSWORD), session)
check("create SFTP target", st == 201, (st, t))
tid = t["id"]
st, r = http("POST", f"/v1/deploy-targets/{tid}/test", token=session)
st, r = http("POST", f"/v1/deploy-targets/{tid}/host-key", {"fingerprint": r["offeredHostKey"]["fingerprint"]}, session)
check("confirm host key", st == 200, (st, r))


def publish(**extra):
    return http("POST", f"/v1/deploy-targets/{tid}/pull-request", {"files": manifest, "baseCommit": main_sha, **extra}, session)


st, r = publish()
check("server equals the repository: nothing to open, nothing written", st == 200 and r.get("code") == "deploy_pull_nothing" and writes() == []
      and sorted(refs()) == ["refs/heads/feature/designer", "refs/heads/main"], (st, r, writes()))

# The designer changes a file directly on the server and adds one.
on_server('S=/home/deploy/site; printf "a{color:red}\\r\\nb{}\\r\\n" > $S/css/app.css; printf "<p>@lino neu</p>\\r\\n" > "$S/neue seite.html"; chown 1001 "$S/neue seite.html"')
before = server_sums()
st, r = publish()
check("a changed server file opens a pull request", st == 200 and r.get("ok") is True and r.get("pullRequest", {}).get("number") == 1
      and r.get("repository") == "acme/kubus" and r.get("baseBranch") == "main" and r.get("baseCommit") == main_sha, (st, r))
branch = r.get("branch", "")
day = run("date", "+%Y-%m-%d").strip()
check("branch is server/<ziel>-JJJJ-MM-TT", branch.startswith("server/kubus-test-") and branch.endswith(day), (branch, day))
head = refs().get("refs/heads/" + branch, "")
check("the branch holds exactly one commit on top of main", head == r.get("commit") and gh("rev-parse", head + "~1").strip() == main_sha
      and gh("rev-list", "--count", f"{main_sha}..{head}").strip() == "1", (head, refs()))
check("the commit changes exactly the drift files", gh("-c", "core.quotepath=false", "diff", "--name-status", main_sha, head).strip().split("\n")
      == ["M\tcss/app.css", "A\tneue seite.html"], gh("diff", "--name-status", main_sha, head))
check("content is the server content with the line endings of the repo", gh("show", head + ":css/app.css") == "a{color:red}\nb{}\n"
      and gh("show", head + ":neue seite.html") == "<p>@lino neu</p>\n")
message = gh("log", "-1", "--format=%B", head)
check("commit message names target and files", message.startswith("Server-Änderungen von „Kubus Test“ geholt") and "css/app.css" in message, message)
check("main and the foreign branch are untouched", refs()["refs/heads/main"] == main_sha and refs()["refs/heads/feature/designer"] == feature_sha)
pr = [e for e in journal() if e["path"].endswith("/pulls")]
check("pull request: head is the new branch, base is main", len(pr) == 1 and pr[0]["head"] == branch and pr[0]["base"] == "main"
      and "css/app.css" in pr[0]["body"] and ".env" in pr[0]["body"], pr)
tokens = [e for e in journal() if e["path"].endswith("/access_tokens")]
check("token per installation, only this repository, only contents and pull requests",
      tokens and all(e["path"] == "/app/installations/777/access_tokens" and e["repositories"] == ["kubus"]
                     and e["permissions"] == {"contents": "write", "pull_requests": "write"} for e in tokens), tokens)
check("no secret file reached the repository", not any(p in gh("ls-tree", "-r", "--name-only", head).split("\n") for p in (".env", ".git/config", "inc/config.php", "link.txt"))
      and "E2E-GEHEIM" not in gh("log", "-p", head))

# --- Attempts on main or a foreign branch --------------------------------------------------------------------------------
snapshot, count = refs(), len(journal())
for name in ("main", "refs/heads/main", "feature/designer", "feature/x", "server/../main", "server/x/../../feature/designer", "server", "Server/x"):
    st, r = publish(branch=name)
    check(f"branch {name!r} is refused", st == 400 and r.get("reason") == "deploy_branch_forbidden", (st, r))
agent = oauth_token("projects:read projects:write")
err, text, r = tool(agent, "open_server_changes_pr", {"targetID": tid, "files": manifest, "baseCommit": main_sha, "branch": "main"})
check("agent: main is refused", err and "deploy_branch_forbidden" in text, text)
check("refused attempts never reached GitHub, every ref unchanged", len(journal()) == count and refs() == snapshot, journal()[count:])
st, r = publish(repository="acme/other")
check("a repository outside the allowlist is refused", r.get("code") == "deploy_github_repository_not_allowed" and len(journal()) == count, r)
st, r = publish(baseCommit=feature_sha)
check("a base outside main is refused without writing", r.get("code") == "deploy_github_base_unknown" and refs() == snapshot, r)
err, text, r = tool(oauth_token("projects:read tasks:read"), "open_server_changes_pr", {"targetID": tid, "files": manifest, "baseCommit": main_sha})
check("agent without projects:write is refused", err and "scope" in text and refs() == snapshot, text)
stranger = account("Deploy C")
st, r = http("POST", f"/v1/deploy-targets/{tid}/pull-request", {"files": manifest, "baseCommit": main_sha}, stranger)
check("another account sees 404", st == 404 and refs() == snapshot, (st, r))

# --- Agent, existing branch name ------------------------------------------------------------------------------------------
err, text, r = tool(agent, "open_server_changes_pr", {"targetID": tid, "files": manifest, "baseCommit": main_sha})
check("agent opens a second pull request on a new branch", not err and r["ok"] is True and r["branch"] == branch + "-2", text)
check("the first branch was not moved, main unchanged", refs()["refs/heads/" + branch] == head and refs()["refs/heads/main"] == main_sha)
check("agent answer carries no host or user", not any(w in text for w in ("127.0.0.1", "\"deploy\"", SFTP_PASSWORD)), text)

everything = writes()
check("only creating requests, only server/* refs and pull request heads",
      all(e["method"] == "POST" and e["path"].split("/repos/acme/kubus")[1] in ("/git/blobs", "/git/trees", "/git/commits", "/git/refs", "/pulls") for e in everything)
      and all(e["ref"].startswith("refs/heads/server/") for e in everything if e["path"].endswith("/git/refs"))
      and all(e["head"].startswith("server/") for e in everything if e["path"].endswith("/pulls")), everything)
check("every ref outside server/ is as before", {k: v for k, v in refs().items() if not k.startswith("refs/heads/server/")}
      == {"refs/heads/main": main_sha, "refs/heads/feature/designer": feature_sha}, refs())
check("the server was only read", server_sums() == before)

# --- Secrets -------------------------------------------------------------------------------------------------------------
key_lines = [l for l in open(key_path).read().split("\n") if l and not l.startswith("-----")]
log = open(os.path.join(scratch, "backend.log"), errors="replace").read()
for label, haystack in (("answer", "\n".join(transcript).replace("\\/", "/")), ("backend log", log), ("pull request or commit", json.dumps(pr) + message)):
    check(f"no key, token or JWT in any {label}",
          not any(w in haystack for w in ["PRIVATE KEY", "ghs_E2EINSTALLATIONTOKEN", "eyJhbGciOi", SFTP_PASSWORD, *key_lines]), haystack[-600:])
check("the backend logged the pull request", "deploy pull request ok" in log, log[-600:])
st, r = http("DELETE", f"/v1/deploy-targets/{tid}", token=session)
check("delete target", st == 204, (st, r))
print(f"deploy e2e github ({db}): {len(failures)} failure(s)")
