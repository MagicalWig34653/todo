#!/usr/bin/env python3
"""Minimal SMTP sink for local tests: accepts every message and appends it as one JSON line to a file.

    python3 web/scripts/smtp-sink.py 2525 /tmp/mails.jsonl

No TLS, no authentication, loopback only. Used by e2e/mail.spec.ts together with
MAIL_ENABLED=true SMTP_HOST=127.0.0.1 SMTP_PORT=2525 SMTP_SECURITY=none MAIL_FROM=todolino@example.org.
"""
import email
import email.policy
import json
import socketserver
import sys


class Handler(socketserver.StreamRequestHandler):
    def send(self, line):
        self.wfile.write((line + "\r\n").encode())

    def handle(self):
        self.send("220 sink ESMTP")
        sender, rcpt = "", []
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            cmd = raw.decode("utf-8", "replace").strip()
            up = cmd.upper()
            if up.startswith("EHLO") or up.startswith("HELO"):
                self.send("250-sink")
                self.send("250 SIZE 1000000")
            elif up.startswith("MAIL FROM"):
                sender, rcpt = cmd[10:].strip(" <>"), []
                self.send("250 ok")
            elif up.startswith("RCPT TO"):
                rcpt.append(cmd[8:].strip(" <>"))
                self.send("250 ok")
            elif up == "DATA":
                self.send("354 end with <CRLF>.<CRLF>")
                lines = []
                while True:
                    row = self.rfile.readline()
                    if not row or row in (b".\r\n", b".\n"):
                        break
                    lines.append(row[1:] if row.startswith(b"..") else row)
                msg = email.message_from_bytes(b"".join(lines), policy=email.policy.default)
                body = msg.get_body(preferencelist=("plain",))
                record = {
                    "from": sender,
                    "to": rcpt,
                    "subject": str(msg["Subject"]),
                    "text": body.get_content() if body else "",
                }
                with open(sys.argv[2], "a", encoding="utf-8") as f:
                    f.write(json.dumps(record, ensure_ascii=False) + "\n")
                self.send("250 queued")
            elif up == "QUIT":
                self.send("221 bye")
                return
            else:
                self.send("250 ok")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 2525
    if len(sys.argv) < 3:
        sys.exit("usage: smtp-sink.py PORT OUTPUT.jsonl")
    with Server(("127.0.0.1", port), Handler) as server:
        server.serve_forever()
