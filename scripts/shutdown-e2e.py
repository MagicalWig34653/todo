#!/usr/bin/env python3
"""End-to-end check of card 395200D3: the real backend gets SIGTERM while long polls are open (rolling update in the swarm).

The waits must be answered at once, the process must end with status 0 and the log must not hold a fatal error.
Usage: shutdown-e2e.py APP_BINARY SCRATCH_DIR PORT   (empty SQLite database in SCRATCH_DIR, nothing else is touched)
"""
import hashlib, json, os, secrets, signal, sqlite3, subprocess, sys, threading, time, urllib.error, urllib.request, uuid

app, scratch, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
base = f"http://127.0.0.1:{port}"
database = os.path.join(scratch, "e2e.sqlite")
env = dict(os.environ, DATABASE_DRIVER="sqlite", DB_NAME=database, RP_ID="localhost", RP_ORIGIN=f"http://localhost:{port}",
           BOOTSTRAP_TOKEN="e2e-bootstrap-only")
failures, passed = [], 0


def check(name, cond, detail=""):
    global passed
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {str(detail)[:600]}"))
    if cond: passed += 1
    else: failures.append(name)


def get(path, token, timeout=40):
    request = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response: return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error: return error.code, error.read()
    except Exception as error: return -1, repr(error)


subprocess.run([app, "migrate", "--yes"], env=env, check=True, capture_output=True)
token, user = secrets.token_hex(24), uuid.uuid4()
with sqlite3.connect(database) as db:
    now = time.time()
    db.execute("INSERT INTO users (id, display_name, is_admin, created_at) VALUES (?, 'Shutdown E2E', 0, ?)", (str(user).upper(), now))
    db.execute("INSERT INTO sessions (id, user_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
               (str(uuid.uuid4()).upper(), str(user).upper(), hashlib.sha256(token.encode()).hexdigest(), now + 3600, now))

for round_number in (1, 2, 3):
    log_path = os.path.join(scratch, f"backend-{round_number}.log")
    with open(log_path, "wb") as log:
        process = subprocess.Popen([app, "serve", "--hostname", "127.0.0.1", "--port", str(port)], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        for _ in range(200):
            try:
                with urllib.request.urlopen(base + "/health/ready", timeout=1): break
            except Exception: time.sleep(0.2)
        status, head = get("/v1/sync/head", token)
        check(f"round {round_number}: backend ready and head answers", status == 200, head)
        results = []
        waits = [threading.Thread(target=lambda n=n: results.append(get(
            f"/v1/sync/wait?since={head['token']}&timeout=25&client=e2e-tab-000{n}", token))) for n in range(3)]
        for w in waits: w.start()
        time.sleep(1.5)
        check(f"round {round_number}: three long polls are open", all(w.is_alive() for w in waits), results)
        started = time.time()
        process.send_signal(signal.SIGTERM)
        try: code = process.wait(timeout=20)
        except subprocess.TimeoutExpired: code = "timeout"
        for w in waits: w.join(timeout=20)
        took = time.time() - started
        check(f"round {round_number}: process ends with status 0 after SIGTERM", code == 0, code)
        check(f"round {round_number}: shutdown does not wait for the long poll deadline ({took:.1f} s)", took < 8, took)
        check(f"round {round_number}: every open wait got 200 with retryAfter",
              len(results) == 3 and all(s == 200 and b.get("retryAfter") == 2 and b.get("changed") is False for s, b in results), results)
        text = open(log_path, errors="replace").read()
        check(f"round {round_number}: no fatal error in the log", "Fatal error" not in text and "Assertion failed" not in text, text[-600:])
    finally:
        if process.poll() is None:
            process.kill(); process.wait()

print(f"{passed} ok, {len(failures)} failed")
sys.exit(1 if failures else 0)
