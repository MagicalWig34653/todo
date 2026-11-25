# Plan Pipeline Stufe 3: Ausführung über den Runner (Karte F5DD1C00)

Folge von Stufe 2 (`docs/PLAN-PIPELINE-STUFE-2.md`). Gemeinsamer Vertrag für Backend, Mac-Runner (Apple-Repo, `TodoRunner/`) und PWA. Abweichungen im Code zuerst hier nachziehen. Rein additiv, kein Deploy.

## 0. Leitplanken

- **Alte Clients und Runner unverändert.** Neue Felder sind optional; bestehende Werte von `mode` (`clarify|implement`) und `state` bekommen keine neuen Ausprägungen. Pipeline-Aufträge sieht und übernimmt nur ein Runner, der sie anfragt.
- **Start nur durch das Startrecht** (`ProjectAccess.startAgent`, Projekteigentümer). Bearbeitungsrecht startet nie etwas.
- **Der Server bestimmt keine Befehle.** Validierungs- und Budget-Befehl sind ausschließlich lokal im Runner eingerichtet; sie verlassen den Mac nie, ebenso wenig Pfade und Befehlsausgaben.
- **Keine automatischen Wiederholungen.** Ein fehlgeschlagener Schritt läuft nur nach `retry` erneut (zählt als Fix-Runde, Grenze `maxFixRounds`).

## 1. Daten (Migration `CreatePipelineExecution`, additiv)

- Neue Tabelle `task_pipeline_executions`: `id` (vom Client, Idempotenz), `task_id` (unique, cascade), `project_id`, `binding_id`, `requested_by`, `state`, `reason?`, `step?`, `content_hash` (SHA-256 aus Titel + Beschreibung beim Start bzw. Fortsetzen), `accepted_plan_version?`, `created_at`, `updated_at`. Eine Zeile je Karte; ein neuer Start ersetzt eine beendete.
- `agent_jobs`: optionale Spalten `pipeline_execution_id`, `pipeline_step`.
- `runner_devices`: optionale Spalte `pipeline_seen_at` (Gerät hat schon einmal mit `?pipeline=1` angefragt).

## 2. Ausführung: Zustände

`state` der Ausführung: `running` (Auftrag wartet oder läuft) | `waiting_approval` | `blocked` (Schritt `failed`) | `paused` (braucht den Eigentümer) | `completed` | `stopped`. Aktiv = `running|waiting_approval|blocked|paused`.

`reason` (nur bei `paused`): `plan_needs_owner`, `task_changed`, `continue_required`; bei `blocked`: `step_failed` oder `fix_rounds_exhausted`.

`advance` (einzige Stelle, die Aufträge einreiht; läuft in der Transaktion des Auslösers, Aufgaben-Zeile gesperrt):

1. Keine aktive Ausführung oder es gibt schon einen offenen Auftrag dieser Ausführung (`queued|claimed|running|waiting_for_answer`) → nichts.
2. Planer an: Schritt `planner` `failed` → `blocked`. Kein Plan oder Plan `changes_requested` → Auftrag `planner`. Plan `proposed` → `waiting_approval`.
3. Danach in fester Reihenfolge `developer, validation, tester, review`, nur eingeschaltete: `done|skipped` überspringen; `failed` → `blocked`; sonst Auftrag für diesen Schritt (`running`).
4. Nichts mehr offen → `completed`.

Vor dem Einreihen eines Arbeitsschritts:
- **Vertrauen in den Plan** (nur bei eingeschaltetem Planer): erlaubt, wenn `accepted_plan_version` = aktuelle Version (gesetzt durch Freigabe/Start/Fortsetzen des Startberechtigten, durch eine Freigabe unter Brain-Vollmacht, oder weil der Planer-Auftrag dieser Ausführung bzw. der Startberechtigte selbst die Version geschrieben hat und die Freigabe ausgeschaltet ist). Sonst `paused`/`plan_needs_owner`.
- **Karteninhalt:** Hash aus Titel + Beschreibung weicht ab → `paused`/`task_changed`.

Auslöser: Start, Fortsetzen, Planentscheidung (beide Richtungen), Plan-Schreiben, Abschluss eines Pipeline-Auftrags, `retry`. `retry` durch eine Verbindung (kein Startrecht) reiht nichts ein: Ausführung wird `paused`/`continue_required`. `retry` durch eine Person ohne Startrecht ebenso.

## 3. REST (menschliche Sitzung, `contracts/pipeline.yaml` 1.2.0)

- `POST /v1/tasks/{id}/pipeline/execution` `{ "id": uuid, "bindingID": uuid }` → PipelineDTO. Startrecht (sonst 403); Bindung gehört zum Projekt der Karte und zum eigenen, nicht widerrufenen Gerät (404). Gleiche `id` mit gleichen Daten → bestehender Stand; abweichend 409 `execution_id_conflict`. Andere aktive Ausführung → 409 `execution_active`. Offener manueller Auftrag zur Karte stört nicht (Repository-Platz regelt der Claim). Alle Arbeitsschritte erledigt → 409 `nothing_to_run`. Ein beim Start vorhandener freigegebener Plan gilt als vom Startenden angenommen.
- `POST /v1/tasks/{id}/pipeline/execution/continue` `{ "planVersion": int? }` → Startrecht; aktive Ausführung (409 `no_execution`); `planVersion` ≠ aktuell → 409 `plan_changed`. Nimmt aktuellen Plan und Karteninhalt an, dann `advance`.
- `POST /v1/tasks/{id}/pipeline/execution/stop` → Startrecht; offener Auftrag wird wie bei `stop` abgebrochen, Schritt `running` → `pending` (keine Fix-Runde), Ausführung `stopped`. Wiederholt ohne aktive Ausführung 409 `no_execution`.
- `GET /v1/tasks/{id}/pipeline` zusätzlich `execution` (fehlt ohne Ausführung):

```json
{ "id": "UUID", "state": "running", "reason": null, "step": "developer", "bindingID": "UUID",
  "bindingLabel": "…", "deviceLabel": "…", "runnerSupportsPipeline": true,
  "jobID": "UUID|null", "jobState": "queued|…|null", "jobProgress": "Text|null",
  "createdAt": "…", "updatedAt": "…" }
```

Audit (Pipeline-Verlauf): `execution_started`, `execution_continued`, `execution_stopped`, `execution_completed`; Schrittänderungen des Runners als `step_changed` mit `actorType` `run`, Name „Runner“. Jede Änderung von Start/Fortsetzen/Stopp zusätzlich Karten-Aktivität `pipeline.execution`. Live-Hinweis wie die anderen Pipeline-Tabellen.

MCP: `start_pipeline_execution` (gleiche Rechte, Scopes und Prüfungen wie `start_agent_job`; Argumente `taskID`, `bindingID`, `executionID?`); Stand über `get_task_pipeline`. Kein MCP-Fortsetzen (Annahme durch den Eigentümer ist eine Personenentscheidung); Stoppen über das vorhandene Stoppen des Auftrags. Handbuch-Version erhöhen.

## 4. Runner-Protokoll (`contracts/agents.yaml` 1.3.0)

- `GET /v1/runner/jobs?pipeline=1` liefert zusätzlich Pipeline-Aufträge; ohne den Parameter nie. `POST /v1/runner/jobs/{id}/claim?pipeline=1`; Claim eines Pipeline-Auftrags ohne Parameter → 409 `pipeline_runner_required`. Beide setzen `pipeline_seen_at`.
- Job-DTO (alle Oberflächen) optional `pipelineStep` (`planner|developer|validation|tester|review`) und `pipelineExecutionID`. `mode`: `implement` für `developer` und `tester`, sonst `clarify`.
- Beim Claim eines Pipeline-Auftrags gilt statt der Aufgaben-Version der Inhalts-Hash (abweichend → Auftrag `cancelled`, Ausführung `paused`/`task_changed`, 409 `task_changed`); `taskRevision` wird auf den aktuellen Stand gesetzt. Schritt → `running`.
- `GET /v1/runner/jobs/{id}` zusätzlich (nur Pipeline-Aufträge):

```json
"pipeline": { "step": "developer", "planBody": "…|null", "planVersion": 1,
  "feedback": "Kommentar zu „Änderungen“ bzw. Notiz des Wiederholens|null",
  "model": "…|null", "effort": "…|null", "resumeSessionReference": "uuid|null" }
```

`resumeSessionReference`: letzter Checkpoint eines Auftrags derselben Ausführung **und Bindung** aus den Schritten `planner|developer`, nur für `planner` und `developer` (Entwickler setzt die Planer-Session fort). Tester und Review beginnen frisch.

- `submit` eines Pipeline-Auftrags: zusätzlich `outcome` (`passed|failed`, Pflicht, sonst 400 `outcome_required`) und beim Schritt `planner` mit `passed` `plan` (1 bis 20000 Zeichen, Pflicht, 400 `plan_required`). `result.summary` wird (Secret-Filter, auf 2000 Zeichen gekürzt) zur Schrittnotiz.
  - `planner` bestanden: Plan wird wie `set_pipeline_plan` als neue Version geschrieben (Autor Typ `run`, „Runner“).
  - Sonst: Schritt `done` bzw. `failed` mit aktueller Planversion.
  - Auftrag: `passed` → `succeeded`, `failed` → `failed`; **letzter** offener Schritt mit `passed` (nicht Planer) → `awaiting_review` mit Review an der Karte (eigene Freigabe, bestehender Ablauf) und Ausführung `completed`. Ist der Plan inzwischen neu (Version ≠ Version beim Einreihen): Auftrag `failed`, Schritt unverändert, `advance`.
  - Lauf endet, danach `advance`.
- `fail`, `reconcile: stopped` eines Pipeline-Auftrags: Schritt `failed` (Notiz „Lauf abgebrochen oder fehlgeschlagen“), Ausführung `blocked`. `stop` durch Runner oder Mensch (`/v1/agents/jobs/{id}/stop`): Schritt `pending`, Ausführung `stopped`. Besitzerwechsel (`revokeRunnerAccess`): Ausführung `stopped`.
- `POST /v1/runner/jobs/{id}/hold` `{ "reason": "Text ≤200" }`: nur eigener Auftrag im Zustand `queued` (409 `job_not_queued`); setzt `progress` (Secret-Filter), Ereignis `held` nur bei geändertem Text. Antwort Job-DTO. Claim leert `progress`.

## 5. Runner (`todo-runner`)

- Fragt mit `?pipeline=1`. Gegen einen alten Server bleiben die Felder leer, nichts ändert sich.
- `todo-runner validation <Repository-UUID|Ordner> [--timeout Sekunden] -- <Programm> [Argumente…]` speichert den Befehl lokal (argv, keine Shell), `--clear` entfernt ihn. Schritt `validation`: Befehl im freigegebenen Ordner, eigene Prozessgruppe, Timeout (Standard 1800 s), **kein Agent, keine Tokens**. Exit 0 → `passed`; sonst `failed`. Ohne eingerichteten Befehl `failed` mit Hinweis. Notiz nur Exit-Code und Dauer; Ausgabe bleibt in einer lokalen Datei (0600).
- Agentenschritte: `planner` nur lesend, Antworttext = Plan (strukturiertes Feld `plan`); `developer` Umsetzungs-Werkzeuge, `--resume`, wenn `resumeSessionReference` **diesem Runner im selben Ordner bekannt** ist, sonst neue Sitzung; `tester` Umsetzungs-Werkzeuge, `review` nur lesend, beide mit Pflichtfeld `verdict` (`passed|failed`; fehlt es → `failed`). `model`/`effort` als `--model`/`--effort`, nur Werte nach `[A-Za-z0-9._:/-]+` ohne führendes `-`.
- **Kontingent-Bremse:** `todo-runner budget -- <Programm> [Argumente…]` (z. B. `python3 …/budget.py --json`), `--clear` entfernt sie. Vor jedem Claim eines Agentenauftrags (auch manueller) und vor dem Fortsetzen nach einer Antwort: Verboten bei Exit ≠ 0, Timeout (30 s), unlesbarer Ausgabe, `"allowed": false` oder `"ampel": "rot"`. Dann kein Claim, `hold` mit „Kontingent-Bremse: …“. Validierungs-Aufträge laufen weiter. Ohne eingerichteten Befehl wie bisher.

## 6. PWA

Pipeline-Tab, Abschnitt „Ausführung“: für Startberechtigte mit Bindung Auswahl + „Pipeline starten“; Status (Schritt, Gerät, Zustand des Auftrags, Fortschritt bzw. Kontingent-Bremse), Hinweise zu `waiting_approval`, `blocked` (Wiederholen am Schritt), `paused` (Grund + „Fortsetzen“), `completed` (Review), „Stoppen“; Hinweis, wenn `runnerSupportsPipeline` false. Laufstatus je Schritt sichtbar. Ohne `execution`-Feld und ohne Bindung bleibt alles wie in Stufe 2.

## Grenzen

Apple-App zeigt die Ausführung noch nicht (Folgekarte). „Änderungen“ am Schluss-Review setzt keine Schritte zurück (neuer Plan oder neuer Start). Befehlsausgaben der Validierung sind nur lokal sichtbar.

## Klarstellung Backend

Wo der Vertrag offen war, gilt die engere Auslegung:

1. **Einreihen nur mit Startrecht.** Auslöser ohne Startrecht (Person mit Bearbeitungs- oder Verwaltungsrecht, jede Verbindung) reihen nie etwas ein; wäre ein Auftrag fällig, wird die Ausführung `paused` mit `plan_needs_owner`, `task_changed` oder `continue_required`. Das gilt auch für „Änderungen“ am Plan (startet den Planer nur auf Wunsch der Person mit Startrecht; unter Brain-Vollmacht nur die **Freigabe**, und nur wenn das Konto der Verbindung das Startrecht hat) und für Plan-Schreiben bei ausgeschaltetem Planer.
2. **Keine automatische Wiederholung.** Ein Auftragsabschluss reiht keinen Schritt erneut ein, der in dieser Ausführung für dieselbe Planversion schon gelaufen ist (z. B. von Hand auf `pending` zurückgesetzt): `paused`/`continue_required`.
3. **Fortsetzen ohne `planVersion`** nimmt nur den Karteninhalt an, keinen neuen Plan.
4. **Claim mit veraltetem Plan** (Version seit dem Einreihen neu oder nicht angenommen): Auftrag `cancelled`, 409 `plan_changed`, danach `advance`. Karte in ein anderes Projekt verschoben: Ausführung `stopped`, 409 `task_changed`.
5. **`planBody`/`planVersion`** im Runner-Detail nur, wenn die Planversion die des Auftrags ist; bei Arbeitsschritten nur der angenommene Plan und nie bei ausgeschaltetem Planer. `feedback`: Notiz des letzten Wiederholens dieses Schritts und dieser Planversion, sonst (Planer) der Kommentar zu „Änderungen“.
6. **Gerät widerrufen, Konto gesperrt** (wie Besitzerwechsel): Ausführung `stopped`, auch wartende Pipeline-Aufträge werden `cancelled`.
7. **`nothing_to_run`** nur, wenn alle eingeschalteten Arbeitsschritte erledigt sind **und** kein Planer-Lauf aussteht (Planer an ohne freigegebenen Plan darf starten).
8. **`jobID`/`jobState`** zeigen den offenen Auftrag, bei `completed` den mit wartendem Review, sonst fehlen sie. `jobProgress` nur für Betrachter mit Startrecht. Fehlende Werte fehlen im JSON.
9. Start verbraucht die Karten-Erlaubnis `autoStart`. Pausieren und Blockieren haben keine eigenen Protokollaktionen. Zusätzliche Spalte `agent_jobs.pipeline_plan_version`.
10. MCP `start_pipeline_execution` mit ungültiger `executionID`: `invalid_execution_id`. Die Review-Zusammenfassung läuft durch den Secret-Filter.

