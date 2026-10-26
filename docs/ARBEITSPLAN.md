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

## Checkpoint 26.10.2026 (Orchestrierung)
Auf `main` zusammengeführt und getestet (34 Tests: SQLite grün, MariaDB grün): Etappe-1-Backend, Teams/Freigaben (ADR 0005), Agentenaufträge/Runner-API (ADR 0008), OpenAPI-Vertrag mit Router-Test, PWA Etappe 1 (inkl. Playwright-E2E mit virtuellem Authenticator). Apple-Repo: `feature/etappe1-client` nach `main` gemergt (API-Client, Passkey-Anbindung, Projekt-/Aufgabenansicht; Passkey auf Gerät ungeprüft).
In Arbeit (Worktrees `.claude/worktrees/*`, Apple `feature/runner`), da Codex bis 1.11.2026 ein Nutzungslimit hat und Agenten direkt weiterbauen: Kommentare/Aktivität, Identität/Recovery, Planung, Labels/Suche, Betrieb (Swarm/Backup), OAuth/MCP, Anhänge, Mac-Runner. Danach: Branches nacheinander mergen, Gesamtsuite auf SQLite + MariaDB.
Backend-Befund: Registrierungsoptionen sollen `residentKey=required` setzen (wird vom Identitäts-Strang erledigt).

## Checkpoint 26.10.2026 spätnachts
`main` enthält zusätzlich Anhänge (ADR 0006): 39 Tests grün auf MariaDB inkl. S3Mock (Mehrreplikat-Upload/-Download), eigene Testdatenbank `TODO_TEST_DB`. S3-Tests brauchen `S3_ENDPOINT=http://localhost:29090 S3_BUCKET=todo-attachments S3_ACCESS_KEY=test S3_SECRET_KEY=test S3_REGION=us-east-1`.
Agenten-Sessionlimit lief ab; Branches mit Zwischenstand (je ein Merge von main eingemischt, teils ungesichert im Worktree): Kommentare/Aktivität (aa22…), Identität (a134…), Planung (afc5…), Labels/Suche (a829…), Betrieb (a8e2…), OAuth/MCP (`oauth-mcp`), Mac-Runner (`/private/tmp/claude-501/runner-wt`, feature/runner). Fortsetzung nach Limit-Reset (ca. 7:20) per SendMessage an die Agenten; Reihenfolge des Merges: Identität, Kommentare, Planung, Labels, Betrieb, OAuth/MCP.
