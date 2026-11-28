#!/usr/bin/env python3
"""A stand-in for GitHub with several people, installations and repositories (card E51E8B8C, ADR 0042 addendum). Tests only.

API and web side on one port: the app's installation page and the user authorization (small HTML pages: pick who you are on
"GitHub"), the OAuth code exchange, user and installation calls, installation tokens (limited to the installation and the asked
repositories) and the git calls of the write path over real bare repositories (shared with fake-github-api.py). The app JWT is
verified with openssl. Every request is journalled (JSON lines). `POST /fake/admin` changes GitHub from the test (permission,
suspend, uninstall). It deliberately does not restrict which branch may be written: the backend has to do that.

Usage: fake-github-hub.py PORT CONFIG.json JOURNAL
"""
import html, importlib.util, json, os, secrets, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_spec = importlib.util.spec_from_file_location("fake_github_api", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake-github-api.py"))
api = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(api)

port, config_path, journal = sys.argv[1:4]
config = json.load(open(config_path))
users = config["users"]                                  # login -> id
installations = config["installations"]                  # id -> {account, accountID, type, repositories}
repositories = config["repositories"]                    # owner/name -> {id, private, bare, permissions}
codes, user_tokens, installation_tokens, pulls = {}, {}, {}, {}


def installation_body(key):
    i = installations[key]
    return {"id": int(key), "app_id": int(config["appID"]), "account": {"login": i["account"], "id": i["accountID"], "type": i["type"]},
            "suspended_at": "2026-11-28T00:00:00Z" if i.get("suspended") else None}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, status, data, content_type, extra=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type); self.send_header("Content-Length", str(len(data)))
        for name, value in extra: self.send_header(name, value)
        self.end_headers(); self.wfile.write(data)

    def answer(self, status, body): self.send(status, json.dumps(body).encode(), "application/json")
    def redirect(self, url): self.send(302, b"", "text/plain", [("Location", url)])

    def page(self, title, links):
        items = "".join(f'<p><a href="{html.escape(url)}">{html.escape(label)}</a></p>' for label, url in links)
        self.send(200, f'<!doctype html><meta charset="utf-8"><title>{html.escape(title)}</title><h1>{html.escape(title)}</h1>{items}'.encode(),
                  "text/html; charset=utf-8")

    def web(self, path, query):
        """The pages a person's browser visits on "GitHub"."""
        callback, state = config["callback"], query.get("state", "")
        if path == f"/apps/{config['slug']}/installations/new":
            return self.page("GitHub (nachgestellt): App installieren",
                             [(f"Als {login} installieren", "/fake/install?" + urllib.parse.urlencode({"user": login, "state": state})) for login in users])
        if path == "/login/oauth/authorize":
            if query.get("client_id") != config["clientID"] or query.get("redirect_uri") != callback: return self.answer(404, {"message": "wrong app"})
            return self.page("GitHub (nachgestellt): App autorisieren",
                             [(f"Als {login} autorisieren", "/fake/authorize?" + urllib.parse.urlencode({"user": login, "state": state})) for login in users])
        login = query.get("user", "")
        if login not in users: return self.answer(404, {"message": "unknown user"})
        code = secrets.token_hex(10); codes[code] = login
        back = {"code": code, "state": state}
        if path == "/fake/install":
            own = [k for k, i in installations.items() if i["accountID"] == users[login]]
            if not own: return self.answer(404, {"message": "no account installation"})
            back.update(installation_id=own[0], setup_action="install")
        return self.redirect(callback + "?" + urllib.parse.urlencode(back))

    def handle_request(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        url = urllib.parse.urlsplit(self.path)
        path, query = url.path, dict(urllib.parse.parse_qsl(url.query))
        if self.command == "GET" and (path.startswith("/apps/") or path == "/login/oauth/authorize" or path in ("/fake/install", "/fake/authorize")):
            return self.web(path, query)
        if self.command == "POST" and path == "/fake/admin":
            if "permission" in body:
                repo, login, value = body["permission"]
                repositories[repo]["permissions"].pop(login, None)
                if value: repositories[repo]["permissions"][login] = value
            if "suspend" in body: installations[str(body["suspend"][0])]["suspended"] = body["suspend"][1]
            if "uninstall" in body:
                installations.pop(str(body["uninstall"]), None)
                for t in [t for t, v in installation_tokens.items() if v[0] == str(body["uninstall"])]: del installation_tokens[t]
            return self.answer(200, {})
        bearer = self.headers.get("Authorization", "").removeprefix("Bearer ")
        entry = {"method": self.command, "path": path, "ref": body.get("ref"), "head": body.get("head"),
                 "installation": installation_tokens.get(bearer, (None,))[0]}
        if path.startswith("/app/installations/"): entry["installation"] = path.split("/")[3]
        with open(journal, "a") as f: f.write(json.dumps(entry) + "\n")
        if not self.headers.get("User-Agent"): return self.answer(403, {"message": "User-Agent required"})
        if self.command == "POST" and path == "/login/oauth/access_token":
            login = codes.pop(body.get("code"), None)
            if body.get("client_id") != config["clientID"] or body.get("client_secret") != config["clientSecret"] or not login:
                return self.answer(200, {"error": "bad_verification_code"})
            token = "ghu_E2EUSERTOKEN" + secrets.token_hex(12); user_tokens[token] = login
            return self.answer(200, {"access_token": token, "token_type": "bearer"})
        if path in ("/user", "/user/installations"):
            login = user_tokens.get(bearer)
            if not login: return self.answer(401, {"message": "Bad credentials"})
            if path == "/user": return self.answer(200, {"id": users[login], "login": login})
            visible = [k for k, i in sorted(installations.items())
                       if i["accountID"] == users[login] or any(login in repositories[r]["permissions"] for r in i["repositories"])]
            return self.answer(200, {"total_count": len(visible), "installations": [installation_body(k) for k in visible]})
        if path.startswith("/app/installations/"):
            if not api.valid_jwt(bearer, config["publicKey"], config["appID"]): return self.answer(401, {"message": "A JSON web token could not be decoded"})
            parts = path.strip("/").split("/")
            key = parts[2]
            if key not in installations: return self.answer(404, {"message": "Not Found"})
            if len(parts) == 3 and self.command == "GET": return self.answer(200, installation_body(key))
            if parts[3:] != ["access_tokens"] or self.command != "POST": return self.answer(404, {"message": "Not Found"})
            i = installations[key]
            if i.get("suspended"): return self.answer(403, {"message": "This installation has been suspended"})
            scope = i["repositories"]
            if body.get("repositories") is not None:
                scope = [f"{i['account']}/{name}" for name in body["repositories"]]
                if not all(r in i["repositories"] for r in scope): return self.answer(422, {"message": "not accessible"})
            token = "ghs_E2EINSTALLATIONTOKEN" + secrets.token_hex(12)
            installation_tokens[token] = (key, scope, body.get("permissions") or {})
            return self.answer(201, {"token": token})
        if bearer not in installation_tokens: return self.answer(401, {"message": "Bad credentials"})
        key, scope, permissions = installation_tokens[bearer]
        if path == "/installation/repositories":
            items = [{"id": repositories[r]["id"], "full_name": r, "private": repositories[r]["private"]} for r in sorted(scope)]
            return self.answer(200, {"total_count": len(items), "repositories": items})
        parts = path.strip("/").split("/")
        name = "/".join(parts[1:3]) if parts[0] == "repos" and len(parts) >= 3 else None
        if name not in repositories or name not in scope: return self.answer(404, {"message": "Not Found"})
        repo, rest = repositories[name], "".join("/" + p for p in parts[3:])
        if rest == "" and self.command == "GET":
            return self.answer(200, {"id": repo["id"], "full_name": name, "private": repo["private"], "default_branch": "main"})
        if len(parts) == 6 and parts[3] == "collaborators" and parts[5] == "permission":
            if parts[4] not in users: return self.answer(404, {"message": "Not Found"})
            return self.answer(200, {"permission": repo["permissions"].get(parts[4], "none"), "user": {"id": users[parts[4]], "login": parts[4]}})
        if self.command != "GET" and permissions.get("contents") != "write": return self.answer(403, {"message": "Resource not accessible"})
        try:
            return self.answer(*api.git_route(repo["bare"], name, pulls.setdefault(name, []), self.command, rest, body))
        except ValueError as e:
            return self.answer(422, {"message": str(e)[:200]})

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_request


ThreadingHTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
