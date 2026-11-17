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

