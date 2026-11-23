#!/usr/bin/env python3
"""End-to-end check of account deletion (cards BCA27B3D, 69439B31) against a running backend and the real operator command.

Usage: account-deletion-e2e.py BASE_URL SESSION_A USER_A SESSION_B USER_B SESSION_C USER_C SQLITE_FILE APP_BINARY
A is deleted. B and C survive.
"""
import json, os, sqlite3, subprocess, sys, urllib.error, urllib.request

base, sa, ua, sb, ub, sc, uc, db_path, native = sys.argv[1:10]
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

def http(method, path, body=None, token=None):
    h = {"Authorization": f"Bearer {token}"} if token else {}
    data = None
    if body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with urllib.request.urlopen(req) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def j(b):
    try: return json.loads(b)
    except Exception: return None

def must(st_body, what):
    st, body = st_body
    if st >= 300: print(f"FAIL setup {what}: {st} {body!r}"); sys.exit(1)
    return j(body)

def projects(token):
    data = j(http("GET", "/v1/projects", token=token)[1])
    items = data if isinstance(data, list) else (data or {}).get("projects") or (data or {}).get("items") or []
    return {p["id"].lower(): p for p in items}

# Case 1: A owns P and shares it with B (manage); B builds S below P and G below S, plus a task in S.
p = must(http("POST", "/v1/projects", {"name": "A Projekt"}, sa), "project P")["id"]
must(http("PUT", f"/v1/projects/{p}/grants", {"principalType": "person", "principalID": ub, "role": "manage"}, sa), "grant B")
s = must(http("POST", "/v1/projects", {"name": "B Unterprojekt", "parentID": p}, sb), "sub-project S")["id"]
g = must(http("POST", "/v1/projects", {"name": "B Enkel", "parentID": s}, sb), "grandchild G")["id"]
must(http("POST", "/v1/tasks", {"projectID": s, "title": "B Aufgabe"}, sb), "task in S")
before = projects(sb)
check("setup: B sees P, S below P and G below S", {p.lower(), s.lower(), g.lower()} <= set(before)
      and (before[s.lower()].get("parentID") or "").lower() == p.lower(), before)

# Case 2: A founds T1 with plain member B and admin C, and T2 alone.
t1 = must(http("POST", "/v1/teams", {"name": "Team Eins"}, sa), "team T1")["id"]
t2 = must(http("POST", "/v1/teams", {"name": "Team Zwei"}, sa), "team T2")["id"]
must(http("PUT", f"/v1/teams/{t1}/members", {"userID": ub, "isAdmin": False}, sa), "invite B")
must(http("PUT", f"/v1/teams/{t1}/members", {"userID": uc, "isAdmin": True}, sa), "invite C")
check("setup: B accepts", http("POST", f"/v1/teams/{t1}/accept", token=sb)[0] < 300)
check("setup: C accepts", http("POST", f"/v1/teams/{t1}/accept", token=sc)[0] < 300)

# The operator command, as documented in docs/BETRIEB.md.
run = subprocess.run([native, "delete-account", ua, "--yes"], capture_output=True, text=True, env=os.environ)
print(run.stdout.strip())
check("delete-account exits 0", run.returncode == 0, run.stdout + run.stderr)

after = projects(sb)
check("P is gone", p.lower() not in after, after)
check("S survives and moved to the top level", s.lower() in after and not after[s.lower()].get("parentID"), after.get(s.lower()))
check("G survives below S", g.lower() in after and (after[g.lower()].get("parentID") or "").lower() == s.lower(), after.get(g.lower()))
st, body = http("GET", "/v1/tasks", token=sb)
tasks = j(body); tasks = tasks if isinstance(tasks, list) else (tasks or {}).get("tasks") or (tasks or {}).get("items") or []
check("B's task in S survives", any(t.get("title") == "B Aufgabe" for t in tasks), body[:200])

teams = {t["id"].lower(): t for t in j(http("GET", "/v1/teams", token=sb)[1]) or []}
check("T1 survives with C (admin) as founder", t1.lower() in teams and teams[t1.lower()]["founderID"].lower() == uc.lower(), teams.get(t1.lower()))
members = j(http("GET", f"/v1/teams/{t1}/members", token=sc)[1]) or []
check("C is an accepted admin, A is no member", any(m["userID"].lower() == uc.lower() and m["isAdmin"] and m["accepted"] for m in members)
      and all(m["userID"].lower() != ua.lower() for m in members), members)
con = sqlite3.connect(db_path)
n2 = con.execute("SELECT count(*) FROM sharing_teams WHERE lower(id) = ?", (t2.lower(),)).fetchone()[0]
check("T2 (no other member) is removed", n2 == 0, n2)
refs = con.execute("SELECT count(*) FROM sharing_teams WHERE lower(founder_id) = ?", (ua.lower(),)).fetchone()[0]
check("no team references the deleted account", refs == 0, refs)
check("A's user row is gone", con.execute("SELECT count(*) FROM users WHERE lower(id) = ?", (ua.lower(),)).fetchone()[0] == 0)
check("no foreign-key violations", con.execute("PRAGMA foreign_key_check").fetchall() == [])

print("\nFAILED: " + ", ".join(failures) if failures else "\nall checks passed")
sys.exit(1 if failures else 0)
