# Plan Pipeline Stufe 2 (Karte B926E7D8)

Folge von Stufe 1 (Karte 74EC341D, `contracts/pipeline.yaml` 1.0.0). **Nur Status und Einstellungen, keine Ausführung** (Runner = Stufe 3, Karte F5DD1C00). Rein additiv: alte Clients und alte Aufrufe laufen unverändert; kein Deploy.

Dieses Dokument ist der gemeinsame Vertrag für Backend und PWA. Abweichungen im Code zuerst hier nachziehen.

## 1. Projekt-Einstellungen

Eine Zeile je Projekt (Tabelle `project_pipeline_settings`, Migration `CreateProjectPipelineSettings`, additiv; Zeile entsteht erst beim ersten Schreiben, ohne Zeile gelten die Standardwerte; Zeile hängt am Projekt mit `onDelete: .cascade`).

```json
{
  "projectID": "UUID",
  "revision": 0,
  "steps": { "planner": true, "approval": true, "developer": true, "validation": true, "tester": true, "review": true },
  "roles": {
    "planner":   { "model": null, "effort": null },
    "developer": { "model": null, "effort": null },
    "tester":    { "model": null, "effort": null },
    "reviewer":  { "model": null, "effort": null }
  },
  "maxFixRounds": 3,
  "notifyOnWaitingApproval": true,
  "updatedAt": "ISO-8601 (fehlt ohne Zeile)",
  "updatedByLabel": "Name (fehlt ohne Zeile)",
  "history": [ { "id": "UUID", "actorType": "person|integration", "actorLabel": "...", "summary": "kurzer Text, z. B. steps.tester aus; roles.developer.model sonnet", "createdAt": "..." } ]
}
```

- Standardwerte: alle Schritte an, `model`/`effort` je Rolle `null` (= Standard des Runners), `maxFixRounds` 3, `notifyOnWaitingApproval` true. `null`-Felder fehlen im JSON (Clients behandeln fehlend wie null); `roles` und `steps` kommen immer vollständig.
- `effort`: `low | medium | high | xhigh | max` oder null. `model`: frei, getrimmt 1 bis 100 Zeichen, Muster `[A-Za-z0-9._:/-]+` (Beispiele `sonnet`, `haiku`, `gpt-6.1-sol`), sonst 400 `invalid_model`; unbekannte Effort-Werte 400 `invalid_effort`. Kein Abgleich mit einer Modellliste (das entscheidet der Runner in Stufe 3).
- Rollen gehören zu Schritten: planner → `planner`, developer → `developer`, tester → `tester`, reviewer → `review`. `validation` hat keine Rolle (läuft in Stufe 3 ohne Agent), `approval` ist eine Person.
- `maxFixRounds`: Ganzzahl 0 bis 10. 0 = Wiederholen ist nie erlaubt.
- Lesen (`GET /v1/projects/{id}/pipeline-settings`, MCP `get_pipeline_settings`, Scope `projects:read`): Leserecht am Projekt. Auch ohne Zeile Antwort mit Standardwerten und `revision` 0.
- Schreiben (`PATCH /v1/projects/{id}/pipeline-settings`, MCP `update_pipeline_settings`, Scope `projects:write`): Recht `manage` am Projekt (`edit` genügt nicht; 403). Teil-Update: nur gesendete Felder ändern sich (`steps`/`roles` auf Feldebene gemischt, `"model": null` bzw. `"effort": null` löscht), mindestens ein Feld, unbekannte Schlüssel 400 `invalid_pipeline_settings`. Pflichtfeld `revision` (aktueller Stand, 0 ohne Zeile), sonst 409 `revision_conflict`. Gleicher Inhalt ändert weder Revision noch Verlauf (Wiederholung).
- Verbindungen (MCP): wie `decide_plan` nur mit Brain-Vollmacht für diese Verbindung und dieses Projekt plus Zitat (`brain_mandate_required`, `outside_brain_mandate`, `quote_required`, `invalid_quote`); Entscheidung wird als Vollmacht-Protokoll gebucht (Audit-Kind `pipeline.settings`). Hintergrund: Modell und Effort bestimmen Kosten, eine Verbindung soll sich nicht selbst hochstufen.
- Audit: Tabelle `project_pipeline_settings_events` (Projekt, laufende `sequence`, Akteur, `summary`, Zeit), in `history` die letzten 20, neueste zuerst. Secrets-Filter ist für `model` nicht nötig (Muster erzwingt es).
- Schritt ausgeschaltet bedeutet:
  - `planner` aus: kein Plan nötig; `planner` und `approval` erscheinen als `skipped`, der Plan-Gate für die Arbeitsschritte (`plan_not_approved`) entfällt. Ein trotzdem geschriebener Plan bleibt möglich und wird dann normal freigegeben.
  - `approval` aus (planner an): ein geschriebener Plan wird sofort `approved` (Entscheidungsfelder: `decidedByType` `system`, kein Name), Schritt `approval` ist `skipped`, keine Wartebenachrichtigung.
  - `developer`/`validation`/`tester`/`review` aus: Schritt erscheint mit `enabled:false` und Status `skipped`; `set_pipeline_step` auf ihn 409 `step_disabled`; Wiederholen auf ihn 409 `step_disabled`.
  - Ein Schritt kann nur vor oder nach dem Lauf umgeschaltet werden; bereits gespeicherte Schrittzustände bleiben stehen (die Anzeige nutzt `enabled`, der gespeicherte Zustand bleibt in `state`).

## 2. Pipeline der Karte (`GET /v1/tasks/{id}/pipeline`, additiv)

Neue Felder:
- `settings`: wirksame Einstellungen (nur `steps`, `roles`, `maxFixRounds`, `notifyOnWaitingApproval`, `revision`, ohne `history`).
- je Schritt: `enabled` (Bool, immer vorhanden), `planVersion` (Int, Planversion, auf die sich der gespeicherte Zustand bezieht; fehlt bei `pending` ohne Zeile), `role` (nur bei den vier Rollen-Schritten: Modell und Effort, wie in den Einstellungen, damit der Client nicht zweimal lädt: `{model?, effort?}`).
- `fixRounds`: `{ "used": n, "max": m, "remaining": m-n }`. `used` zählt die Wiederholungen der **aktuellen Planversion** (Protokollaktion `step_retried`); ein neuer Plan beginnt wieder bei 0.
- `waitingApproval` (Bool, true wenn Plan `proposed` und `approval` an).

## 3. Wiederholen (nur Status)

`POST /v1/tasks/{id}/pipeline/steps/{step}/retry`, MCP `retry_pipeline_step` (Scope `tasks:write`, Recht `edit`).
Body: `{ "planVersion": int (optional), "note": "bis 2000 Zeichen (optional)", "agentName": ... }`.
- Nur für einen Schritt im Zustand `failed` (sonst 409 `step_not_failed`); `approval` 409 `step_managed`; ausgeschalteter Schritt 409 `step_disabled`; `planVersion` angegeben und nicht aktuell 409 `plan_changed`; kein freigegebener Plan bei Arbeitsschritten 409 `plan_not_approved`.
- Grenze: `fixRounds.used >= maxFixRounds` ⇒ 409 `fix_rounds_exhausted`.
- Wirkung: nur dieser Schritt geht von `failed` auf `pending` (Notiz ersetzt oder gelöscht), alle anderen Schritte bleiben unberührt. Protokoll `step_retried` (mit `planVersion`, `step`), Aktivität `pipeline.step`. Es wird nichts gestartet.
- Wirkung auf Personen und Verbindungen gleich (Bearbeitungsrecht). Wiederholung mit gleichem Zustand (Schritt schon `pending`) 409 `step_not_failed`.

## 4. Bindung von `set_pipeline_step` an die Planversion

`PUT .../steps/{step}` und MCP `set_pipeline_step` nehmen **optional** `planVersion` (Int ≥ 1).
- Angegeben und ungleich der aktuellen Version (oder kein Plan): 409 `plan_changed`, nichts wird geschrieben (ein Agent mit altem Plan überschreibt keine neuen Schritte).
- Fehlt es, verhält sich der Aufruf wie bisher; gespeichert wird die aktuelle Planversion (bzw. nichts ohne Plan). Das Handbuch empfiehlt `planVersion` immer mitzugeben.
- `ausgeschalteter Schritt` ⇒ 409 `step_disabled` (siehe oben). `maxFixRounds` wirkt nur über `retry`; ein direktes `pending` setzen eines `failed`-Schritts über `set_pipeline_step` bleibt erlaubt (Stufe 1), zählt aber nicht als Runde (Hinweis im Handbuch: für die Runner-Logik `retry_pipeline_step` benutzen).

## 5. Benachrichtigung bei wartender Freigabe

Ein Plan im Zustand `proposed`, dessen Projekt `approval` an hat und `notifyOnWaitingApproval` true:
- **Überblick/Für dich** (`GET /v1/feed`): `needsYou`-Eintrag `kind: "plan"` (Rang gleich Reviews: zwischen review und blocked einsortieren, d. h. Rang 2 wie Review), `id: "plan:<taskID>:<version>"`, `title` = Aufgabentitel mit Zusatz „Plan v<version> wartet auf Freigabe“ (Text deutsch, Detail = erste Zeile des Plans bis 160 Zeichen), Aktionen `approve` („Plan freigeben“, POST `/v1/tasks/{id}/plan/decision` Body `{decision:"approve", version}`) und `request_changes` („Änderungen“, requiresInput `comment`). Nur für Personen mit `edit` am Projekt. Command Center (`GET /v1/command-center`): Karte bekommt `planWaiting: true` (fehlt sonst), `summary.plansWaiting` (Anzahl); Lanes bleiben unverändert.
- **Updates/Feed-Posts**: `plan.written`, `plan.approved`, `plan.changes_requested` kommen in `CommandCenterService.updateKinds` und in `FeedService.managementKinds` (Post `kind: "plan"` mit `event` der Aktivität, `text` = Titel „Plan v<n>“ bzw. Kommentar der Entscheidung). `pipeline.step` bleibt aus dem Feed (zu laut), erscheint in der Karten-Aktivität wie bisher.
- **Push**: Trigger `plan` im `PushWorker`: für jeden Empfänger mit `edit` am Projekt ein Eintrag, Dedupe-Schlüssel `plan:<planID>:<version>`, Einstellung der Kategorie `agent_reviews` (kein neuer Schalter); Text deutsch/englisch wie Review („Ein Plan wartet auf deine Freigabe.“; mit Inhalt der Kartentitel); `PushDelivery` prüft vor dem Senden erneut und überspringt (`skipped`), wenn der Plan inzwischen entschieden, ersetzt oder die Benachrichtigung ausgeschaltet ist; Rolle `.edit`. Kein Push an den Schreiber des Plans selbst (Person als Autor: Eintrag nur für andere Personen; Verbindung als Autor: an alle Berechtigten).
- Live (ADR 0022) und `wait_for_events` unverändert (Hinweis `plan` existiert).

## 6. Vertrag, Handbuch, Audit

- `contracts/pipeline.yaml` → 1.1.0 (neue Pfade, Schemas, `x-mcp-tools`), `contracts/oauth-mcp.yaml` → 1.9.0, `contracts/feed.yaml` und `contracts/command-center.yaml` Minor-Version hoch (additive Felder), Handbuch → 1.44.0 (Abschnitt „Plan approval and pipeline“ erweitern, Änderungsvermerk, `scripts/embed-agent-manual.sh`, Versionstests nachziehen), `docs/MCP-PARITAET.md`, neuer ADR-Nachtrag (Entscheidungen oben) in `docs/adr/0032-...` bzw. neuer ADR 0033.
- Neue MCP-Werkzeuge: `get_pipeline_settings`, `update_pipeline_settings`, `retry_pipeline_step`; geändert: `set_pipeline_step` (+`planVersion`), `get_task_pipeline` (neue Felder).
- Fehlercodes neu: `invalid_pipeline_settings`, `invalid_model`, `invalid_effort`, `revision_conflict`, `step_disabled`, `step_not_failed`, `fix_rounds_exhausted`, `plan_changed` (jetzt auch für Schritte).

## Klarstellung Backend (25.11.2026, Backend-Worker)

Kleinste sichere Auslegung dort, wo der Vertrag offen war. Gilt für Backend, MCP und PWA gleichermaßen:

- **Fehlende oder ungültige `revision` im PATCH** (nicht ganzzahlig, negativ, fehlt): 400 `invalid_pipeline_settings`. 409 `revision_conflict` nur bei ganzzahliger, aber veralteter `revision`.
- **Wiederholung**: Ergibt das Anwenden des Updates keine Änderung, antwortet der Server 200 mit dem aktuellen Stand, auch wenn die mitgesendete `revision` veraltet ist (eine Wiederholung nach Erfolg trägt die alte Revision). Prüfreihenfolge: Rechte, Vollmacht (MCP), dann „keine Änderung“, dann `revision_conflict`. Zahlen außerhalb 0 bis 10, Nicht-Zahlen und Nicht-Ganzzahlen bei `maxFixRounds` sind 400 `invalid_pipeline_settings`; ein leeres Objekt (`steps: {}`, `roles.x: {}`) zählt nicht als Feld. Nicht-Strings bei `model` sind `invalid_model`, bei `effort` `invalid_effort`.
- **Vollmacht-Protokoll**: `brain_decision_audits.task_id` ist NOT NULL; `pipeline.settings` wird deshalb in `brain_connection_audits` gebucht (`target_grant_id` = handelnde Verbindung, `project_id`), in `GET /v1/settings/brain-mandate/audit` mit `taskID` fehlend, `projectID` und `subjectID` = Projekt, `note` fehlt. Keine neue Tabelle, kein Karten-Chat-Eintrag (keine Karte).
- **Rollen im JSON**: `roles` hat die Schlüssel `planner`, `developer`, `tester`, `reviewer` (der Schritt `review` gehört zur Rolle `reviewer`); `steps` die sechs Schrittnamen.
- **`enabled` von `approval`** ist `steps.approval` UND `steps.planner` (ohne Planer gibt es nichts freizugeben, Anzeige `skipped`). `waitingApproval`, Feed, Command Center und Push richten sich nur nach `steps.approval` und `notifyOnWaitingApproval` (ein trotz ausgeschaltetem Planer geschriebener Plan wird normal freigegeben und angekündigt). Eine Schrittzeile gewinnt gegen die Anzeige `skipped`: `state` ist der gespeicherte Zustand, sonst `skipped` (aus) bzw. `pending`.
- **Planer aus**: auch `set_pipeline_step` auf `planner` ist dann `step_disabled`. Der Plan-Gate (`plan_not_approved`) entfällt für `set_pipeline_step` und `retry`, solange `steps.planner` aus ist.
- **Automatische Freigabe** (`steps.approval` aus): Plan `approved`, `decidedByType` `system` (im DTO `decidedByType`, klein geschrieben), `decidedAt` gesetzt, kein Name; Schritt `approval` `skipped`; ein Protokolleintrag `plan_written`, kein `plan_approved`. Dasselbe Planen mit demselben Text ändert nichts (Wiederholung).
- **Prüfreihenfolge bei Schritten** (`set_pipeline_step`, `retry`): Schrittname, `step_managed`, `invalid_plan_version`/Text, Rechte, `plan_changed`, `step_disabled`, danach `plan_not_approved` (set) bzw. `step_not_failed`, `plan_not_approved`, `fix_rounds_exhausted` (retry). `planVersion` gilt auch für den Schritt `planner` (ohne Plan: `plan_changed`).
- **`fixRounds.used`** zählt `step_retried`-Einträge mit der aktuellen Planversion (ohne Plan: Einträge ohne Version); `remaining` nie negativ, auch wenn `maxFixRounds` unter `used` gesenkt wird.
- **Aktivität `plan.*`**: `subjectID` zeigt jetzt auf den Protokolleintrag der Karte (Version und Kommentar des Zeitpunkts, im Feed „Plan v<n>“ stimmt auch für ältere Einträge); Einträge aus Stufe 1 (Plan als Subjekt) werden mit der aktuellen Version gelesen.
- **Command Center**: `planWaiting` und `summary.plansWaiting` hängen nicht an der Rolle (jede lesbare Karte), das Feed-needsYou nur an `edit`. `planWaiting` einer Karte schließt Unteraufgaben ein, `plansWaiting` zählt Pläne.
- **Feed-needsYou**: `title` = „<Aufgabentitel> – Plan v<n> wartet auf Freigabe“, `detail` = erste nichtleere Zeile (bis 160 Zeichen), `actor` = Autor des Plans.
- **Push**: Payload-Feld `version` (Plan) im `PushEvent`, Kategorie der Benachrichtigung `TODO_PLAN` (die App kennt sie noch nicht und zeigt dann ohne Aktionen), Titel mit Inhalt nur der Kartentitel, nie der Plantext. Abzeichen (badge) zählt Pläne nicht.

## 7. PWA

- **Projekt-Einstellungen** (Verwaltungsansicht des Projekts, Abschnitt „Pipeline“, nur sichtbar für `manage`; sonst nur Anzeige): Schalter je Schritt (sechs), je Rolle Modell (Textfeld mit Vorschlägen) und Effort (Auswahl, „Standard“ = null), „Höchstens … Fix-Runden“ (0 bis 10), Schalter „Benachrichtigen, wenn eine Freigabe wartet“, Speichern mit Revision (Konflikt → verständliche Meldung und Neuladen), Verlauf (letzte Änderungen). Alle Texte in `de-pipeline.ts`.
- **Karte → Tab Pipeline**: ausgeschaltete Schritte als „aus“ gekennzeichnet (nicht klickbar, nicht gezählt), Modell/Effort je Rolle als kleine Zeile am Schritt, `failed`-Schritt mit Knopf „Wiederholen“ (nur Bearbeiter, zeigt „Runde n von m“; bei erschöpft deaktiviert mit Hinweis), Hinweis „Plan wartet auf Freigabe“ bleibt, Fehlermeldungen für die neuen Codes.
- **Überblick/Für dich**: needsYou-Karte `plan` mit Aktionen (freigeben, Änderungen mit Kommentar) und Link zur Karte; Feed-Posts `plan` lesbar dargestellt; unbekannte Kinds weiter als Rohtext.
- Hell und dunkel, 1280 px und 390 px, Bilder ansehen. E2E gegen das echte Backend (Chromium, Firefox, WebKit wo die Spec in `MULTI` steht).
