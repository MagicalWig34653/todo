# Arbeitsplan

## Etappe 0 – Grundlage
- [x] Bestandsaufnahme, Entscheidungen 12–14, ADR 0001–0003
- [x] Backend-Grundgerüst, Dev-Stack (MariaDB, S3Mock), Linux-Image, Health-Endpunkte
- [x] `contracts/openapi.yaml` mit Health-Endpunkten als Start
- [x] PWA-Grundgerüst (SvelteKit, shadcn-svelte, npm), erreicht Backend
- [x] Apple-Grundgerüst im zweiten Repository (gemeinsamer API-Kern, iOS/macOS/watchOS bauen)
- [x] Runner-Machbarkeit: Claude Code nichtinteraktiv starten und fortsetzen (ADR 0004)
- [ ] README: Start aus frischem Checkout dokumentieren

## Etappe 1 – Persönlicher vertikaler Schnitt
Backend-Teil erledigt (siehe STATUS). Parallele Arbeitsströme (getrennte Worktrees) laufen für: PWA-Login/-Listen, Apple-Client, OpenAPI-Vertrag, Teams/Freigaben, Anhänge (S3Mock), MCP/OAuth, Agentenaufträge/Runner-API.
Datenmodell/Migrationen → Bootstrap und Passkey → Capability-Endpunkt und Passwort-Schalter → Projekte/Aufgaben-API → PWA → SwiftUI-Minimalclient → gezielte Tests (Autorisierung, Schalter, Challenge über zwei Replikate, MariaDB-Konkurrenz). Details: UMSETZUNGSPLAN.md.

## Checkpoints
Nach jedem Teilschritt STATUS.md und diesen Plan aktualisieren. Bisher nichts committet; Commit nur auf Nutzerwunsch.

## Etappe 5 – Labels/Suche (26.10.2026)
- [x] Bestand/Rechte gelesen; Discovery-Schema und API-Schnitt implementiert (siehe STATUS, Abschnitt Labels/Suche).
- [ ] Vertrag und Tests für private Metadaten, Rechteentzug, Wildcards, Cursor und gespeicherte Kriterien abschließen.
- [ ] SQLite und isolierte MariaDB-Datenbank prüfen, Grenzen dokumentieren und auf Worktree-Branch committen (expliziter Nutzerauftrag).
## Checkpoint 26.10.2026 (Orchestrierung)
Auf `main` zusammengeführt und getestet (34 Tests: SQLite grün, MariaDB grün): Etappe-1-Backend, Teams/Freigaben (ADR 0005), Agentenaufträge/Runner-API (ADR 0008), OpenAPI-Vertrag mit Router-Test, PWA Etappe 1 (inkl. Playwright-E2E mit virtuellem Authenticator). Apple-Repo: `feature/etappe1-client` nach `main` gemergt (API-Client, Passkey-Anbindung, Projekt-/Aufgabenansicht; Passkey auf Gerät ungeprüft).
In Arbeit (Worktrees `.claude/worktrees/*`, Apple `feature/runner`), da Codex bis 1.11.2026 ein Nutzungslimit hat und Agenten direkt weiterbauen: Kommentare/Aktivität, Identität/Recovery, Planung, Labels/Suche, Betrieb (Swarm/Backup), OAuth/MCP, Anhänge, Mac-Runner. Danach: Branches nacheinander mergen, Gesamtsuite auf SQLite + MariaDB.
Backend-Befund: Registrierungsoptionen sollen `residentKey=required` setzen (wird vom Identitäts-Strang erledigt).

## Checkpoint 26.10.2026 spätnachts
`main` enthält zusätzlich Anhänge (ADR 0006): 39 Tests grün auf MariaDB inkl. S3Mock (Mehrreplikat-Upload/-Download), eigene Testdatenbank `TODO_TEST_DB`. S3-Tests brauchen `S3_ENDPOINT=http://localhost:29090 S3_BUCKET=todo-attachments S3_ACCESS_KEY=test S3_SECRET_KEY=test S3_REGION=us-east-1`.
Agenten-Sessionlimit lief ab; Branches mit Zwischenstand (je ein Merge von main eingemischt, teils ungesichert im Worktree): Kommentare/Aktivität (aa22…), Identität (a134…), Planung (afc5…), Labels/Suche (a829…), Betrieb (a8e2…), OAuth/MCP (`oauth-mcp`), Mac-Runner (`/private/tmp/claude-501/runner-wt`, feature/runner). Fortsetzung nach Limit-Reset (ca. 7:20) per SendMessage an die Agenten; Reihenfolge des Merges: Identität, Kommentare, Planung, Labels, Betrieb, OAuth/MCP.

## Checkpoint 26.10.2026 vormittags
`main` (Hauptrepo) enthält jetzt: Etappe-1-Backend, Teams/Freigaben, Agentenaufträge/Runner-API, Anhänge, Identität/Recovery, Planung, Labels/Suche, Kommentare/Aktivität, Betrieb (Swarm-/Backup-Skripte, Einzelknoten real geprüft), OpenAPI-Vertrag. Gesamtsuite: 75 Tests auf MariaDB (+S3Mock) grün, 1 übersprungen. Apple-Repo `main`: API-Client Etappe 1, Mac-Runner (37 Tests, Live-Test mit claude-CLI).
Offen/in Arbeit: OAuth/MCP (Agent a01943d… nach Limit fortgesetzt), PWA Etappe 2 (Agent a54439e…), Apple Etappe 2 (Codex-Job im Worktree /private/tmp/claude-501/etappe2-wt, Branch feature/etappe2-client).
Bekannte Lücken: activity_events werden von Projekt-/Aufgaben-Routen noch nicht geschrieben; Runner-E2E gegen echtes Backend; Mehrknoten-Swarm; echte Geräte-Passkeys (Domain/AASA); Kommentar-/Anhangs-MCP-Tools; Linux-Build des Gesamtstands nicht neu geprüft.

## Checkpoint 26.10.2026 mittags
OAuth/MCP gemergt (ADR 0007). Beim Merge zeigte sich auf MariaDB 12 ein echter Fehler: ein Lesezugriff vor `SELECT … FOR UPDATE` in derselben Transaktion scheitert bei Konkurrenz mit "Record has changed since last read" (Snapshot-Isolation). Behoben in `OAuthController` (Lookup vor der Transaktion, Sperre vor dem ersten Lesen). **Regel für neue Konkurrenzcode:** zuerst sperren, dann lesen. Gesamtsuite: 83 Tests auf MariaDB grün (1 übersprungen), SQLite grün (14 übersprungen).
Claude-CLI gegen den MCP-Endpunkt: Discovery/401 und Tool-Aufrufe mit manuell beschafftem Token belegt; der interaktive OAuth-Flow der CLI im Browser ist nicht geprüft. PWA Etappe 2 läuft (Agent a54439e…, nach Limit fortgesetzt). Apple Etappe 2: Codex-Job im Worktree etappe2-wt.

## Checkpoint 26.10.2026 (Backend-Lücken PWA Etappe 2)
- [x] activity_events aus Task-/Planungs-/Agentenrouten; Kommentar-/Aktivitätsnamen; eingeschränkte Nutzersuche; Teamname in Einladungen; Planungsdaten in `GET /v1/tasks` (Details in STATUS). SQLite + MariaDB grün.
- [ ] PWA auf neue Felder umstellen; Projekt-/Freigabe-Ereignisse (eigenes Modell) konzipieren; UI zum Ausstellen von Recovery-Codes.
