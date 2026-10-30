# ADR 0014 – Steuerzentrale: Agenten arbeiten über das Kanban-Board (Handbuch, Fragen, Fortschritt, Reviews, Build-Screenshots)

Status: Backend und MCP implementiert (30.10.2026); PWA angebunden (30.10.2026, siehe STATUS), Apple noch nicht. Vertrag: `contracts/command-center.yaml`. Handbuch für Agenten: `docs/agent-manual.md`.

## Anlass (Nutzeranforderung, Kernzweck des Produkts)

Bisher muss der Nutzer jedem seiner Coding-Agenten von Hand Eingaben und Entscheidungen geben. Das soll vollständig über die Projektverwaltung laufen, als **Kanban-Board**:

- Agenten holen sich per MCP Bedienungsanleitung und Konventionen und bedienen MCP/Funktionen damit korrekt.
- In der App gibt es eine **Steuerzentrale** („Überblick“): laufende Features mit Fortschritt, **alle offenen Fragen** im Projekt/Konto, Build-Screenshots, fällige Reviews und Updates – standardmäßig als Kanban, optional als Liste.

Dieser ADR legt Datenmodell, API und MCP-Werkzeuge fest. Clients entstehen danach.

## Entscheidungen

### 1. Handbuch und Konventionen (versioniert, maschinen- und menschenlesbar)

- Quelle ist **`docs/agent-manual.md`** (Englisch, für Agenten; UI-Texte bleiben Deutsch). Erste Zeile `<!-- manual-version: X.Y.Z -->`. `## `-Überschriften sind Abschnitte (`section`-ID = Slug). Das Handbuch wird beim Build eingebettet (`Sources/TodoKit/MCP/AgentManualContent.swift`, erzeugt mit `scripts/embed-agent-manual.sh`; ein Test schlägt fehl, wenn die eingebettete Fassung veraltet ist). Begründung: Das Docker-Image kopiert nur `Sources`/`Tests`; SwiftPM-Ressourcen würden Bundle-Pfade auf Linux erzwingen.
- Zugriff: MCP-Werkzeug **`get_manual {section?}`** (ohne Scope, jede gültige Freigabe), MCP-Ressourcen `todo://manual` (Markdown) und `todo://conventions` (JSON), REST `GET /v1/manual` (öffentlich, enthält keine Nutzerdaten). Antwort: `{version, sections, content, conventions}`; `conventions` ist die strukturierte Fassung (Lanes, Spaltenvorlage, Status, Frage-/Review-Zustände, Anhangsrollen, Limits).
- **Abdeckungstest**: Das Handbuch muss jeden registrierten MCP-Werkzeugnamen nennen; jedes Werkzeug braucht eine Beschreibung (≥ 40 Zeichen) und jedes Eingabefeld eine `description`. Neue Werkzeuge ohne Dokumentation lassen die Tests fehlschlagen.
- Das MCP-`initialize`-Ergebnis trägt `instructions` („Rufe zuerst `get_manual` auf“) und `capabilities.resources`.
- **Projekt-Briefing (`agent brief`)**: Tabelle `project_agent_briefs` (eine Zeile je Projekt: `text` Markdown ≤ 20 000 Zeichen, `version`, `updated_by`, `updated_at`). Der Nutzer pflegt dort Beschreibung/Ziele/Randbedingungen/Definition of Done („Regeln des Projekts“); empfohlene Überschriften `Goals`, `Constraints`, `Definition of done`, `Agent rules`. Lesen `read`, Schreiben **`manage`** (die Anweisungen steuern Agenten, deshalb nicht für Kommentatoren/Bearbeiter), optimistische `version` (0 = neu). `get_project_structure {projectID}` (REST `GET /v1/projects/{id}/structure`) liefert Beschreibung, Briefing, Spalten (+ erkannte Rollen), Zähler und welche Spalten der Standardvorlage fehlen.
- **Standard-Spaltenvorlage „agent_workflow“**: Backlog, Bereit, In Arbeit, Frage offen, Review, Erledigt (`isDone`); anlegbar mit `POST /v1/projects/{id}/columns/template {"source":"agent_workflow"}` bzw. MCP `apply_agent_workflow_columns`. Spaltenrollen werden **über den Namen** erkannt (Groß-/Kleinschreibung egal; Aliasse im Handbuch), damit auch eigene Boards funktionieren. Workflow-Werkzeuge verschieben Karten in die passende Spalte, **falls vorhanden**; fehlt sie, bleibt die Karte stehen (der Zustand liegt nie nur in der Spalte).

### 2. Fragen als eigene Objekte

- Tabelle `task_questions`: `task_id` (FK, Kaskade), Fragender (`asked_by_type` Person/Integration/Run, `asked_by_id`, `asked_by_label`), `prompt`, `options` (JSON), `blocking`, `state` (`open|answered|withdrawn`), `answer`, `answered_by`, `answered_via` (`rest|mcp|runner`), `answered_at`, `created_at`, `agent_question_id` (Verweis auf `agent_questions`), `idempotency_key`, `version`.
- **Wiederverwendung statt Duplikat**: Der Rückfragefluss der Runner-Aufträge (`agent_questions`/`agent_answers`, Auftragszustand `waiting_for_answer`) bleibt maßgeblich für den Auftrag. `AgentService` spiegelt jede Runner-Frage in `task_questions` (mit `agent_question_id`, `blocking=true`) und jede Antwort zurück; Abbruch/Fehlschlag/`stopped` setzt offene Spiegel auf `withdrawn`. Antworten auf eine gespiegelte Frage über die neue API werden an `AgentService.answer` delegiert (gleiche Regeln: Projekteigentümer, Optionsprüfung, Auftrag muss warten). Frei gestellte Fragen (MCP-Agenten ohne Runner) leben nur in `task_questions`.
- Regeln: Fragen stellen = `edit`; beantworten = `comment` bei freien Fragen; Antwort muss eine Option sein, sofern Optionen vorhanden. Nur eine Antwort: zweite abweichende Antwort 409 `question_already_answered`; gleiche Antwort desselben Kontos idempotent. Ein MCP-Grant darf eine **selbst gestellte** Frage nicht beantworten (403 `cannot_answer_own_question`) – der Mensch bleibt in der Schleife; Menschen antworten über REST/App. `idempotencyKey` beim Stellen (gleicher Text → gleiche Frage, anderer Text → 409).
- Aktivitätsereignisse (Aufgabenverlauf): `question.asked`, `question.answered`, `question.withdrawn`; Subjekt = Frage-ID. Aggregat: `GET /v1/questions?projectID=&state=` (konto-/projektweit, nur lesbare Projekte), MCP `list_open_questions`, `get_question`.

### 3. Fortschritt und „Feature“

- Es gab weder Unteraufgaben noch Aufgabenarten. Minimale Ergänzung: Tabelle **`task_workflow`** (eine Zeile je Aufgabe, lazy; `id` = Aufgaben-ID, FK Kaskade): `kind` (`task|feature`), `parent_task_id` (FK `SET NULL`), `blocked_reason`, `claimed_by_type/_id/_label`, `claimed_at`. `tasks` bleibt unverändert (kein Eingriff in Sync/Schema).
- **Feature** = Aufgabe mit `kind=feature` **oder** mit mindestens einer Unteraufgabe. Unteraufgabe = `parent_task_id` auf eine Aufgabe **desselben Projekts**; Tiefe höchstens 2 (Eltern haben kein Elternteil, Aufgaben mit Kindern bekommen keins) – Zyklen sind dadurch ausgeschlossen.
- **Fortschritt (Prozent 0–100) mit Quelle**: `done` → 100 (`status`); sonst Unteraufgaben erledigt/gesamt (`subtasks`); sonst Akzeptanzkriterien erledigt/gesamt (`criteria`, bestehende Tabelle); sonst letzter Prozentwert einer Fortschrittsnotiz (`agent`); sonst 0 (`none`). Zusätzlich liefert der Rollup die jüngste Notiz, den jüngsten Checkpoint des Runners (`nextStep`) und Zähler.
- Fortschrittsnotizen: Tabelle `task_progress_notes` (Akteur, Label, `note` ≤ 4000, `percent` 0–100 optional, `created_at`); Ereignis `progress.posted`. Runner-Fortschritt (`agent_jobs.progress`) und Checkpoints werden zusätzlich gelesen, nicht kopiert.
- Ein Claim (`claim_task`) setzt Status `in_progress`, den Bearbeiter (Label) und – falls vorhanden – die Spalte „In Arbeit“. Zweiter Claim durch einen anderen Akteur → 409 `already_claimed` (außer `takeOver=true`). Freigabe `release_task`.
- Blockiert: `blocked_reason` (frei) oder offene Abhängigkeit (`planning_dependencies`, Voraussetzung nicht erledigt).

### 4. Reviews

- Tabelle `task_reviews` (Verlauf): `state` (`pending|accepted|changes_requested|withdrawn`), Anforderer, `reviewer_id` (optional: wer prüfen soll), `summary`, `decided_by`, `decided_at`, `decision_note`, `agent_job_id` (Runner-Verweis). Höchstens ein `pending` je Aufgabe (unter Aufgabenzeilensperre).
- **Verallgemeinerung**: `request_review` / `POST /v1/tasks/{id}/review` (edit) setzt Status `in_review`, legt eine `pending`-Prüfung an (Spalte „Review“). Der Runner-Fluss (`submit` → Auftrag `awaiting_review`) legt zusätzlich eine `pending`-Prüfung mit `agent_job_id` an (Aufgabenstatus bleibt unverändert, um die Revisionsprüfung der Aufträge nicht zu stören). Entscheidung `accept`/`request_changes` über `POST /v1/tasks/{id}/review/decision {decision, note}` (Rolle `edit`; ist `reviewer_id` gesetzt und der Entscheider ein anderer, ist `manage` nötig). Bei Runner-Prüfungen läuft die Entscheidung durch `AgentService.humanTransition` (Eigentümerfähigkeit, Auftragszustand) und aktualisiert die Prüfung in derselben Transaktion (die Aufgabe bleibt dabei unverändert, wie im bisherigen Runner-Fluss; die Person schließt sie). Bei nicht-runnerbasierten Prüfungen: `accept` → Aufgabe `done` (Spaltenabgleich wie überall), `request_changes` → `in_progress`; Ereignisse `review.requested`, `review.accepted`, `review.changes_requested`. Agenten dürfen eigene Anforderungen nicht selbst entscheiden (403 `cannot_decide_own_review`).
- Aggregat `GET /v1/reviews?projectID=&state=pending`, MCP `list_pending_reviews`.

### 5. Build-Screenshots

- Gespeichert werden sie über den bestehenden Anhangsdienst (Rolle `result`; dessen Interna bleiben unberührt, ein anderer Strang verlagert den Speicher in die Datenbank). Die Build-Metadaten stehen in **`build_artifacts`** (`attachment_id` unique, `task_id` FK Kaskade, `build_id`, `label`, `platform`, Ersteller, `created_at`). „Rolle build“ = Anhang `result` + Zeile in `build_artifacts`. Sichtbar erst, wenn der Anhang `complete` ist.
- MCP `add_attachment` (Base64, bis 5 MiB Rohdaten; PNG/JPEG/WebP/PDF; Prüfsumme/Magic-Bytes durch den Anhangsdienst) ruft intern `begin → upload → complete`. Größere Dateien: `begin_attachment` (liefert Upload-URL + Einmal-Token für `PUT`) und `complete_attachment`. Grund: `/mcp` sammelt höchstens 8 MiB Körper; das Anhangslimit der Instanz gilt unverändert.
- Gruppierung im Überblick: Karten tragen die jüngsten Build-Screenshots (`previewURL`); die Antwort enthält zusätzlich `builds` (nach `build_id` gruppiert, neueste zuerst).

### 6. Steuerzentrale: Aggregations-Endpunkt

`GET /v1/command-center?scope=account|project&projectID=&view=kanban|list&…` (Details im Vertrag). Alles wird aus den vorhandenen Tabellen **zur Anfragezeit** berechnet (kein Cache, replikasicher); Sicht = `ProjectAccess.visibleProjects()` bzw. `project(read)`; bei `scope=project` standardmäßig mit Unterprojekten (`includeSubprojects=true`). MCP: `get_command_center` (auf die Projekte des Grants beschränkt).

- **Lanes** (feste Schlüssel, Reihenfolge): `running` „Läuft“, `question` „Frage offen“, `review` „Review fällig“, `ready` „Bereit“, `blocked` „Blockiert“, `done` „Erledigt kürzlich“ (Standard 7 Tage, `doneWithinDays`). Zuordnung einer Karte in dieser Rangfolge: erledigt > offene Frage > Review (Status `in_review`, `pending`-Prüfung oder Spaltenrolle Review) > blockiert > läuft (Status `in_progress`, Claim/aktiver Lauf oder Spaltenrolle „In Arbeit“) > bereit (Status `open`, nicht in Spaltenrolle Backlog). Backlog-Karten erscheinen nicht, nur im Zähler `backlog`. Features: Lane aus dem dringlichsten Zustand von Feature und Unteraufgaben (Frage > Review > läuft > bereit); Unteraufgaben erscheinen verschachtelt (`subtasks`), in der Listenansicht mit `includeSubtasks` auch einzeln.
- **Karte**: Aufgabe, Projekt (Name/Farbe), Art, Fortschritt (Prozent+Quelle+Zähler), aktueller Agent/Lauf (Claim-Label; Auftragszustand nur für den Projekteigentümer – wie `get_progress`), Zähler und Vorschau offener Fragen, offene Prüfung, `blockedReason`, jüngste Aktualisierung (Notiz/Checkpoint), Build-Screenshots (≤ 3 + Anzahl), nächste Fälligkeit (`planning.due_at`).
- **Summary**: Zähler je Lane, `openQuestions`, `pendingReviews`, `backlog`, `features`, `activeAgents`. **Updates**: jüngste Fortschritts-/Fragen-/Antwort-/Review-/Build-/Agentenereignisse (`updatesLimit` ≤ 50) aus `activity_events`, mit aufgelöstem Text.
- **Listenansicht** (`view=list`): dieselben Karten flach, Filter `lane`/`kind`/`hasQuestion`, `sort=attention|updated|due|progress|title`, `limit`/`offset`.
- **Grenzen**: Pro Lane höchstens `laneLimit` (Standard 50, max 200) Karten, `count` zeigt die Gesamtzahl; die Berechnung lädt alle nicht lange erledigten Aufgaben der sichtbaren Projekte (bei Zehntausenden offenen Aufgaben später SQL-seitig voraggregieren). **Sync-Feed: nicht enthalten** (Aggregat wird serverseitig berechnet; Clients rufen den Endpunkt per Polling/Fokus ab; Offline-Schreiben dieser Objekte nicht gefordert). Aufgabenereignisse erscheinen im bestehenden `GET /v1/activity`.

### 7. MCP-Werkzeuge

Jedes Werkzeug hat Beschreibung und Feldbeschreibungen (Test). Neuer Scope `attachments:write` (Upload); alle anderen Schreibwerkzeuge laufen unter `tasks:write`, lesende unter `tasks:read`/`projects:read`/`attachments:read`; `get_manual` ohne Scope. Vollständige Liste und Schemas: Vertrag und Handbuch.

## Folgen

- Eine additive Migration `CreateCommandCenter` (neue Tabellen, keine Änderung an `tasks`/`projects`), MariaDB-sicher (TEXT für freie Texte). Vor Betrieb `App migrate --yes`.
- Änderungen an `AgentService` (Spiegelung von Fragen/Prüfungen) sind additiv; Runner-API und Auftragszustände bleiben unverändert.
- Der neue Scope `attachments:write` muss in der Consent-Oberfläche angezeigt werden; bestehende Grants behalten ihre Scopes (Upload-Werkzeuge fehlen dort).
- Offen: Clients (PWA/Apple), Sync-Feed für Fragen/Prüfungen, SQL-seitige Voraggregation bei sehr großen Konten, Benachrichtigungen bei neuen Fragen.
