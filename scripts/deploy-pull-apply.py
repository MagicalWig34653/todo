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
        if a == "--author": author = next(it, None)
        elif a == "--base": base = next(it, None)
        else: args.append(a)
    if len(args) != 1: refuse("usage: deploy-pull-apply.py REPO [--author 'Name <mail>'] [--base REF] < answer.json")
    repo = os.path.realpath(args[0])
    if git(repo, "rev-parse", "--is-inside-work-tree").returncode != 0: refuse("not a git repository")
    answer = json.load(sys.stdin)
    if answer.get("ok") is not True: refuse(f"the answer is not ok (code {answer.get('code')})")
    files = answer.get("files") or []
    if not files: refuse("the answer holds no files", 3)
    branch, message = answer.get("branch") or "", answer.get("commitMessage") or ""
    if not re.fullmatch(r"server/[a-z0-9][a-z0-9-]{0,60}-\d{4}-\d{2}-\d{2}", branch): refuse("unexpected branch name")
    if not message.strip(): refuse("empty commit message")
    for f in files:
        if not safe_relative(f.get("path")): refuse(f"unsafe path {f.get('path')!r}")
        if f.get("encoding") not in ("utf-8", "base64") or not isinstance(f.get("content"), str): refuse("unknown encoding")
    if run(repo, "status", "--porcelain").strip(): refuse("the working tree is not clean")
    name, n = branch, 1
    while git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + name).returncode == 0:
        n += 1; name = f"{branch}-{n}"
    run(repo, "switch", "-c", name, *([base] if base else []))
    try:
        written = []
        for f in files:
            target = os.path.join(repo, *f["path"].split("/"))
            probe = repo
            for part in f["path"].split("/")[:-1]:
                probe = os.path.join(probe, part)
                if os.path.islink(probe): raise SystemExit(refuse(f"a symlink is in the way: {f['path']}"))
            if os.path.islink(target) or (os.path.exists(target) and not os.path.isfile(target)): refuse(f"not a regular file: {f['path']}")
            if os.path.commonpath([repo, os.path.realpath(os.path.dirname(target))]) != repo: refuse(f"outside the repo: {f['path']}")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            data = base64.b64decode(f["content"], validate=True) if f["encoding"] == "base64" else f["content"].encode("utf-8")
            with open(target, "wb") as out: out.write(data)
            written.append(f["path"])
        run(repo, "add", "--", *written)
        if git(repo, "diff", "--cached", "--quiet").returncode == 0: refuse("nothing changed against the repo", 3)
        env_args = ["--author", author] if author else []
        run(repo, "commit", "-q", *env_args, "-F", "-", input=message.encode())
    except SystemExit as e:
        git(repo, "reset", "-q", "--hard"); git(repo, "switch", "-q", "-")
        git(repo, "branch", "-q", "-D", name)
        raise e
    print(json.dumps({"branch": name, "commit": run(repo, "rev-parse", "HEAD").strip(), "files": written}))


if __name__ == "__main__":
    main(sys.argv[1:])
