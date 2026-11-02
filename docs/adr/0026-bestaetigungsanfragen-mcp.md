# ADR 0026 – Bestätigungsanfragen für große MCP-Aktionen

Status: umgesetzt (2.11.2026), SQLite und Chromium geprüft, MariaDB ungeprüft.

## Kontext

Agenten dürfen über MCP viel, aber nicht alles direkt: Ein Projekt zu löschen oder das Eigentum zu übertragen ist unumkehrbar oder weitreichend. Nutzerwunsch (Todolino): große Aktionen (Klasse C), z. B. Projekt löschen, soll der Mensch bestätigen.

## Entscheidung

- **Klasse C führt der Agent nicht aus, er beantragt sie.** Die MCP-Tools `delete_project`, `delete_task` und `transfer_project_owner` prüfen Argumente, Grant und aktuelle Rechte, legen eine Zeile in `action_requests` an und antworten mit dem Fehler `confirmation_required` (JSON mit `actionRequestID`, Text: nicht erneut auslösen, mit `wait_for_events`/`get_action_request` warten). Gleicher Aufruf bei offener Anfrage derselben Verbindung liefert dieselbe Anfrage (Fingerprint aus Grant, Tool, Argumenten; serialisiert über die Grant-Zeile).
- **Tabelle `action_requests`** (additive Migration `CreateActionRequests`): Konto, Grant, Agentenname, Tool, Argumente (Strings), Zusammenfassung (deutsch, vom Server), Umfang (`ActionImpact`: Ziel, Anzahl Aufgaben/Unterprojekte, `destructive`), Zustand `pending|confirmed|rejected|expired|executed|failed`, Ergebnis `{ok, code}`, Zeiten, Ablauf nach 7 Tagen. Die Zeile ist zugleich der Audit-Eintrag („Agent X wollte ..., bestätigt/abgelehnt um ...“); ein eigener Aktivitätseintrag entfällt, weil bei Löschungen das Ziel samt Aktivität verschwindet.
- **Registry `ConfirmableActions`:** je Aktion `describe` (prüft die Rechte des Kontos jetzt und liefert Zusammenfassung, Umfang, betroffene Projekte) und `execute` (dieselben Fachpfade wie REST: `PlanningOperations.deleteProject/deleteTask`; Eigentumswechsel mit den Schritten von `PUT /v1/projects/{id}/owner`, nachgebildet, weil der Controller unverändert blieb). Weitere Klasse-C-Aktionen kommen als Eintrag dazu.
- **Ausführung nur nach Bestätigung durch das Konto** (`POST /v1/action-requests/{id}/confirm`, contracts/action-requests.yaml): in einer Transaktion mit Sharing-Graph-Sperre und `lockRow` auf der Anfrage. Rechte werden neu geprüft (`describe` erneut, Grant nicht widerrufen, alle betroffenen Projekte inklusive Unterprojekte im Grant). Scheitert das, rollt die Aktion zurück und die Anfrage wird `failed` mit `result.code` (`forbidden`, `not_found`, `version_conflict`, `connection_revoked`). Zweites Bestätigen liefert dasselbe Ergebnis ohne neue Ausführung; Ablehnen ist nur bei `pending` möglich (sonst 409), abgelaufen 410. Fremde Konten sehen 404.
- **Agent:** `get_action_request`/`list_action_requests` (nur Anfragen der eigenen Verbindung, kein Scope nötig), `wait_for_events` meldet Entscheidungen als Hinweis `kind: action_request` mit `actionRequestID` (ohne Inhalte). Dafür bekommt `live_events` eine nullable Spalte `ref_id` (Migration `AddLiveEventRef`); `ActionRequest` schreibt wie die anderen Modelle Hinweiszeilen.
- **Feed und Zähler:** `GET /v1/feed` bekommt additiv das Feld `confirmations[]` (offene Anfragen, nur kontoweit, erste Seite). Ein eigenes Feld statt `needsYou`, weil dessen Elemente aufgabengebunden und nicht-optional sind; ältere Clients (Apple) ignorieren das Feld und brechen nicht. `summary.pendingConfirmations` im Command Center zählt offene Anfragen (nur kontoweit, ohne Grant-Einschränkung) und geht in den Attention-Badge ein.
- **Push:** neue Kategorie `confirmations` (Standard an), fester Text „Bestätigung nötig / Ein Agent wartet auf deine Bestätigung“, kein Inhalt; Badge-Zahl enthält offene Anfragen.
- **Bereinigung:** `cleanup-expired` setzt offene Anfragen nach Ablauf auf `expired` und löscht entschiedene/abgelaufene Zeilen 30 Tage nach `expires_at`.
- **PWA:** Karte `ConfirmationCard` in „Für dich“ > „Braucht dich“: Zusammenfassung, Agent, Ablauf, Knöpfe „Bestätigen“ (zweiter Schritt: Projektname eintippen beim Projektlöschen, sonst Haken „Ich habe verstanden“; destruktive Optik) und „Ablehnen“; nach der Entscheidung bleibt das Ergebnis („Projekt gelöscht.“) bis zum Verlassen der Seite sichtbar.

## Folgen / offen

- Die Karte ist an die Aktionen der Registry gebunden; eine neue Aktion braucht Texte (`confirm.kind.*`, `confirm.done.*`) in der PWA.
- Der Eigentumswechsel dupliziert die wenigen Schritte von `SharingController.setOwner`; bei Änderung dort mitziehen (oder in einen gemeinsamen Dienst herausziehen).
- Apple-App kennt `confirmations` und die Kategorie noch nicht (Feld wird ignoriert, Push zeigt den festen Text).
- Kein Aktivitätseintrag am Projekt; das Protokoll liegt in `action_requests` (30 Tage nach Ablauf aufgehoben). Eine „Verlauf“-Ansicht der entschiedenen Anfragen fehlt (REST `?state=all` liefert sie).
- MariaDB: `FOR UPDATE` auf Anfrage und Grant sowie JSON-Spalten nicht ausgeführt.
