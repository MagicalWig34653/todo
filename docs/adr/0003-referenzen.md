# ADR 0003 – Timetrack nur als Lesereferenz

Status: angenommen (25.10.2026, Nutzerentscheidung).

`timetrack-backend` und `timetrack-pwa` werden gelesen, aber weder verändert noch kopiert. Passkey, Sessions, Recovery, OAuth/MCP und Job-Leases werden neu geschrieben. Damit entfällt die Frage nach Lizenz und AGPL-/OpenSSL-Folgen einer Codeübernahme.
