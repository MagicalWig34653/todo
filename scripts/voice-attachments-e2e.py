#!/usr/bin/env python3
"""End-to-end check of voice attachments (ADR 0030, step 1) against a running backend.

Real HTTP against the real attachment endpoints with real M4A/WAV files (afconvert/ffmpeg) plus hand-built boundary files.
Usage: voice-attachments-e2e.py BASE_URL SESSION_A SESSION_B FILES_DIR
FILES_DIR contains: speech.m4a, speech.wav (real, short), and the boundary files written by the shell wrapper:
m4a_120s.m4a, m4a_121s.m4a, wav_120s.wav, wav_121s.wav, m4a_5mib.m4a, m4a_5mib_plus1.m4a, fake.m4a (PNG bytes), tone.mp3 (real MP3).
"""
import hashlib, json, os, sys, urllib.request, urllib.error

base, sess_a, sess_b, files = sys.argv[1:5]
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" {detail}"))
    if not cond: failures.append(name)

def http(method, path, body=None, token=None, raw=None, headers=None):
    h = dict(headers or {})
    if token: h["Authorization"] = f"Bearer {token}"
    data = raw
    if body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, method=method, data=data, headers=h)
    try:
        with urllib.request.urlopen(req) as r: return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e: return e.code, e.read(), e.headers

def jsonb(b):
    try: return json.loads(b)
    except Exception: return None

def read(name): return open(os.path.join(files, name), "rb").read()

st, b, _ = http("POST", "/v1/projects", {"name": "Voice E2E"}, sess_a); project = jsonb(b)["id"]
st, b, _ = http("POST", "/v1/tasks", {"projectID": project, "title": "Voice memo"}, sess_a); task = jsonb(b)["id"]

def upload(name, media, role="voice", token=sess_a, data=None, task_id=None):
    """Returns (status of first failing step or complete, attachment id)."""
    data = read(name) if data is None else data
    st, b, _ = http("POST", "/v1/attachments/begin", {"taskID": task_id or task, "filename": name, "role": role, "mediaType": media,
        "size": len(data), "checksum": hashlib.sha256(data).hexdigest()}, token)
    if st != 200: return st, None
    cap = jsonb(b)
    st, _, _ = http("PUT", cap["uploadURL"], token=cap["token"], raw=data, headers={"Content-Type": "application/octet-stream"})
    if st != 204: return st, cap["attachmentID"]
    st, _, _ = http("POST", f"/v1/attachments/{cap['attachmentID']}/complete", token=token)
    return st, cap["attachmentID"]

# Real recordings
for name, media in (("speech.m4a", "audio/mp4"), ("speech.wav", "audio/wav")):
    st, aid = upload(name, media)
    check(f"real {name} accepted as voice", st == 200, st)
    if st != 200: continue
    st, body, h = http("GET", f"/v1/attachments/{aid}/download", token=sess_a)
    check(f"{name} download bytes identical", st == 200 and body == read(name))
    check(f"{name} Cache-Control private, no-store", h.get("Cache-Control") == "private, no-store", h.get("Cache-Control"))
    check(f"{name} Content-Type {media}", h.get("Content-Type") == media, h.get("Content-Type"))
    check(f"{name} nosniff", h.get("X-Content-Type-Options") == "nosniff")
    st, _, _ = http("GET", f"/v1/attachments/{aid}/download", token=sess_b)
    check(f"{name} foreign account download 404", st == 404, st)
    st, _, _ = http("GET", f"/v1/attachments/{aid}/download")
    check(f"{name} anonymous download 401", st == 401, st)
    st, _, _ = http("GET", f"/v1/attachments/{aid}/download", token=sess_a, headers={"Range": "bytes=0-9"})
    check(f"{name} range 206", st == 206, st)

# Boundaries
for name, media, want, label in (
    ("m4a_120s.m4a", "audio/mp4", 200, "M4A exactly 120 s ok"),
    ("m4a_121s.m4a", "audio/mp4", 422, "M4A 121 s rejected 422"),
    ("wav_120s.wav", "audio/wav", 200, "WAV exactly 120 s ok"),
    ("wav_121s.wav", "audio/wav", 422, "WAV 121 s rejected 422"),
    ("m4a_5mib.m4a", "audio/mp4", 200, "exactly 5 MiB ok"),
    ("m4a_5mib_plus1.m4a", "audio/mp4", 413, "5 MiB + 1 byte rejected 413"),
    ("fake.m4a", "audio/mp4", 415, "PNG bytes declared audio/mp4 rejected 415"),
    ("speech.wav", "audio/mp4", 415, "WAV bytes declared audio/mp4 rejected 415"),
    ("tone.mp3", "audio/mpeg", 415, "MP3 rejected 415"),
):
    st, _ = upload(name, media)
    check(label, st == want, f"got {st}")
st, _ = upload("speech.m4a", "audio/mp4", role="result")
check("audio with role result rejected 400", st == 400, st)
st, _ = upload("speech.m4a", "audio/mp4", token=sess_b)
check("foreign account cannot begin on this task (404)", st == 404, st)
st, b, _ = http("GET", f"/v1/tasks/{task}/attachments", token=sess_a)
listed = jsonb(b)
check("only accepted voice files are listed", len(listed) == 5 and all(a["role"] == "voice" for a in listed), len(listed))
png = bytes.fromhex("89504e470d0a1a0a") + b"\0" * 20
st, _ = upload("x.png", "image/png", role="result", data=png)
check("existing image/result path unchanged", st == 200, st)

print("FAILED: " + ", ".join(failures) if failures else "ALL OK")
sys.exit(1 if failures else 0)
