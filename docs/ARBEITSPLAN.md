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
