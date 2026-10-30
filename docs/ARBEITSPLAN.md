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

## MCP-Erweiterung und Cleanup (26.10.2026)
- [x] MCP: list_comments, add_comment, get_progress (lesend), list_attachments, get_attachment; Scopes comments:write, attachments:read, agents:read; gemeinsamer CommentService mit REST
- [x] `cleanup-expired` (replikatsicher), Tests SQLite und MariaDB (eigene DB), Vertrag, ADR 0007 Nachtrag
- [ ] Cleanup als wiederkehrenden Job einplanen (Cron/Swarm) und in BETRIEB dokumentieren
- [ ] Consent-Oberfläche für neue Scopes; Claude-Code-Abnahme der neuen Werkzeuge
## Checkpoint 26.10.2026 (Backend-Lücken PWA Etappe 2)
- [x] activity_events aus Task-/Planungs-/Agentenrouten; Kommentar-/Aktivitätsnamen; eingeschränkte Nutzersuche; Teamname in Einladungen; Planungsdaten in `GET /v1/tasks` (Details in STATUS). SQLite + MariaDB grün.
- [ ] PWA auf neue Felder umstellen; Projekt-/Freigabe-Ereignisse (eigenes Modell) konzipieren; UI zum Ausstellen von Recovery-Codes.

## Sync-Strang (26.10.2026)
- [x] Backend: Änderungsfeed mit Cursor, Tombstones, idempotente Mutationen mit 409 (ADR 0009, `contracts/sync.yaml`); SQLite und MariaDB grün (88 Tests).
- [x] Zugriffsänderungen (Freigabe/Entzug/Verschieben) als Feedereignisse (27.10.2026, SQLite geprüft; MariaDB-Nachprüfung offen).
- [ ] Aufbewahrung/Kompaktierung.
- [ ] PWA-Offline-Cache und Apple-Client an Sync anbinden; Merge des Branches in `main`.

## Sync-Sichtbarkeitsänderungen (27.10.2026)
- Auftrag: Zugriffsgewinne und -verluste unter `lockSharingGraph` transaktional im DB-Feed erfassen; SQLite-SyncTests prüfen, Vertrag/ADR aktualisieren. Kein Commit, Docker oder Änderungen an web/.
- Umsetzung: effektive Leser vor/nach Sharing- und Verschiebeoperationen vergleichen; Zugriffsverlust von echter Löschung unterscheiden.
- Nächster Schritt: Implementierung und Regressionstests; MariaDB bleibt ungeprüft.

### Abschluss Sync-Sichtbarkeit (27.10.2026)
- [x] Effektive Sichtbarkeit transaktional vergleichen und Upserts/Entzug-Tombstones einschließlich Altbestand persistieren; erneute Freigabe, alternative Rechte und Elternredaktion berücksichtigen.
- [x] SyncTests: 10 Tests, 1 MariaDB-Test übersprungen, 0 Fehler; separater nativer Swift-Build erfolgreich, YAML geparst, Diff-Whitespace geprüft. Reproduzierbarer Sandbox-Aufruf und Grenzen in STATUS.md.
- [x] Vertrag 1.1.0 und ADR 0009 aktualisiert; keine neue Schema-Migration, interner `revoke`-Typ erfordert neue Leser auf allen Replikaten. `main`/`5bec1c5`, uncommitted; keine eigenen Jobs, kein Docker/Commit, fremde web/- und Screenshot-Änderungen erhalten.
- [ ] Nächster Schritt: MariaDB-Konkurrenzabnahme, danach Clients anbinden und Vergleichskosten messen. Linux und echte Clients in diesem Auftrag ungeprüft.

### Darstellung und Account-Preferences (29.10.2026)
- [x] Backend `GET/PUT /v1/me/preferences` (Vertrag, Migration, Tests SQLite+MariaDB); PWA-Bereich "Darstellung" unter Konto mit Farbschema, Akzent (Presets/eigen), Leuchteffekt, Transparenz, Pre-Paint, Abgleich; Screenshots hell/dunkel. Details und Grenzen in STATUS.md.
- [ ] Nächster Schritt: Apple-Client an Preferences anbinden; weitere Einstellungsgruppen im Dokument (`version` erhöhen, `PreferencesDocument.migrated`).

## Projektspalten (29.10.2026)
Anforderung: **Projekte unbegrenzt; projektspezifische Spalten statt Projekt-als-Spalte-Workaround** (Todoist-Limit, ADR 0011).
- [x] Backend: `project_columns`, `tasks.column_id/board_position`, REST (`/v1/projects/{id}/columns|board`, `PUT /v1/tasks/{id}/column`), Sync-Feed, MCP `list_columns`/`move_task_to_column`, `contracts/project-columns.yaml`, Tests (SQLite, MariaDB).
- [ ] PWA: Board-Ansicht pro Projekt mit Drag-and-drop, Spalten verwalten (anlegen, umbenennen, einfärben, sortieren, löschen mit Zielwahl), Vorlage Offen/In Arbeit/Erledigt oder Kopie.
- [ ] Apple: Board-Ansicht anbinden (Vertrag unverändert, `contracts/project-columns.yaml`).
- [ ] Sync-Mutationen für Spalten (Offline-Schreiben), optional MCP-Schreibwerkzeuge für Spalten.

## Checkpoint 29.10.2026 (PWA-Struktur und Spalten-Board)
- [x] PWA in Todoist-Struktur (Seitenleiste, Quick-Add, Projektseite, Board mit Projektspalten) – Details und Prüfstand in STATUS.
- [ ] Backend: Favoriten, Projektbeschreibung, Projektfarbe, Projektreihenfolge; danach localStorage-Provisorien entfernen.
- [ ] Apple: Board-Anbindung an `GET /v1/projects/{id}/board`.

## Checkpoint 30.10.2026 (Backend-Lücken PWA/Apple)
- [x] Projektbeschreibung/-farbe, Favoriten und Anzeigeeinstellungen je Konto, Projektreihenfolge je Konto (ADR 0012), Projektkommentare, Aktivitätsfeed, Runner-Geräte-/Auftragslisten, Spalten-Sync-Mutationen und MCP-Spaltenwerkzeuge; SQLite + MariaDB grün (siehe STATUS).
- [ ] PWA: `localStorage`-Provisorien auf die neuen Endpunkte umstellen (Favoriten, Beschreibung, Anzeige, Sortierung per Drag-and-drop, Projektkommentare, Aktivität, Geräte-/Auftragsliste); Apple: dieselben Verträge und Board anbinden.
- [ ] Optional: Projektkommentare/-aktivität in Sync-Feed und MCP.

## Checkpoint 30.10.2026 (Anhänge in der Datenbank)
- [x] S3 optional, Anhänge standardmäßig in der DB (ADR 0013), `migrate-storage`, Infrastruktur/Docs ohne S3-Pflicht; SQLite + MariaDB grün (siehe STATUS).
- [ ] Offen: S3-Test und `migrate-storage` gegen S3Mock (`docker compose --profile s3 up -d s3`, `S3_ENDPOINT=http://localhost:29090 S3_BUCKET=todo-attachments`), Swarm-Smoke erneut ausführen, bei Bedarf Streaming-Download für größere Limits.

## Steuerzentrale für Agenten (30.10.2026, ADR 0014)
- [x] Backend + MCP: Handbuch, Briefing, Fragen, Fortschritt/Features, Reviews, Build-Screenshots, `GET /v1/command-center`.
- [ ] PWA: Seite "Überblick" (Kanban-Lanes, Listenansicht, Fragen beantworten, Review entscheiden, Briefing-Editor, Screenshot-Galerie, Vorlage anwenden).
- [ ] Apple: dieselben Ansichten (Vertrag `contracts/command-center.yaml`). Consent-Oberfläche für Scope `attachments:write`.
- [ ] Optional: Sync-Feed/Push für Fragen und Reviews; SQL-Voraggregation.
