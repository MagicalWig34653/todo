# Arbeitsplan

## Checkpoint 1.11.2026 (Stop-Hook wartet auf Antwort, Option b Variante 2)

Ziel: Sitzung endet nicht, solange eine eigene blockierende Frage offen ist. Gebaut: `claude-plugin/scripts/stop.sh` (fester Text, `wait_for_events` dann `get_question`, max. 6 Fortsetzungen, `stop_hook_active`-Schutz), Tests in `claude-plugin/tests/test-hooks.sh` (32 Prüfungen grün), Doku in `CLAUDE-CODE-EINRICHTUNG.md` und `PUSH-AN-CLAUDE-CODE.md`. Grenzen: trägt nur wenige Minuten (max. 8 Fortsetzungen durch Claude Code), nicht in einer echten Sitzung erprobt, `claude plugin validate` im Agentenlauf nicht ausführbar. Nächstes: manuell in Claude Code erproben, danach Spike für den `mcp_tool`-Hook (Variante 1).

## Etappe 0 – Grundlage
- [x] Bestandsaufnahme, Entscheidungen 12–14, ADR 0001–0003
- [x] Backend-Grundgerüst, Dev-Stack (MariaDB, S3Mock), Linux-Image, Health-Endpunkte
- [x] `contracts/openapi.yaml` mit Health-Endpunkten als Start
- [x] PWA-Grundgerüst (SvelteKit, shadcn-svelte, npm), erreicht Backend
- [x] Apple-Grundgerüst im zweiten Repository (gemeinsamer API-Kern, iOS/macOS/watchOS bauen)
- [x] Runner-Machbarkeit: Claude Code nichtinteraktiv starten und fortsetzen (ADR 0004)
- [x] README: Start aus frischem Checkout dokumentieren (README überarbeitet 31.10.2026)

## Etappe 1 – Persönlicher vertikaler Schnitt
Backend-Teil erledigt (siehe STATUS). Parallele Arbeitsströme (getrennte Worktrees) laufen für: PWA-Login/-Listen, Apple-Client, OpenAPI-Vertrag, Teams/Freigaben, Anhänge (S3Mock), MCP/OAuth, Agentenaufträge/Runner-API.
Datenmodell/Migrationen → Bootstrap und Passkey → Capability-Endpunkt und Passwort-Schalter → Projekte/Aufgaben-API → PWA → SwiftUI-Minimalclient → gezielte Tests (Autorisierung, Schalter, Challenge über zwei Replikate, MariaDB-Konkurrenz). Details: UMSETZUNGSPLAN.md.

## Checkpoints
Nach jedem Teilschritt STATUS.md und diesen Plan aktualisieren. Bisher nichts committet; Commit nur auf Nutzerwunsch.

## Berechtigungen in der PWA auffindbar (31.10.2026)

Erledigt: Teilen-Schaltfläche und eigene Rolle im Projektkopf, neues Teilen-Fenster, Teams in der Seitenleiste, "Mit mir geteilt", Konto "Berechtigungen & Zugriff", deaktivierte Aktionen mit Erklärung, [BERECHTIGUNGEN.md](BERECHTIGUNGEN.md). Details und Prüfstand: STATUS.md "Checkpoint 31.10.2026 (Berechtigungen auffindbar und verständlich)". Offen (Vorschläge, nicht beschlossen): Zuweisungen, feinere Rollen, Nutzerverwaltung, `GET /v1/me/access`, Rolle/Eigentümer in den Apple-Clients.

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
- [x] Cleanup als wiederkehrenden Job: In-Process-Scheduler mit DB-Lease (31.10.2026, ADR 0019, BETRIEB)
- [ ] Consent-Oberfläche für neue Scopes; Claude-Code-Abnahme der neuen Werkzeuge
## Checkpoint 26.10.2026 (Backend-Lücken PWA Etappe 2)
- [x] activity_events aus Task-/Planungs-/Agentenrouten; Kommentar-/Aktivitätsnamen; eingeschränkte Nutzersuche; Teamname in Einladungen; Planungsdaten in `GET /v1/tasks` (Details in STATUS). SQLite + MariaDB grün.
- [ ] PWA auf neue Felder umstellen; Projekt-/Freigabe-Ereignisse (eigenes Modell) konzipieren; UI zum Ausstellen von Recovery-Codes.

## Sync-Strang (26.10.2026)
- [x] Backend: Änderungsfeed mit Cursor, Tombstones, idempotente Mutationen mit 409 (ADR 0009, `contracts/sync.yaml`); SQLite und MariaDB grün (88 Tests).
- [x] Zugriffsänderungen (Freigabe/Entzug/Verschieben) als Feedereignisse (27.10.2026, SQLite geprüft; MariaDB 31.10.2026 grün).
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
- [x] (MariaDB-Volllauf 31.10.2026 grün) Nächster Schritt: MariaDB-Konkurrenzabnahme, danach Clients anbinden und Vergleichskosten messen. Linux und echte Clients in diesem Auftrag ungeprüft.

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
- [x] PWA: `localStorage`-Provisorien auf die neuen Endpunkte umgestellt (Favoriten, Beschreibung, Farbe, Anzeige, Sortierung per Drag-and-drop, Projektkommentare, Aktivität, Geräte-/Auftragsliste), Altimport; Details in STATUS „PWA an Projektzustand angebunden“.
- [ ] Apple: dieselben Verträge (`project-state.yaml`) und Board anbinden; PWA: Binding anlegen/Gerät widerrufen/Auftrag freigeben im UI.
- [ ] Optional: Projektkommentare/-aktivität in Sync-Feed und MCP.

## Checkpoint 30.10.2026 (Anhänge in der Datenbank)
- [x] S3 optional, Anhänge standardmäßig in der DB (ADR 0013), `migrate-storage`, Infrastruktur/Docs ohne S3-Pflicht; SQLite + MariaDB grün (siehe STATUS).
- [ ] Offen: S3-Test und `migrate-storage` gegen S3Mock (`docker compose --profile s3 up -d s3`, `S3_ENDPOINT=http://localhost:29090 S3_BUCKET=todo-attachments`), Swarm-Smoke erneut ausführen, bei Bedarf Streaming-Download für größere Limits.

## Steuerzentrale für Agenten (30.10.2026, ADR 0014)
- [x] Backend + MCP: Handbuch, Briefing, Fragen, Fortschritt/Features, Reviews, Build-Screenshots, `GET /v1/command-center`.
- [x] PWA: Seite "Überblick" (30.10.2026): Kanban/Liste, Konto- und Projektscope, Fragen/Reviews direkt entscheiden, Updates, offene Fragen, Briefing-Editor, Standard-Spalten, Build-Vorschau (Details STATUS). Offen: Galerie über alle Builds (`builds[]` der Antwort ungenutzt), Konsole für Features/Unteraufgaben-Anlage in der PWA.
- [ ] Apple: dieselben Ansichten (Vertrag `contracts/command-center.yaml`). Consent-Oberfläche für Scope `attachments:write`.
- [ ] Optional: Sync-Feed/Push für Fragen und Reviews; SQL-Voraggregation.

## Checkpoint 30.10.2026 (PWA im Image)
- [x] PWA im Backend-Image ausgeliefert (ADR 0015), Tests und E2E gegen das Image grün. Offen: Rollout auf dem Server per `update.sh`.

## Checkpoint 30.10.2026 (OAuth-/MCP-Issuer, ADR 0016)
- Fehler: Produktion lieferte in der gesamten OAuth-/MCP-Discovery `http://localhost:28080`, weil `OAUTH_ISSUER` nirgends gesetzt wurde. Fix: `AppSettings.oauthIssuer`/`oauthResource` (OAUTH_ISSUER, sonst RP_ORIGIN wenn nicht loopback, sonst Dev-Standard), Logwarnung bei Loopback-Issuer in `--env production`; `stack.yaml`, `stack.env.example`, `setup.sh` angepasst; alte Env-Dateien mit nur `RP_ORIGIN` funktionieren ohne Änderung. Details und Sofortmaßnahme: ADR 0016, BETRIEB.md (Abschnitt OAuth-/MCP-Issuer).
- Tests: `OAuthIssuerTests` (SQLite) plus bestehende Suite (161 Tests, 0 Fehler). Real geprüft: lokales Image in isoliertem Compose-Projekt `todo-issuerchk` (eigene Ports, `RP_ORIGIN=https://todo.example.test`, danach `down -v`): Discovery, `WWW-Authenticate`, DCR, authorize (PKCE S256, `resource`) mit Consent per Sitzungs-Bearer (Sitzung per SQL angelegt, kein Passkey), `iss` im Redirect, token (falsche Resource localhost: 400), `POST /mcp tools/list` mit Bearer: 29 Tools. Grenzen: kein echter MCP-Client, kein TLS/Reverse Proxy.
- Hinweis: Docker-VM war voll (0 Byte frei); `docker builder prune` (nur Build-Cache) schaffte Platz.
- Offen: nach Rollout des neuen Images müssen Clients neu verbinden (alte Grants tragen die localhost-Resource).

## Checkpoint 31.10.2026 (Projekt-Onboarding Etappe 1, ADR 0018)

Gebaut: MCP-Prompts (setup_project, sync_project, session_start), Tabellen project_bindings und task_external_keys, Tools find_project_by_repository, create_project (Scope projects:write), bind_repository, record_sync, get_sync_status, get_stale_projects, import_plan (idempotent), list_plan_keys, set_agent_brief; Steuerzentrale mit projects[].sync und summary.staleProjects; REST GET/PUT /v1/projects/{id}/sync und GET /v1/projects/by-repository; Handbuch 1.1.0. Tests: ProjectSyncTests (Prompts, Normalisierung, Setup-Ablauf, Idempotenz, fresh/stale, Rechte/404) auf SQLite (Gesamtsuite) und MariaDB (gefilterte Suite, DB todo_test_onboard). Offen: Etappe 2 (Plugin/Hooks), Etappe 3 (Compose-E2E, Doku CLAUDE-CODE-EINRICHTUNG.md), PWA-Anzeige des Sync-Zustands.

## Checkpoint 31.10.2026 (Projekt-Onboarding Etappe 2: Claude-Code-Plugin)

Gebaut: `.claude-plugin/marketplace.json` (Marketplace `todolino`) und `claude-plugin/` (Plugin `todolino` 1.0.0): `.mcp.json` (HTTP, URL aus `userConfig.server_url`, Standard https://todo.linolaske.de/mcp), Skills `todolino`, `setup`, `sync`, Hooks SessionStart/PostToolUse(git commit)/Stop als POSIX-sh-Skripte (kein Netz, fail-open, Stop blockiert höchstens einmal je Sitzung, `stop_hook_active` und `TODOLINO_HOOKS_OFF` beachtet), Vorlage `templates/claude-md-section.md`. Geprüft: `claude plugin validate` (Plugin und Marketplace), Installation aus dem lokalen Repo in temporärem `CLAUDE_CONFIG_DIR` (Skills 3, Hooks 3, MCP-Server `plugin:todolino:todolino` meldet "Needs authentication" gegen den echten Server), `claude-plugin/tests/test-hooks.sh` (22 Prüfungen). Nicht geprüft: Hooks im laufenden Claude-Code-Lauf (Login nötig), interaktiver OAuth-Flow der CLI.

## Sync-Aufbewahrung, Kontolöschung, Cleanup-Scheduler (31.10.2026, ADR 0019)
- [x] `SYNC_RETENTION_DAYS` (90): Tombstones/ersetzte Upserts/Mutationsergebnisse; Boden in `sync_counter`; 410 `cursor_expired`; Vertrag sync.yaml 1.3.0
- [x] Kontolöschung mit Tombstones (`App delete-account`), Tests SQLite
- [x] `CleanupScheduler` mit `maintenance_leases` (`CLEANUP_INTERVAL_MINUTES`, 360, 0 = aus), `/health/ready` informativ
- [x] (31.10.2026 MariaDB-Volllauf grün, Rest siehe Text) MariaDB-Läufe der neuen Tests (`SyncRetentionTests`) nachholen, falls im Checkpoint offen; Client-Seite (PWA/Apple): 410 `cursor_expired` behandeln = lokalen Cache des Kontos verwerfen, ab `c0` neu laden
- [ ] Selbstbedienungs-Route zur Kontolöschung (bisher nur CLI)

## Checkpoint 31.10.2026 (Dokumentation und Projektseite konsolidiert)
- [x] README neu gegliedert (Überblick, Schnellstart, Betrieb mit `deploy`-Branch, Claude-Code-Einrichtung, Status und Grenzen, Links). docs-site: neue Seiten Steuerzentrale, Projekt-Onboarding/Plugin, Sync-Aufbewahrung, Runner (Link ins Apple-Repository), Installation ohne Quellcode, Agentenhandbuch; Startseite und Screenshots-Seite mit den Steuerzentrale-Bildern. `docs/STATUS.md` beginnt mit der Zusammenfassung „Aktueller Stand (31.10.2026)“. `contracts/oauth-mcp.yaml`: Scope-Liste quotiert, damit auch YAML-1.1-Parser (Ruby) die Datei laden.
- [ ] Nächste Schritte stehen in der Tabelle in STATUS.md: Docker-Platz, MariaDB-Volllauf und Playwright-Läufe, Plugin in echter Claude-Code-Sitzung, Account-Wechsel prüfen, TestFlight, Rollout per `update.sh`, Empfehlung Widgets/App Intents.

## Sync: Planung und Labels (31.10.2026, ADR 0020)
- [x] `task.planning`, `label.*`, `task.label_add/remove`, Feed-Planung und Entität `label`, sync.yaml 1.4.0, Tests SQLite
- [x] (31.10.2026 MariaDB-Volllauf grün, Rest siehe Text) MariaDB-Lauf `SyncPlanningLabelTests` nachholen (Docker-Platz); Apple-Outbox auf die neuen Mutationen umstellen

## APNs-Push (31.10.2026, ADR 0021)
- [x] Backend: Geräte, Einstellungen, Outbox, Worker mit Lease, ES256-JWT, Sender mit Backoff/Widerruf, Trigger Erinnerung/Frage/Review/Kommentar, `push-test`, Health-Info, Vertrag `contracts/push.yaml`, Tests SQLite (14), Deploy-Overlay/`setup.sh`/Doku (`docs/PUSH-EINRICHTUNG.md`).
- [ ] Nutzer: APNs-Schlüssel anlegen, Secret `todo_apns_key`, `stack.env`, `update.sh --force`, `push-test` (erster echter Apple-Versand, bisher ungeprüft).
- [ ] Apple-Client: `POST /v1/push/devices` bei jedem Start (Umgebung sandbox bei Debug, production bei TestFlight/App Store), Entitlement, Berechtigungsabfrage, Deep-Links, Einstellungen (`/v1/me/push-prefs`), optional Notification Service Extension.
- [x] (31.10.2026 MariaDB-Volllauf grün, Rest siehe Text) MariaDB-Lauf `PushTests` nachholen (Docker-Platz). Später: Web-Push (VAPID), Zuweisungs-Push, Ruhezeiten.

## Checkpoint 31.10.2026 (APNs-Testknopf und Mailversand, ADR 0024)

**Gebaut (Backend):** `POST /v1/push/test` (eigene Geräte, generische Nachricht, Ergebnis je Gerät `sent|failed|revoked` ohne Token, `409 push_disabled`, 1 Test je 10 s). Mailversand: eigener SMTP-Client auf SwiftNIO/NIOSSL (`Sources/TodoKit/Mail/`, STARTTLS/TLS, AUTH PLAIN/LOGIN, Timeouts, keine neuen Fremdpakete; swift-nio/-ssl nur direkt deklariert), `MailConfig` (`MAIL_ENABLED`, `SMTP_*`, `SMTP_PASSWORD_FILE`, `MAIL_FROM[_NAME]`, Startvalidierung), Tabellen `user_emails`, `email_verifications`, `mail_outbox` (Migration `CreateMailSchema`), Worker mit Lease/Backoff/Dedupe, Double-Opt-In (`/v1/me/email`, `/v1/email/confirm`), Test-Mail, Recovery-Code per Mail (`sendEmail` an `POST /v1/identity/accounts/{id}/recovery`, Klartext mit Warnhinweis, siehe ADR 0024), `/health/ready` mit `mail`. **PWA:** Karten „Benachrichtigungen“ (Serverstatus, Geräte mit Widerruf, Kategorien, Testknopf mit Ergebnis) und „E-Mail“ (Adresse, Bestätigung, Test-Mail, Status) unter Konto > Allgemein, Haken „per E-Mail senden“ im Recovery-Formular, Seite `/confirm-email`, Prefill auf `/recover#code=`. **Deploy/Doku:** `stack.mail.yaml`, `stack.env.example`, `setup.sh` Schritt E-Mail (shellcheck ohne Warnungen), deploy-Branch-Workflow, `docs/MAIL-EINRICHTUNG.md`, `PUSH-EINRICHTUNG.md` (Testknopf), `BETRIEB.md`, `contracts/mail.yaml`, `push.yaml`, `identity.yaml`, ADR 0024, docs-site-Seite.
**Geprüft:** SQLite `MailTests` + `SMTPClientTests` (33 Tests: Konfig, Format, Bestätigung, Enumerationsschutz, Rate-Limits, Outbox/Lease/Backoff/Dedupe/Ablauf, Recovery-Mail, Push-Test, SMTP-Dialog gegen Fake-Server) grün; vitest, svelte-check 0 Fehler, build grün; Playwright `e2e/mail.spec.ts` (Chromium, natives SQLite-Backend, lokaler SMTP-Sink `web/scripts/smtp-sink.py`, gefälschter APNs-Schlüssel) 3/3: Push-Karte inkl. Testknopf, Bestätigung, Test-Mail, Recovery-Mail, mobil 390 px. docs-site-Build ohne Warnungen.
**Nicht geprüft:** echter SMTP-Anbieter, echter APNs-Versand, MariaDB, Firefox/WebKit. **Offen:** Einladung per Mail (Einladungen haben keine Empfängeradresse), Benachrichtigungs-/Zusammenfassungsmails.

## Checkpoint 31.10.2026 (PWA: Einstellungs-Hub, Hilfe, Verwaltung)

Gebaut und geprüft: siehe STATUS (gleicher Titel) und [VERWALTUNG.md](VERWALTUNG.md). Erledigt: PWA-Seite „Claude Code verbinden“ (`/hilfe/claude-code`, auch unter `/einstellungen/mcp`), Hilfemenü, Benutzermenü, Verwaltungsbereich (nur Lesen/Erzeugen, was das Backend bietet). Offen (Backend, priorisiert): 1 Kontenliste/Sperren/Löschen, 2 Einladungsliste und Datenexport/Konto löschen, 3 Profil bearbeiten, 4 Mail-/Versionsanzeige, 5 APNs/Speicher in der Oberfläche, 6 Änderungsprotokoll, persönliche API-Tokens.

## Checkpoint 31.10.2026 (Konfiguration über die PWA, Backend)

Siehe STATUS.md (gleicher Titel) und ADR 0025. Backend, Vertrag `contracts/admin-settings.yaml`, `docs/KONFIGURATION.md`, Deploy-Anpassungen und 16 Tests sind fertig (SQLite; MariaDB ungeprüft). **Nächster Schritt:** PWA-Verwaltungsbereich im Hub (`/einstellungen/verwaltung/<kategorie>`), generiert aus `GET /v1/admin/settings`, mit Playwright (Admin vs. Nicht-Admin, Mail-Test gegen smtp-sink) und Screenshots; danach Image-Tag prüfen und dem Nutzer die Schritte (Migration, optional Konfigurationsschlüssel, Env-Variablen entfernen, die in der PWA änderbar sein sollen) nennen.
