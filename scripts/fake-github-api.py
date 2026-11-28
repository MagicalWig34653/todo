#!/usr/bin/env python3
"""A stand-in for the GitHub REST API, backed by a real bare git repository (card 354ADE12, ADR 0042). Tests only.

Implements just what the write path of Todolino uses, verifies the app's RS256 JWT with openssl and journals every request
(JSON lines: method, path, ref). It deliberately does NOT restrict which branch may be written: the backend has to do that,
and the test reads the journal and the repository to prove it.

Usage: fake-github-api.py PORT BARE_REPO PUBLIC_KEY.pem JOURNAL APP_ID INSTALLATION_ID OWNER/REPO
scripts/fake-github-hub.py (several users and installations) imports the git part (`git_route`, `valid_jwt`).
"""
import base64, json, os, subprocess, sys, tempfile, time
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "ghs_E2EINSTALLATIONTOKENgeheim0123456789"


def git(bare, *args, data=None, env=None, check=True):
    e = dict(os.environ, GIT_AUTHOR_NAME="App", GIT_AUTHOR_EMAIL="app@example.invalid", GIT_COMMITTER_NAME="App",
             GIT_COMMITTER_EMAIL="app@example.invalid", **(env or {}))
    r = subprocess.run(["git", "--git-dir", bare, *args], input=data, capture_output=True, env=e)
    if check and r.returncode != 0: raise ValueError(r.stderr.decode(errors="replace"))
    return r


def out(bare, *args, **kw): return git(bare, *args, **kw).stdout.decode().strip()


def unb64(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def valid_jwt(jwt, public_key, app_id):
    try:
        head, payload, signature = jwt.split(".")
        claims = json.loads(unb64(payload))
        with tempfile.NamedTemporaryFile() as sig:
            sig.write(unb64(signature)); sig.flush()
            ok = subprocess.run(["openssl", "dgst", "-sha256", "-verify", public_key, "-signature", sig.name],
                                input=f"{head}.{payload}".encode(), capture_output=True).returncode == 0
        now = time.time()
        return (ok and json.loads(unb64(head))["alg"] == "RS256" and str(claims["iss"]) == app_id
                and claims["iat"] <= now + 5 < claims["exp"] + 5 and claims["exp"] - claims["iat"] <= 600)
    except Exception:
        return False


def git_route(bare, repository, pulls, method, rest, body):
    """The git part of the API for one bare repository: (status, answer). Raises ValueError for requests git refuses."""
    if method == "GET" and rest == "": return 200, {"default_branch": "main", "private": True}
    if method == "GET" and rest.startswith("/compare/"):
        base, head = rest[len("/compare/"):].split("...")
        if git(bare, "cat-file", "-e", base + "^{commit}", check=False).returncode != 0: return 404, {"message": "Not Found"}
        head_sha = out(bare, "rev-parse", head)
        status = "identical" if base == head_sha else "ahead" if git(bare, "merge-base", "--is-ancestor", base, head_sha, check=False).returncode == 0 else "diverged"
        return 200, {"status": status}
    if method == "GET" and rest.startswith("/git/commits/"):
        return 200, {"tree": {"sha": out(bare, "rev-parse", rest.rsplit("/", 1)[1] + "^{tree}")}}
    if method == "GET" and rest.startswith("/git/trees/"):
        entries = []
        for line in git(bare, "ls-tree", "-z", rest.rsplit("/", 1)[1]).stdout.decode().split("\0"):
            if not line: continue
            meta, name = line.split("\t", 1); mode, kind, sha = meta.split()
            entries.append({"path": name, "mode": mode, "type": kind, "sha": sha})
        return 200, {"tree": entries, "truncated": False}
    if method == "POST" and rest == "/git/blobs":
        if body.get("encoding") != "base64": raise ValueError("encoding")
        return 201, {"sha": out(bare, "hash-object", "-w", "--stdin", data=base64.b64decode(body["content"], validate=True))}
    if method == "POST" and rest == "/git/trees":
        with tempfile.TemporaryDirectory() as d:
            env = {"GIT_INDEX_FILE": os.path.join(d, "index")}
            git(bare, "read-tree", body["base_tree"], env=env)
            for e in body["tree"]:
                sha = e.get("sha") or out(bare, "hash-object", "-w", "--stdin", data=e["content"].encode())
                # --index-info needs no work tree (bare repository).
                git(bare, "update-index", "--index-info", data=f"{e['mode']} {sha}\t{e['path']}\n".encode(), env=env)
            return 201, {"sha": out(bare, "write-tree", env=env)}
    if method == "POST" and rest == "/git/commits":
        args = ["commit-tree", body["tree"]]
        for p in body["parents"]: args += ["-p", p]
        return 201, {"sha": out(bare, *args, data=body["message"].encode())}
    if method == "POST" and rest == "/git/refs":
        ref, sha = body["ref"], body["sha"]
        if not ref.startswith("refs/") or git(bare, "check-ref-format", ref, check=False).returncode != 0: raise ValueError("Reference name is invalid")
        if git(bare, "rev-parse", "--verify", "-q", ref, check=False).returncode == 0: return 422, {"message": "Reference already exists"}
        git(bare, "update-ref", ref, sha)
        return 201, {"ref": ref}
    if method == "POST" and rest == "/pulls":
        git(bare, "rev-parse", "--verify", "-q", "refs/heads/" + body["head"])
        pulls.append(body)
        return 201, {"number": len(pulls), "html_url": f"https://github.example/{repository}/pull/{len(pulls)}"}
    return 404, {"message": "Not Found"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def handle_request(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        path = self.path.split("?")[0]
        with open(journal, "a") as f:
            f.write(json.dumps({"method": self.command, "path": path, "ref": body.get("ref"), "head": body.get("head"), "base": body.get("base"),
                                "title": body.get("title"), "body": body.get("body"), "repositories": body.get("repositories"),
                                "permissions": body.get("permissions"), "agent": self.headers.get("User-Agent")}) + "\n")
        if not self.headers.get("User-Agent"): return self.answer(403, {"message": "User-Agent required"})
        authorization = self.headers.get("Authorization", "")
        if self.command == "POST" and path == f"/app/installations/{installation}/access_tokens":
            if not valid_jwt(authorization.removeprefix("Bearer "), public_key, app_id): return self.answer(401, {"message": "A JSON web token could not be decoded"})
            return self.answer(201, {"token": TOKEN})
        if authorization != f"Bearer {TOKEN}": return self.answer(401, {"message": "Bad credentials"})
        prefix = f"/repos/{repository}"
        if path != prefix and not path.startswith(prefix + "/"): return self.answer(404, {"message": "Not Found"})
        rest = path[len(prefix):]
        try:
            return self.answer(*git_route(bare, repository, pulls, self.command, rest, body))
        except ValueError as e:
            return self.answer(422, {"message": str(e)[:200]})

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_request


if __name__ == "__main__":
    port, bare, public_key, journal, app_id, installation, repository = sys.argv[1:8]
    pulls = []
    HTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
