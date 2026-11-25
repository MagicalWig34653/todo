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

## 7. PWA

- **Projekt-Einstellungen** (Verwaltungsansicht des Projekts, Abschnitt „Pipeline“, nur sichtbar für `manage`; sonst nur Anzeige): Schalter je Schritt (sechs), je Rolle Modell (Textfeld mit Vorschlägen) und Effort (Auswahl, „Standard“ = null), „Höchstens … Fix-Runden“ (0 bis 10), Schalter „Benachrichtigen, wenn eine Freigabe wartet“, Speichern mit Revision (Konflikt → verständliche Meldung und Neuladen), Verlauf (letzte Änderungen). Alle Texte in `de-pipeline.ts`.
- **Karte → Tab Pipeline**: ausgeschaltete Schritte als „aus“ gekennzeichnet (nicht klickbar, nicht gezählt), Modell/Effort je Rolle als kleine Zeile am Schritt, `failed`-Schritt mit Knopf „Wiederholen“ (nur Bearbeiter, zeigt „Runde n von m“; bei erschöpft deaktiviert mit Hinweis), Hinweis „Plan wartet auf Freigabe“ bleibt, Fehlermeldungen für die neuen Codes.
- **Überblick/Für dich**: needsYou-Karte `plan` mit Aktionen (freigeben, Änderungen mit Kommentar) und Link zur Karte; Feed-Posts `plan` lesbar dargestellt; unbekannte Kinds weiter als Rohtext.
- Hell und dunkel, 1280 px und 390 px, Bilder ansehen. E2E gegen das echte Backend (Chromium, Firefox, WebKit wo die Spec in `MULTI` steht).
