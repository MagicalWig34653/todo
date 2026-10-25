# ADR 0004 – Claude-Code-Start durch den Mac-Runner

Status: Machbarkeit belegt (25.10.2026), Details offen.

**Geprüft** mit Claude Code 2.1.310 auf macOS: `claude -p "<prompt>" --session-id <uuid> --output-format json --allowedTools Read --permission-mode dontAsk --max-turns N` in einem Arbeitsordner liest eine Datei und liefert JSON (`result`, `session_id`, `is_error`). `claude -p … --resume <uuid>` setzt dieselbe Sitzung fort und kennt den vorherigen Inhalt.

**Folgerung.** Der Runner vergibt die Session-UUID selbst und speichert sie im Checkpoint des AgentRun; Fortsetzung nach einer Rückfrage läuft über `--resume`. Werkzeuge werden per `--allowedTools` begrenzt.

**Nicht geprüft.** Authentifizierung auf fremden Macs, Verhalten bei Schlaf/gesperrtem Mac, Abbruch/Stop laufender Prozesse, macOS-Sandbox der verteilten App (Prozessstart und Ordnerzugriff), MCP-Anbindung des Todo-Servers an diesen Lauf, Verhalten bei Lease-Verlust. Die Sitzungsdaten liegen lokal beim CLI; der Checkpoint in der App muss ohne sie fortsetzbar sein.
