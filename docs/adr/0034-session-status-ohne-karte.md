# ADR 0034 – Session-Status (Heartbeat) ohne geclaimte Karte und Übersicht "Jetzt"

Status: Backend umgesetzt (17.11.2026, Karte `F6DF71C3`, Stufe 1). Clients und Plugin-Hook folgen.

## Kontext

Die Live-Ansicht (ADR 0031) hängt an einer Karte. Arbeitet ein Agent ohne Karte (Recherche, Aufräumen, neues Thema), sieht niemand, dass er aktiv ist. Außerdem fehlt ein gebündelter Blick "was passiert gerade" über alle Projekte.

## Entscheidung

1. **Leichter Status je (Konto, Projekt, Sitzungsname)** in `session_statuses` (Upsert, kein Verlauf): ein Satz, höchstens 300 Zeichen, durch den vorhandenen `SecretFilter`. Kein Transkript, nur der letzte Stand.
2. **Melden** über MCP `report_session_status` (Scope `tasks:write`) und REST `PUT /v1/projects/{id}/session-status`; ein Fachpfad `SessionStatusService`. Rolle edit am Projekt, bei OAuth zusätzlich Projekt im Grant. Nicht lesbar: 404; lesbar ohne Schreibrolle: 403 (wie `ProjectAccess` überall).
3. **Rate-Limit:** höchstens ein Schreibvorgang je 10 s je (Konto, Projekt, Sitzungsname), geprüft über `updated_at` (kein Zähler, keine Zusatztabelle; Millisekunden). Höchstens 20 Sitzungen je Konto und Projekt gegen Müllnamen. Parallele Erstmeldungen löst der Unique-Key; die Verlierer bekommen 429.
4. **Lesen:** `GET /v1/overview/now` und MCP `get_overview_now` (`tasks:read`) über `OverviewNowService`: je lesbarem Projekt (`ProjectAccess.visibleProjects`, bei MCP geschnitten mit dem Grant) laufende Karten, Heartbeats (verwaist nach 30 min, ausgeblendet nach 24 h), aktive Agentenaufträge, Builds, offene Fragen, ausstehende Reviews, letzte 10 Aktivitätsereignisse; nach letzter Aktivität sortiert. Fremd- und Kundenprojekte erscheinen nur, wenn lesbar.
5. **Live ohne Polling:** `SessionStatus` hängt an der `live_events`-Middleware (Hinweiszeile mit Projekt-ID als `ref_id`). `wait_for_events` liefert daraus einen projektbezogenen Hinweis `progress` ohne `taskID` für lesbare Grant-Projekte. Aus dem Karten-Hinweisfilter `taskHints` ist `session_statuses` ausgenommen.

## Nachtrag 18.11.2026: Felder für die PWA-Seite "Jetzt" (Vertrag 1.1.0, Handbuch 1.33.0)

Additiv und optional: `runningTasks[].percent` (Prozent der letzten Fortschrittsnotiz der Karte, die einen Prozentwert trug) und `builds[].commit` (buildID, wenn sie wie ein Commit-Hash aussieht: 7 bis 40 Hex-Kleinbuchstaben). Bewusst kein Build-/CI-Status und keine Migration; im Datenmodell gibt es dafür keine Quelle (`build_artifacts` kennt nur buildID, Label, Plattform).

## Nachtrag 18.11.2026: Build-Status und expliziter Commit (Vertrag 1.2.0, Handbuch 1.34.0)

Entscheidung des Orchestrators: `register_build` (und REST `POST /v1/builds`, derselbe `WorkflowService.registerBuild`) bekommt optional `status` (building | succeeded | failed) und `commit`. Additive Migration `AddBuildStatusCommit` (zwei nullable Spalten in `build_artifacts`, je ein ALTER). Idempotenz bleibt: derselbe Aufruf mit anderem Status aktualisiert ihn und schreibt die Aktivität `build.status_changed` (Live-Hinweis über die bestehende Live-Middleware); ohne `status` bleibt ein vorhandener Status unverändert. `OverviewNow.Build` zeigt `status` (fehlt, wenn nie gemeldet) und `commit` (explizit, sonst wie bisher aus der buildID). Der Satz "bewusst kein Build-/CI-Status" oben gilt damit nur für 1.1.0. Grenzen: Der Status kommt nur von register_build; der Upload-Weg begin/complete_attachment kennt ihn nicht (danach register_build mit status aufrufen). Der Feed (`FeedService`) zeigt `build.status_changed` nicht.

## Folgen und Grenzen

- Aufbewahrung: Zeilen werden nicht aktiv gelöscht; nach 24 h sind sie in der Übersicht unsichtbar, Projekt-/Kontolöschung löscht per Kaskade. Ein Aufräumschritt im `ExpiredCleanup` ist nicht Teil von Stufe 1.
- Der Melder selbst erhält über `wait_for_events` ebenfalls den Projekt-Hinweis zu seiner eigenen Meldung (die Hinweiszeile kennt keinen Absender); das Live-Token ändert sich ohnehin bei jeder Meldung. Ein Absenderfilter bräuchte eine Spalte in `live_events`.
- Die Übersicht lädt je Projekt zwei begrenzte Abfragen (Builds, Aktivität); bei sehr vielen Projekten ist das N+1 und müsste später gebündelt werden.
- Migration `CreateSessionStatuses` ist additiv.
