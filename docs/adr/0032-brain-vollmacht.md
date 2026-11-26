# ADR 0032 – Brain-Vollmacht: eigene Verbindung, die im Auftrag einer Person entscheidet

Status: Entwurf (16.11.2026, Karte `11DA4A38`), Umsetzung auf Branch `agent/brain-vollmacht`.

## Kontext

Lino steuert seine Projekt-Sessions über einen Orchestrator ("Brain"). Er will dem Brain sagen können „nimm das an“ oder „antworte B“, ohne selbst in die App zu gehen (Frage im Brain, 13.11.: „Sammelfreigabe und das Brain darf entscheiden“). Heute teilen alle Agenten dieselbe MCP-Verbindung (denselben OAuth-Grant). `decide_review`/`answer_question` lehnen dann mit `cannot_decide_own_review`/`cannot_answer_own_question` ab, weil die Identität eines Agenten der Grant ist. Gleichzeitig darf heute jede *andere* Verbindung fremde Reviews entscheiden – ohne Vollmacht und ohne Nachweis. Der Marker `brainRecommended` (ADR-los, Handbuch 1.27.0) hängt nur am Label `agentName: "brain"`, das jede Verbindung setzen kann.

## Entscheidung

1. **Identität = eigener OAuth-Grant.** Das Brain meldet sich mit einer eigenen MCP-Verbindung an (eigener `claude mcp add`-Eintrag bzw. eigener Client, eigener Consent). Maßgeblich ist ausschließlich die Grant-ID, nie `agentName` oder der Client-Name.
2. **Vollmacht (Mandat) je Person.** Tabelle `brain_mandates`: `id`, `user_id` (Vollmachtgeber, eindeutig, FK users cascade), `grant_id` (FK oauth_grants cascade), `projects` (UUID-Liste, genau diese Projekte, keine Unterprojekt-Vererbung), `created_at`, `updated_at`, `revoked_at` (null = aktiv). Höchstens ein Mandat je Person; neu erteilen überschreibt die Zeile. Der Grant muss der Person gehören und darf nicht widerrufen sein. Wird der Grant widerrufen, ist das Mandat wirkungslos.
3. **Verwaltung nur durch die Person.** REST mit Sitzung (`requireUser` akzeptiert nur `UserSession`, keine OAuth-Tokens): `GET/PUT/DELETE /v1/settings/brain-mandate`, `GET /v1/settings/brain-mandate/audit`. Kein MCP-Schreibweg. MCP `get_connection` meldet nur lesend, ob die eigene Verbindung ein aktives Mandat hat und für welche Projekte. PWA: Einstellungen → „Brain-Vollmacht“ (Verbindung wählen, Projekte wählen, widerrufen, Protokoll).
4. **Rechteprüfung für Agentenentscheidungen** (zentral in `WorkflowService.answer`/`decideReview`, gilt für Kanban- und Runner-Reviews/-Fragen), Reihenfolge:
   1. eigener Review/eigene Frage derselben Verbindung → `403 cannot_decide_own_review`/`cannot_answer_own_question` (unverändert, auch mit Mandat);
   2. kein aktives Mandat dieser Verbindung für diese Person → `403 brain_mandate_required` (**Verhaltensänderung:** Verbindungen ohne Mandat entscheiden gar nicht mehr);
   3. Projekt der Karte nicht im Mandat → `403 outside_brain_mandate` (zusätzlich gelten wie bisher Projektrecht der Person und Projektliste des Grants);
   4. Pflichtfeld `quote` („Linos Entscheidung (Zitat)“) fehlt/leer → `400 quote_required`, zu lang (> 2000) → `400 invalid_quote`.
   Personen (REST) sind nicht betroffen. Das Mandat wird in der Entscheidungstransaktion gesperrt und erneut gelesen, damit ein gleichzeitiger Widerruf gewinnt.
5. **Sichtbarkeit und Audit.** Jede Mandatsentscheidung schreibt in derselben Transaktion (a) eine Zeile `brain_decision_audits` (`mandate_id`, `user_id`, `grant_id`, `kind` `review.accepted|review.changes_requested|question.answered`, `task_id`, `project_id`, `subject_id`, `quote`, `note`/Antwort, `created_at`; ohne FK auf Karte/Grant, damit das Protokoll Löschungen überdauert; nur `user_id` kaskadiert) und (b) einen Kommentar im Chat des Reviews/der Frage mit Autor-Label „Brain im Auftrag von <Name>“ und Text „Linos Entscheidung (Zitat): „…““. Die Aktivität behält den Grant als Akteur und bekommt dasselbe Label. Bei Runner-Reviews/-Fragen werden die Prüfungen vor der Delegation an `AgentService` ausgeführt; Audit und Kommentar folgen danach.
6. **`brainRecommended` an die Identität gebunden.** `true` nur, wenn ein Kommentar im Review-Chat von einem Grant mit aktivem Mandat stammt, dessen Mandat das Projekt der Karte enthält. Das Label `brain` allein reicht nicht mehr.

## Angriffsfläche

- **Rechteausweitung:** Ein Agent kann sich kein Mandat geben (kein MCP-Weg, REST nur mit Sitzung). Das Mandat erweitert keine Rechte: entschieden wird weiter als die Person mit ihren Projektrollen, eingeschränkt durch Grant-Projekte und Mandatsprojekte (Schnittmenge). Keine Sammelentscheidung per MCP.
- **Identitätsverwechslung:** Vertrauen nur über Grant-ID. Erteilt Lino das Mandat der gemeinsamen Projekt-Verbindung, entscheiden alle Sessions mit – die PWA zeigt deshalb Name und letzte Nutzung der Verbindung und warnt; technisch verhindern lässt sich das nicht. Eigene Reviews/Fragen der Brain-Verbindung bleiben gesperrt.
- **Widerruf:** sofort wirksam (kein Cache, Prüfung unter Zeilensperre). Widerruf des Grants wirkt ebenso. Bereits getroffene Entscheidungen bleiben (Rücknahme durch die Person wie bisher).
- **Zitat:** nicht beweisbar, nur Bestätigung des Brains; deshalb Pflicht, im Chat sichtbar und im Protokoll.

## Folgen

- Handbuch 1.29.0, Verträge `command-center` (Parameter `quote`, neue Fehler) und `connections` (Mandat-Endpunkte).
- Agenten, die bisher fremde Reviews ohne Mandat entschieden haben, bekommen `brain_mandate_required`.
- Offen: Step-up (frische Passkey-Bestätigung) beim Erteilen des Mandats ist nicht Teil dieses Schritts.

## Nachtrag 17.11.2026: Ergebnis des Security-Reviews

Umgesetzt: Audit-Felder `quote`/`note` als TEXT; Mandat und Grant werden unter `FOR UPDATE` gelesen (Sperrreihenfolge Mandat, dann Grant); Runner-Pfade entscheiden, auditieren und kommentieren in einer Transaktion; `update_task` auf `done` bei Review einer anderen Verbindung ist `brain_mandate_required`, Projektwechsel mit offener Review/Frage ist gesperrt, Aktivitaet wird als Integration gebucht; Integrationen aendern/loeschen nur eigene Kommentare, Entscheidungskommentare sind unveraenderlich; Label-Praefix "Brain im Auftrag von" reserviert; `brainRecommended` zaehlt nur Kommentare ab Erteilung und nie auf eigenen Reviews der Mandatsverbindung.

Bekannte Luecken (bewusst offen): Journal-Urteile (`review_decision`) und andere Planungsaktivitaeten laufen ausserhalb des Mandats bzw. werden als Person gebucht; Aktivitaets-Label der Mandatsentscheidung; PWA-Einstellungsseite; Passkey-Step-up beim Erteilen.


## Nachtrag 23.11.2026: eine Vollmacht je Verbindung (Karte `2280A2F1`)

Anlass (Lino 23.11.): „Lass mal prüfen warum man nur einen MCP eine Vollmacht geben kann. Ich möchte dass Codex und du die Vollmacht bekommen.“

**Warum es nur eine gab:** Entscheidung 2 („höchstens ein Mandat je Person; neu erteilen überschreibt die Zeile“), umgesetzt als `unique(user_id)`. Grund war eine eindeutige Brain-Identität, keine technische Notwendigkeit: Die Prüfung (Entscheidung 4) vergleicht ohnehin die Grant-ID des Aufrufers mit dem Mandat, und Reviews/Fragen haben ihren Antragsteller als Grant.

**Neu (ändert Entscheidung 2, 3 und 6; Rest unverändert):**

- Eindeutigkeit je Verbindung: `unique(user_id, grant_id)`. Eine Person kann mehreren ihrer Verbindungen je ein Mandat geben (Brain und Codex), jedes mit eigener Projektliste. Erteilen für dieselbe Verbindung überschreibt nur deren Zeile und hebt ihren Widerruf auf. Migration `BrainMandateGrantUnique`: das bestehende Mandat bleibt unverändert erhalten (MariaDB: neuen Index anlegen, alten entfernen; SQLite: Tabelle neu aufbauen und Zeilen kopieren; Migrationstest mit Altstand). `revert` stellt die Eindeutigkeit je Person wieder her und schlägt fehl, solange eine Person mehrere Mandate hat.
- REST: `GET /v1/settings/brain-mandate` liefert `{mandates: [...]}` (das Feld `mandate` entfällt), `PUT` setzt das Mandat der genannten Verbindung, `DELETE /v1/settings/brain-mandate/{grantID}` widerruft nur dieses, `DELETE` ohne ID widerruft alle. Weiter nur mit Personen-Sitzung; kein MCP-Schreibweg.
- Prüfung (`WorkflowService.brainAuthority`): liest das Mandat genau der entscheidenden Verbindung (`user_id` + `grant_id`) unter `FOR UPDATE`, danach den Grant (Sperrreihenfolge Mandat, dann Grant, auch beim Erteilen). Die Mandate anderer Verbindungen werden nicht angesehen: Vollmacht einer Verbindung hilft einer anderen nicht, und `outside_brain_mandate` bezieht sich auf die Projektliste der eigenen Vollmacht. Reihenfolge der Fehler unverändert.
- `brainRecommended`: Kommentar jeder Verbindung mit eigener aktiver Vollmacht für das Projekt der Karte (ab deren Erteilung, nie auf eigenen Reviews dieser Verbindung). `get_connection.brainMandate` beschreibt weiter nur die aufrufende Verbindung. Audit unverändert (`grant_id` je Zeile nennt die entscheidende Verbindung).
- PWA: Einstellungen, „Brain-Vollmacht“ ist jetzt eine Liste der Vollmachten (Status, Projekte, zuletzt benutzt) mit „Projekte ändern“ und „Vollmacht widerrufen“ je Eintrag und einem Formular „Vollmacht hinzufügen“; die Übertragen-Bestätigung entfällt, die Änderung des Projektumfangs zeigt weiter den Vorher/Nachher-Vergleich.

**Sicherheit unverändert:** kein MCP-Schreibweg, eigene Reviews/Fragen bleiben gesperrt (Prüfung vor dem Mandat), Widerruf sofort unter Zeilensperre, Zitat-Pflicht, Audit mit Zitat. Verbleibende Fläche: Je Verbindung mehr Vollmacht heißt mehr Verbindungen, deren Token Entscheidungen treffen können; die PWA zeigt je Verbindung Name, letzte Nutzung und Projekte, und jede lässt sich einzeln widerrufen. Die Mandate summieren sich nicht: eine Verbindung entscheidet nie in Projekten, die nur eine andere Verbindung in ihrer Liste hat.

## Nachtrag 24.11.2026: Projektfreigaben eigener Verbindungen per MCP setzen (Karte `E71B0FF1`)

Anlass (Lino 24.11.): Die Verbindung "Wächter (Mac)" sieht Formular Backend, CarbStock und GearFlow nicht und weckt das Brain deshalb dort nicht. „Du sollst die Freigabe selber erteilen können als Brain (über die Vollmacht).“

**Neu (ergänzt Entscheidung 3 „kein MCP-Schreibweg“ nur für Projektlisten, nie für Vollmachten):**

- Zwei MCP-Werkzeuge, gleiche Fachregeln wie REST (`ConnectionService.add/remove`), Logik in `MandatedConnectionService`:
  - `list_connections` (Scope `projects:read`): die übrigen nicht widerrufenen Verbindungen derselben Person `{grantID, name, clientName, scopes, lastUsedAt, projects:[{id,name}]}`; `projects` enthält nur Projekte, die in der **eigenen Vollmacht** der aufrufenden Verbindung stehen (und die die Person jetzt lesen kann). Ohne aktive Vollmacht `403 brain_mandate_required`.
  - `set_connection_projects {grantID, addProjectIDs?, removeProjectIDs?, quote}` (Scope `projects:write`): je Liste höchstens 50, zusammen mindestens eines, keine Überschneidung (`invalid_projects`). Es ändert nur Projekte der eigenen Vollmacht; Projekte des Ziels außerhalb davon bleiben unberührt und unsichtbar (nicht in der Antwort).
- Prüfreihenfolge: Form der Argumente; Ziel = eigene Verbindung `403 cannot_change_own_connection`; Ziel fremd oder unbekannt `404 not_found` (nicht unterscheidbar), widerrufen `409 grant_revoked`; keine aktive Vollmacht dieser Verbindung `403 brain_mandate_required`; ein genanntes Projekt nicht in der Vollmacht `403 outside_brain_mandate` (die ganze Anfrage, nichts wird teilweise angewendet); `quote` fehlt `400 quote_required`, über 2000 `400 invalid_quote`; je hinzuzufügendem Projekt braucht die Person jetzt Leserechte (`404`, wie `ConnectionService.add`); das Entfernen des letzten Projekts einer Verbindung ohne `projects:write` ist `400 projects_required`. Ziel-Fehler stehen bewusst vor der Vollmachtsprüfung: sie hängen nicht davon ab, ob eine Vollmacht existiert. Alles in einer Transaktion. Idempotent (Vorhandenes hinzufügen, Fehlendes entfernen ist kein Fehler und schreibt kein Audit); ein offener Zugriffshinweis des Ziels (`ConnectionAccessRequest`) wird beim Hinzufügen auf `granted` gesetzt.
- Wiederverwendung statt Kopie: `WorkflowService.brainAuthority` ruft jetzt die allgemeine Funktion `lockedBrainAuthority` (mehrere Projekt-IDs, optional weitere zu sperrende Grants, Hook `afterLock`); Entscheidungen verhalten sich unverändert (alle `BrainMandateTests` grün).
- Sperrreihenfolge: Mandat der aufrufenden Verbindung, dann die Grants (eigener und Ziel) in aufsteigender Id-Reihenfolge, alle unter `FOR UPDATE` (`lockedMandate`/`lockedFirst`). Zwei Verbindungen, die sich gleichzeitig gegenseitig ändern, sperren dieselbe Reihenfolge der Grants; der Test `testOppositeCallsAtTheSameTimeDoNotDeadlock` läuft auf MariaDB (auf SQLite übersprungen, dort gibt es keine Zeilensperren). Die anderen Schreibwege sperren höchstens einen Grant (`ConnectionService.add/remove`) oder Mandat, dann Grant (`BrainMandateService.grant`): keine Umkehrung.
- Audit: **eigene Tabelle `brain_connection_audits`** (`mandate_id`, `user_id` mit Cascade, `grant_id` = handelnde Verbindung, `target_grant_id`, `kind` `connection.project_added|connection.project_removed`, `project_id`, `quote` als TEXT, `created_at`), eine Zeile je tatsächlich geänderten Projekts, in derselben Transaktion wie die Änderung. Entscheidung gegen "`task_id` in `brain_decision_audits` nullable machen": SQLite kann eine Spalte nicht lockern, ohne die Tabelle neu aufzubauen (Risiko für Bestandsdaten, MariaDB und SQLite getrennte Pfade, siehe Lehre aus `BrainMandateGrantUnique`), und die Zeilen gehören fachlich nicht zu einer Karte. Eine neue Tabelle ist rein additiv. `GET /v1/settings/brain-mandate/audit` mischt beide Tabellen (je höchstens 200, dann gemeinsam sortiert, neueste zuerst); `BrainAuditDTO.taskID` ist jetzt optional (fehlt bei `connection.*`), `subjectID` ist dort die geänderte Verbindung. Die PWA-Liste zeigt die neuen kinds und blendet den Kartenlink ohne `taskID` aus.
- Nicht geändert: Vollmachten (kein Werkzeug, auch nicht für die Ziel-Verbindung; eine Vollmacht des Ziels bleibt bei einer Projektänderung byte-gleich), eigene Reviews/Fragen, Widerruf sofort, Zitat-Pflicht.

**Entscheidung zur Schnittmenge:** Bei Entscheidungen gilt weiter Mandat UND Projektliste des Grants (Schnittmenge). Für `set_connection_projects` genügt das Mandat: die Person hat die Projekte beim Erteilen ausdrücklich für diese Verbindung genannt und musste sie lesen können, und zum Zeitpunkt der Änderung prüft der Server erneut ihre Leserechte. Eine zusätzliche Bedingung "Projekt steht im Grant des Brains" würde den Anlass (Brain soll Projekte freigeben, die gerade nicht in seiner eigenen Liste stehen müssen) unnötig verhindern, ohne dass ein Recht der Person überschritten wird. Die Verbindung kann damit Projekte an Dritte freigeben, die sie selbst nicht über ihre Grant-Liste liest; wer das nicht will, nimmt das Projekt nicht in die Vollmacht auf.

**Angriffsfläche (neu):**

- *Rechteausweitung:* Die Wirkung ist auf Projekte der eigenen Vollmacht und auf die Verbindungen derselben Person begrenzt; das Recht der Person bleibt Obergrenze, weil jede Verbindung ohnehin nur Rolle der Person ∩ Grant-Liste hat. Eine freigegebene Verbindung bekommt nie mehr als die Person selbst hat. Kein Weg, ein Mandat zu setzen oder zu ändern, auch nicht indirekt (Vollmachtszeilen werden nicht angefasst).
- *Selbstermächtigung:* Eigene Verbindung ist gesperrt (`cannot_change_own_connection`); ein Brain kann sich keine zusätzlichen Projekte geben. Vollmachten summieren sich nicht: jede Verbindung ändert nur Projekte der Vollmacht der **handelnden** Verbindung, auch wenn eine andere Verbindung der Person mehr Projekte in ihrer Vollmacht hat.
- *Fremde Konten:* Grants anderer Personen sind weder lesbar noch änderbar, `404` ohne Unterschied zu unbekannten Ids; gesperrt wird dennoch die Zeile (kein Seitenkanal in der Antwort).
- *Verdeckte Projekte:* Antworten nennen nie Projekte des Ziels außerhalb der Vollmacht.
- *Widerruf:* wirkt für den nächsten Aufruf (Mandat und Grants unter Zeilensperre gelesen); bereits geänderte Listen bleiben und lassen sich in der PWA (Verbindungen, Teilen-Fenster) oder per REST durch die Person zurücknehmen. Die Zitat-Pflicht und das Protokoll gelten wie bei Entscheidungen.
- *Schleife/Flut:* höchstens 50 Projekte je Aufruf; idempotente Wiederholungen schreiben nichts.

**Bekannte Lücken (bewusst offen):** Kein Eintrag in Aktivität/Feed mit dem Label „Brain im Auftrag von <Name>“: `activity_events` ist an eine Karte gebunden (`task_id` Pflicht), eine projektbezogene Aktivität ohne Karte gibt es nicht; das wäre ein eigener Umbau. Das Protokoll in den Einstellungen ist der Nachweis. Kein Chatkommentar (keine Karte). Kein Push an die Person bei Freigaben (nur Protokoll). `list_connections` nennt keine Verbindungen anderer Personen und keine widerrufenen.

## Nachtrag 25.11.2026: Plan-Freigabe unter der Vollmacht (Karte `74EC341D`)

Die Vollmacht gilt seit Karte `74EC341D` auch für `decide_plan` (Plan freigeben oder Änderungen verlangen, Vertrag `contracts/pipeline.yaml`). Es gelten dieselben Regeln wie für `decide_review`: eigene Vollmacht der aufrufenden Verbindung, Projekt der Karte in deren Projektliste, Pflicht-Zitat, nie der eigene Plan derselben Verbindung (`cannot_decide_own_plan`), Audit (`plan.approved`, `plan.changes_requested`) und Chatkommentar. Das gilt auch für bereits erteilte Vollmachten; sie müssen nicht neu erteilt werden.


## Nachtrag 25.11.2026 (2): Pipeline-Einstellungen unter der Vollmacht, Stufe 2 (Karte `B926E7D8`)

Plan: `docs/PLAN-PIPELINE-STUFE-2.md`, Vertrag `contracts/pipeline.yaml` 1.1.0. Entscheidungen:

- **Einstellungen je Projekt**: eine Zeile (`project_pipeline_settings`, erst beim ersten Schreiben), Revision für optimistische Sperre, Verlauf in `project_pipeline_settings_events`. Beides gehört dem Projekt (`onDelete: cascade`), nicht dem Konto: Namen von Personen werden beim Lesen aus dem Konto gelesen. Migrationen rein additiv (`CreateProjectPipelineSettings`, `AddPlanVersionToPipelineSteps` mit nullbarer Spalte; alte Zeilen bleiben gültig).
- **Wer ändert**: Personen mit `manage` über REST; Verbindungen über MCP `update_pipeline_settings` nur mit Brain-Vollmacht dieser Verbindung für das Projekt und Pflicht-Zitat (gleiche Prüfreihenfolge und Fehlercodes wie `decide_plan`), das Recht `manage` der Person bleibt Obergrenze. Grund: Modell und Effort bestimmen Kosten; eine Verbindung soll sich nicht selbst hochstufen, und die Vollmacht ist der bestehende, widerrufbare Weg dafür. Die Entscheidung steht im Vollmacht-Protokoll (kind `pipeline.settings`, Tabelle `brain_connection_audits`, weil `brain_decision_audits` an eine Karte gebunden ist).
- **Keine Ausführung**: Die Einstellungen sind Status und Wunsch; nichts wird gestartet. Modell und Effort sind frei (Muster `[A-Za-z0-9._:/-]+`), es gibt keinen Abgleich mit einer Modellliste; das entscheidet der Runner (Stufe 3).
- **Schritt-aus-Semantik** (Plan Abschnitt 1) und **Fix-Runden** (`retry` zählt je Planversion, Grenze `maxFixRounds`, 0 bis 10) sind reine Statusregeln im gemeinsamen Dienst `WorkflowService`; REST und MCP rufen dieselben Methoden. `planVersion` an Schrittmeldungen verhindert, dass ein Agent mit altem Plan neue Schritte überschreibt.
- **Benachrichtigung bei wartender Freigabe**: Feed, Command Center, Updates und Push richten sich nach dem Recht `edit` und den Projekteinstellungen; Push mit Nachprüfung vor dem Senden (entschieden, ersetzt, ausgeschaltet oder Recht verloren = übersprungen), Kategorie `agent_reviews`, nie mit dem Plantext.
- **Angriffsfläche**: Rechteausweitung nicht möglich (Vollmacht UND `manage` der Person); Selbsthochstufung über Modell/Effort nur mit Zitat der Person; Widerruf wirkt beim nächsten Aufruf; Modellnamen können keine Geheimnisse oder Befehle transportieren (enges Zeichenmuster, 100 Zeichen); Revision verhindert stilles Überschreiben.

## Nachtrag 26.11.2026: Übernahme bei Neuanmeldung (Karte `BEF08998`)

Entscheidung 1 bleibt (Identität = Grant-ID). Die Person kann beim erneuten Zustimmen eine Vollmacht von der früheren auf die neue Verbindung übertragen; eigene Anfragen der Vorgänger bleiben gesperrt. Details und Abwägung: [ADR 0036](0036-oauth-nachlauffenster-uebernahme.md).

