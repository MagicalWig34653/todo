#!/usr/bin/env python3
"""Turns an answer of REST POST /v1/deploy-targets/{id}/pull (or the MCP tool pull_server_changes) into a branch with one commit
in a local git repository (card 354ADE12, phase 2a, ADR 0041). Todolino itself never writes to GitHub or to the repo: the person
or the agent runs this (or does the same by hand), then pushes and opens the PR.

  deploy-pull-apply.py REPO [--author "Name <mail>"] [--base REF] < answer.json

The answer may be a merged one (the `files` of all pages, the last `branch` and `commitMessage`). The script refuses an answer with
ok=false, paths that leave the repo or touch .git, symlinks on the way, a dirty working tree and a branch name outside server/*.
An existing branch name gets -2, -3, ... Exit code 0: JSON {"branch", "commit", "files"} on stdout; 2: refused; 3: nothing to commit.
"""
import base64, json, os, re, subprocess, sys


def refuse(message, code=2):
    print("deploy-pull-apply: " + message, file=sys.stderr)
    sys.exit(code)


def git(repo, *args, input=None):
    cmd = ["git", "-c", "core.autocrlf=false", "-c", "core.safecrlf=false", "-c", "commit.gpgsign=false", "-C", repo, *args]
    return subprocess.run(cmd, input=input, capture_output=True, check=False)


def run(repo, *args, input=None):
    r = git(repo, *args, input=input)
    if r.returncode != 0:
        refuse(f"git {args[0]} failed: {r.stderr.decode(errors='replace').strip()[:300]}")
    return r.stdout.decode()


def safe_relative(path):
    if not isinstance(path, str) or not path or len(path) > 1024 or path.startswith("/") or "\\" in path or any(ord(c) < 32 for c in path):
        return False
    parts = path.split("/")
    return all(p not in ("", ".", "..") for p in parts) and parts[0].lower() != ".git" and ".git" not in [p.lower() for p in parts]


def main(argv):
    args, author, base = [], None, None
    it = iter(argv)
    for a in it:
        if a == "--author":
            author = next(it, None)
            if not author or author.startswith("-"): refuse("--author needs a value like 'Name <mail>'")
        elif a == "--base":
            base = next(it, None)
            if not base or base.startswith("-"): refuse("--base needs a branch, tag or commit")
        else: args.append(a)
    if len(args) != 1: refuse("usage: deploy-pull-apply.py REPO [--author 'Name <mail>'] [--base REF] < answer.json")
    repo = os.path.realpath(args[0])
    if git(repo, "rev-parse", "--is-inside-work-tree").returncode != 0: refuse("not a git repository")
    try: answer = json.load(sys.stdin)
    except ValueError: refuse("the answer is not JSON")
    if not isinstance(answer, dict) or answer.get("ok") is not True: refuse(f"the answer is not ok (code {answer.get('code') if isinstance(answer, dict) else None})")
    files = answer.get("files") or []
    if not files: refuse("the answer holds no files", 3)
    branch, message = answer.get("branch") or "", answer.get("commitMessage") or ""
    if not re.fullmatch(r"server/[a-z0-9][a-z0-9-]{0,60}-\d{4}-\d{2}-\d{2}", branch): refuse("unexpected branch name")
    if not message.strip(): refuse("empty commit message")
    # Everything is checked and decoded before the repo is touched.
    decoded = []
    for f in files:
        if not isinstance(f, dict) or not safe_relative(f.get("path")): refuse(f"unsafe path {f.get('path') if isinstance(f, dict) else f!r}")
        if f.get("encoding") not in ("utf-8", "base64") or not isinstance(f.get("content"), str): refuse("unknown encoding")
        try: data = base64.b64decode(f["content"], validate=True) if f["encoding"] == "base64" else f["content"].encode("utf-8")
        except (ValueError, UnicodeError): refuse(f"cannot decode {f['path']}")
        decoded.append((f["path"], data))
    if len({p for p, _ in decoded}) != len(decoded): refuse("a path appears twice")
    if base and git(repo, "rev-parse", "--verify", "--quiet", "--end-of-options", base + "^{commit}").returncode != 0: refuse("unknown base")
    base_sha = run(repo, "rev-parse", "--verify", "--end-of-options", base + "^{commit}").strip() if base else None
    if run(repo, "status", "--porcelain").strip(): refuse("the working tree is not clean")
    ignored = git(repo, "check-ignore", "--no-index", "--stdin", "-z", input="\0".join(p for p, _ in decoded).encode() + b"\0")
    if ignored.stdout.strip(b"\0"): refuse("a path is ignored by git: " + ignored.stdout.split(b"\0")[0].decode(errors="replace"))
    name, n = branch, 1
    while git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + name).returncode == 0:
        n += 1; name = f"{branch}-{n}"
    previous = run(repo, "rev-parse", "--abbrev-ref", "HEAD").strip()
    if previous == "HEAD": previous = run(repo, "rev-parse", "HEAD").strip()
    run(repo, "switch", "-c", name, *([base_sha] if base_sha else []))
    written, created_dirs = [], []
    try:
        for path, data in decoded:
            target = os.path.join(repo, *path.split("/"))
            probe = repo
            for part in path.split("/")[:-1]:
                probe = os.path.join(probe, part)
                if os.path.islink(probe): refuse(f"a symlink is in the way: {path}")
            if os.path.islink(target) or (os.path.exists(target) and not os.path.isfile(target)): refuse(f"not a regular file: {path}")
            if os.path.commonpath([repo, os.path.realpath(os.path.dirname(target))]) != repo: refuse(f"outside the repo: {path}")
            parent = os.path.dirname(target)
            missing = []
            while not os.path.exists(parent): missing.append(parent); parent = os.path.dirname(parent)
            os.makedirs(os.path.dirname(target), exist_ok=True); created_dirs += reversed(missing)
            existed = os.path.exists(target)
            with open(target, "wb") as out: out.write(data)
            written.append((path, existed))
        run(repo, "--literal-pathspecs", "add", "--", *[p for p, _ in written])
        if git(repo, "diff", "--cached", "--quiet").returncode == 0: refuse("nothing changed against the repo", 3)
        run(repo, "commit", "-q", *(["--author", author] if author else []), "-F", "-", input=message.encode())
    except BaseException as e:
        # Back to where we were: tracked files restored, files this run created removed, branch deleted.
        git(repo, "reset", "-q", "--hard")
        for path, existed in written:
            if not existed:
                try: os.remove(os.path.join(repo, *path.split("/")))
                except OSError: pass
        for d in reversed(created_dirs):
            try: os.rmdir(d)
            except OSError: pass
        git(repo, "switch", "-q", previous); git(repo, "branch", "-q", "-D", name)
        if isinstance(e, SystemExit): raise
        refuse(f"unexpected error, nothing changed: {type(e).__name__}")
    print(json.dumps({"branch": name, "commit": run(repo, "rev-parse", "HEAD").strip(), "files": [p for p, _ in written]}))


if __name__ == "__main__":
    main(sys.argv[1:])
