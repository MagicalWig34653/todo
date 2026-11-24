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

## Nachtrag 18.11.2026: Build-Status in Ereignissen und Feed (Vertrag 1.3.0, Feed 1.1.0, Handbuch 1.35.0)

`OverviewNow.Event` bekommt optional `label`, `platform`, `status`, nur fuer `build.added` und `build.status_changed` (aus dem `BuildArtifact` ueber `subjectID`; es ist der aktuelle Stand des Builds, nicht der zum Ereigniszeitpunkt). Der Feed (`FeedService`) liefert `build.status_changed` jetzt als Post kind `build` mit `text` = Label (sonst Build-ID), `status`, `platform` (additive Felder in `FeedPostDTO`, nil fehlt im JSON). Je Statuswechsel ein eigener Post ohne Bilder; keine Zusammenfassung mit `build.added`. Keine Migration. Der Satz "Der Feed zeigt build.status_changed nicht" im Nachtrag davor gilt damit nur fuer 1.2.0. Grenze: da der Status der aktuelle ist, zeigen aeltere Statusereignisse desselben Builds denselben (neuesten) Status.

## Nachtrag 24.11.2026: Block "now", kompakte Antwort, Sitzung beenden, Aufräumen (Vertrag 1.4.0, Handbuch 1.40.0, Karte 692891DF)

Ziel: Agenten und die PWA sollen mit einem Aufruf sehen, was gerade läuft, worauf gewartet wird und was erledigt ist, ohne die große Projektliste zu lesen. Alles additiv, keine Migration.

**Block `now`** (`OverviewNow.now`, immer gefüllt in REST und MCP, in der vollen Antwort höchstens 100 Einträge je Liste, `counts` sind die Gesamtzahlen vor dem Kürzen):

- `running`: Karten mit Status `in_progress` und Lebenszeichen höchstens 30 Minuten sowie Sitzungsstatus mit `updatedAt` höchstens 30 Minuten. `silent`: Karten in Arbeit ohne Lebenszeichen der letzten 30 Minuten und Sitzungen von 30 Minuten bis 24 Stunden Alter. Beide Listen: jüngstes Lebenszeichen zuerst (bei Gleichstand nach Titel).
- Lebenszeichen einer Karte: dieselbe Berechnung wie das Verwaist-Kennzeichen (`ClaimLiveness.lastSignOfLife`: Claim, Fortschrittsnotiz, Kommentar, Aktivitätsereignis, Runner-Ereignis) plus `last_seen_at` der Live-Ansicht der Karte (ADR 0031). Eine Karte in Arbeit ganz ohne Lebenszeichen ist `silent`; als `lastSignAt` steht dann der Beginn des Claims bzw. die letzte Änderung der Karte.
- Sitzungen, deren `activity` (nach Trim, ohne Beachtung der Groß-/Kleinschreibung) mit "Beendet" beginnt, erscheinen weder in `running` noch in `silent`. `projects[].sessions` bleibt unverändert (zeigt sie weiter, verwaist nach 30 Minuten, ausgeblendet nach 24 Stunden).
- `waiting`: offene Fragen (`open`) und ausstehende Reviews (`pending`) aller lesbaren Projekte, neueste zuerst, Text einzeilig und höchstens 200 Zeichen. Wie bei `openQuestions`/`pendingReviews` ohne Filter auf erledigte Karten.
- `recentlyDone`: Karten mit Status `done`, deren Zeitpunkt der letzten Änderung (`updated_at`) höchstens 6 Stunden zurückliegt, neueste zuerst. Es gibt kein eigenes Erledigt-Datum und kein Aktivitätsereignis mit dem Zielstatus (`task.status_changed` nennt ihn nicht); die Quelle ist dieselbe wie bei der Erledigt-Spalte der Steuerzentrale. Grenze: Wird eine erledigte Karte später bearbeitet (Titel, Beschreibung, Spalte), rückt `doneAt` nach vorn; eine wieder geöffnete Karte fällt heraus.
- Rechte unverändert: `ProjectAccess.visibleProjects`, bei MCP geschnitten mit dem Grant. Fremdes bleibt unsichtbar.

**Kompakt:** REST `GET /v1/overview/now?compact=true&limit=N` und MCP `get_overview_now {compact, limit}` liefern nur `{serverTime, now}` (ohne `projects`; die Abfragen für Aufträge, Builds und Aktivität entfallen), jede Liste auf `limit` gekürzt (Standard 10, 1 bis 50, sonst 400 `invalid_limit`, auch ohne `compact` geprüft), Texte, Titel und Projektnamen auf 140 Zeichen mit "…". Das Handbuch empfiehlt `compact=true` für Agenten.

**Sitzung beenden:** `ended: true` an `PUT /v1/projects/{id}/session-status` und `report_session_status` löscht die Zeile (Modell-Löschung, also meldet die Live-Middleware den Projekt-Hinweis und ändert das Live-Token wie bei einer Meldung; wurde nichts gelöscht, bleibt das Token). Idempotent (unbekannter Name 200), kein 10-s-Limit, gleiche Rechte wie das Melden (edit, Grant; 404/403 wie sonst), Antwort mit `ended: true` und leerem `activity`; `activity` ist dann nicht nötig, ohne `ended` weiter Pflicht (400 `invalid_activity`). Das Löschen schafft Platz gegen `too_many_sessions`. Gelöscht wird nur die eigene Zeile (Schlüssel Konto, Projekt, Name).

**Aufräumen:** `ExpiredCleanup` (`cleanup-expired`, Scheduler) löscht Zeilen mit `updated_at` höchstens 24 Stunden vor dem Lauf, genau die in der Übersicht ausgeblendeten (`Report.sessionStatuses`).

**Grenzen:** (1) `silent` und `running` lesen bis zu 1000 Karten in Arbeit (die `runningTasks` je Projekt wie bisher 300); darüber fehlen die ältesten. Fortschrittsnotizen werden für Text und Prozent aus den neuesten 2000 Notizen gelesen (wie schon `runningTasks`). (2) `counts.waiting` und `counts.recentlyDone` kommen aus eigenen Zählabfragen, `counts.running`/`silent` aus den geladenen Karten und höchstens 500 Sitzungen. (3) Der Block kennt keine Teams oder Rollen über die Lesbarkeit hinaus; Sitzungen anderer Personen in geteilten Projekten erscheinen wie bisher mit. (4) Ein Agent, der abstürzt, beendet seine Sitzung nicht; sie wird nach 30 Minuten `silent`, nach 24 Stunden unsichtbar und gelöscht.

## Folgen und Grenzen

- Aufbewahrung: nach 24 h sind Zeilen in der Übersicht unsichtbar; Projekt-/Kontolöschung löscht per Kaskade. Stufe 1 löschte sie nicht aktiv, seit dem Nachtrag 24.11.2026 tut es `ExpiredCleanup`; eine Sitzung lässt sich mit `ended: true` sofort beenden.
- Der Melder selbst erhält über `wait_for_events` ebenfalls den Projekt-Hinweis zu seiner eigenen Meldung (die Hinweiszeile kennt keinen Absender); das Live-Token ändert sich ohnehin bei jeder Meldung. Ein Absenderfilter bräuchte eine Spalte in `live_events`.
- Die Übersicht lädt je Projekt zwei begrenzte Abfragen (Builds, Aktivität); bei sehr vielen Projekten ist das N+1 und müsste später gebündelt werden.
- Migration `CreateSessionStatuses` ist additiv.
