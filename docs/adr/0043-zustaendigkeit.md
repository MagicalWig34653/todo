# ADR 0043: Zuständigkeit an Karte, Frage und Review, „Für mich“ und gezielter Push

Status: angenommen (28.11.2026, Karte 8B4BAC2E Teil 1; Anlass: Lino 27.11.2026, „Aufgaben/Rückfragen/Reviews zuweisen, die wirklich
für mich sind“). Betrifft ADR 0014 (Workflow), 0018 (MCP), 0021 (Push). Vertrag: `contracts/assignments.yaml` 1.0.0.

## Entscheidung

1. **Höchstens eine Person** je Karte (`tasks.assignee_id`), offener Frage (`task_questions.assignee_id`) und Review. Reviews nutzen
   das vorhandene `reviewer_id` weiter; nach außen heißt es zusätzlich `assigneeID`. Keine zweite Wahrheit, alte Clients
   (`reviewerID`) bleiben gültig. Mehrere Zuständige und Teams als Zuständige gibt es nicht.
2. **Rechte.** Zuweisbar ist nur, wer am Projekt das Recht hat, mit dem Eintrag etwas zu tun: Karte `read`, Frage `comment`, Review
   `edit` (bisher reichte beim `reviewerID` `read`, damit konnte diese Person nie entscheiden). Zuweisen verlangt `edit`. Eine benannte
   Review lenkt nur diese Person oder `manage` um; das gilt auch beim erneuten Anfragen derselben Review (ohne Person bleibt die
   benannte, früher wurde sie gelöscht).
3. **Wirkung wird berechnet, nicht aufgeräumt** (`ResponsibilityResolver`): bei jedem Lesen und vor jedem Versand zählt eine
   Zuweisung nur, solange die Person das nötige Recht hat und nicht gesperrt ist. Entzug, Teamaustritt, Verschieben von Projekten
   und Kontosperre brauchen so keinen eigenen Aufräumweg; neu freigegeben wirkt die Zuweisung wieder. Folge: `assigneeID` kann auf eine
   Person ohne Zugriff zeigen. Aufgeräumt wird nur beim Projektwechsel einer Karte (Ziel nicht sichtbar) und bei Kontolöschung.
4. **Vererbung von der Karte.** Fragen, Reviews und wartende Pläne ohne eigene Person gehen an die Person der Karte, wenn sie das
   nötige Recht hat und nicht selbst gefragt oder angefragt hat; Runner-Einträge nie (eigene Rechte). Erinnerungen gehen an sie statt
   an den Ersteller. Vererbung schränkt nicht ein, wer antworten oder entscheiden darf.
5. **Push.** Gibt es eine zuständige Person, geht die Mitteilung nur an sie (Kategorien und Geräte wie bisher; hat sie sie
   abgeschaltet, erfährt niemand sonst davon). Ohne Zuständigkeit unverändert. Ausnahme: Verliert ein benannter Reviewer `edit`,
   bleibt die Entscheidung bei `manage` (Regel seit ADR 0014), also gehen die Mitteilungen dorthin statt an alle. Späteres Zuweisen
   setzt `assigned_at` und benachrichtigt auch bei älteren Einträgen. Das Abzeichen zählt Einträge anderer Zuständiger nicht.
6. **„Für mich“** (`GET /v1/for-me`, MCP `list_for_me`): offene eigene Karten sowie Fragen und Reviews, für die das Konto nach Punkt
   3 und 4 zuständig ist. Nicht Zugewiesenes fehlt bewusst. Die bestehenden Listen und der Feed „Für dich“ bleiben unverändert.
7. **Datensparsamkeit.** `list_assignees` liefert nur ID, Anzeigename, zuweisbare Arten und `isMe`, nur ab `edit`, bei Verbindungen
   nur für Projekte des Grants. Neu daran: Wer `edit` hat, sieht die Namen aller Personen mit Zugriff (bisher sah die vollständige
   Freigabeliste nur `manage`); ohne das lässt sich niemand zuweisen. Unbekannt, gesperrt und fremd ergeben dieselbe Antwort.
8. **Nur Entwurf** (`x-draft` im Vertrag): Erwähnung und Zuweisung in Kommentaren; Reviews mit angekündigter Folge
   (Deploy-Konzept §8.9). Kommentar-Mitteilungen sind unverändert.

## Folgen

- Migrationen `AddTaskAssignee` (vor dem Sync-Backfill, der Aufgaben über das Modell liest) und `AddQuestionAndReviewAssignment`;
  additiv, drei Indizes, keine Fremdschlüssel. SQLite und MariaDB.
- Handbuch 1.56.0, `oauth-mcp.yaml` 1.19.0, `command-center.yaml` 1.11.0, `push.yaml` 1.3.0; keine neuen Scopes.
- Teil 2 (PWA und iOS) steht in `docs/PLAN-ZUSTAENDIGKEIT-TEIL-2.md`.

## Grenzen

- Mitteilungen sind je Konto und Eintrag dedupliziert (drei Tage); wer zurückbekommt, was ihm kurz vorher zugewiesen war, wird erst
  durch den neuen Zeitstempel erneut benachrichtigt (Sekundenauflösung).
- Karte zuweisen löst selbst keine Mitteilung aus.
- Sehr viele offene Einträge: Push prüft je Lauf höchstens 200 Fragen und 200 Reviews (wie bisher); „Für mich“ kürzt je Liste bei
  `limit` und meldet `truncated`.
