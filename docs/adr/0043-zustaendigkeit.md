# ADR 0043: Zuständigkeit an Karte, Frage und Review, „Für mich“ und gezielter Push

Status: angenommen (28.11.2026, Karte 8B4BAC2E Teil 1; Anlass: Lino 27.11.2026, „Aufgaben/Rückfragen/Reviews zuweisen, die wirklich
für mich sind“). Betrifft ADR 0014 (Workflow), 0018 (MCP), 0021 (Push). Vertrag: `contracts/assignments.yaml` 1.1.0.
Nachtrag Karte E9300901 (Punkte 9 bis 12): Namen, „betrifft mich“ und Mitteilung beim Zuweisen einer Karte.

## Entscheidung

1. **Höchstens eine Person** je Karte (`tasks.assignee_id`), offener Frage (`task_questions.assignee_id`) und Review. Reviews nutzen
   das vorhandene `reviewer_id` weiter; nach außen heißt es zusätzlich `assigneeID`. Keine zweite Wahrheit, alte Clients
   (`reviewerID`) bleiben gültig. Mehrere Zuständige und Teams als Zuständige gibt es nicht.
2. **Rechte.** Zuweisbar ist nur, wer am Projekt das Recht hat, mit dem Eintrag etwas zu tun: Karte `read`, Frage `comment`, Review
   `edit` (bisher reichte beim `reviewerID` `read`, damit konnte diese Person nie entscheiden). Zuweisen verlangt `edit`. Eine benannte
   Review lenkt nur diese Person oder `manage` um; das gilt auch beim erneuten Anfragen derselben Review (ohne Person bleibt die
   benannte, früher wurde sie gelöscht). Eine Verbindung (MCP) lenkt
   eine benannte Review nur bei eigener Anfrage um oder entfernt die Person (sonst `not_review_requester`): so hebt kein Agent ohne
   Brain-Vollmacht die Bindung fremder Anfragen auf. Eine unbenannte Review darf sie benennen.
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
   setzt `assigned_at` und benachrichtigt auch bei älteren Einträgen, je Person und Eintrag höchstens einmal (Hin- und Herschieben
   erzeugt keine Flut; eine unversendet verworfene Mitteilung wird nachgeholt, wenn der Eintrag zurückkommt). „Höchstens einmal“ gilt,
   solange die Zeile im Postausgang liegt (siehe Grenzen). Das Abzeichen zählt Einträge anderer Zuständiger nicht.
6. **„Für mich“** (`GET /v1/for-me`, MCP `list_for_me`): offene eigene Karten sowie Fragen und Reviews, für die das Konto nach Punkt
   3 und 4 zuständig ist. Nicht Zugewiesenes fehlt bewusst. Die bestehenden Listen und der Feed „Für dich“ bleiben unverändert.
7. **Datensparsamkeit.** `list_assignees` liefert nur ID, Anzeigename, zuweisbare Arten und `isMe`, nur ab `edit`, bei Verbindungen
   nur für Projekte des Grants. Neu daran: Wer `edit` hat, sieht die Namen aller Personen mit Zugriff (bisher sah die vollständige
   Freigabeliste nur `manage`); ohne das lässt sich niemand zuweisen. Unbekannt, gesperrt und fremd ergeben dieselbe Antwort.
8. **Nur Entwurf** (`x-draft` im Vertrag): Erwähnung und Zuweisung in Kommentaren; Reviews mit angekündigter Folge
   (Deploy-Konzept §8.9). Kommentar-Mitteilungen sind unverändert.
9. **Name für Leser** (`assigneeName`): Wer eine Karte, Frage oder Review lesen darf, bekommt in den REST-Antworten den Anzeigenamen
   der dort gespeicherten Person, nur solange dieses Konto Zugriff auf das Projekt hat und nicht gesperrt ist; nie Anmeldename oder
   E-Mail. Das braucht kein `edit` (Punkt 7 gilt weiter für die Liste aller zuweisbaren Personen). Über MCP steht `assigneeName` nur
   in den Frage- und Review-Kurzfassungen von `get_command_center` (Agenten sehen ID und Name); Sync-Feed und Aufgabenlisten bleiben ohne.
10. **„Betrifft mich“** (Regel des Push-Abzeichens: für das Konto benannt oder für niemanden, direkt oder über die Karte): Feed-Einträge
    „Für dich“ tragen `concernsMe`, die Zusammenfassung der Steuerzentrale `concerningQuestions`, `concerningReviews` und
    `concerningPlans`. Welche Einträge erscheinen und die bisherigen Zahlen bleiben unverändert.
11. **Mitteilung beim Zuweisen einer Karte:** `kind assignment`, Kategorie `assignments`, **Standard aus**. Nur an die neue
    zuständige Person, nie beim Zuweisen an sich selbst (eine Verbindung ist nicht die Person), vor dem Senden erneut geprüft. Der
    Push-Lauf liest die Zuweisungsereignisse seitenweise und nur für nicht erledigte Karten von Empfängern mit eingeschalteter
    Kategorie, damit fremde Ereignisse keine Mitteilung verdrängen.
12. **Entschieden nach Empfehlung** (Karte E9300901): „Für mich“ enthält nur Zugewiesenes (Punkt 6); je Review genau eine Person
    (Punkt 1). Push an mehrere Zuständige eines Deploy-Ziels kommt erst mit der „Review mit Folge“ (Entwurf, Punkt 8).

## Folgen

- Migrationen `AddTaskAssignee` (vor dem Sync-Backfill, der Aufgaben über das Modell liest) und `AddQuestionAndReviewAssignment`;
  additiv, drei Indizes, keine Fremdschlüssel. SQLite und MariaDB.
- Teil 1 (8B4BAC2E): Handbuch 1.56.0, `assignments.yaml` 1.0.0, `oauth-mcp.yaml` 1.19.0, `command-center.yaml` 1.11.0, `push.yaml`
  1.3.0. Karte E9300901: Handbuch 1.57.0, `assignments.yaml` 1.1.0, `command-center.yaml` 1.12.0, `push.yaml` 1.4.0, `feed.yaml`
  1.3.0, ohne neue Migration. Keine neuen Scopes.
- Teil 2 (PWA und iOS) steht in `docs/PLAN-ZUSTAENDIGKEIT-TEIL-2.md`.

## Grenzen

- Die benannte Review bindet das **Entscheiden dieser Review**, sie sperrt nicht die Karte. Wie schon vor ADR 0043 kann, wer `edit`
  hat, die Karte erledigen (die Review wird zurückgezogen) oder in ein anderes Projekt verschieben (dort gelten dessen Rechte), und
  die anfragende Verbindung bzw. Person kann ihre Review zurückziehen und neu anfragen. Soll die Bindung auch das verhindern, ist das
  eine eigene Entscheidung (ändert heutige Rechte).
- Mitteilungen sind je Konto und Eintrag dedupliziert, solange die Zeile im Postausgang liegt: Der Server löscht erledigte Zeilen
  drei Tage nach ihrer Anlage; eine spätere erneute Zuweisung kann dann wieder benachrichtigen.
- Sehr viele offene Einträge: Push prüft je Lauf höchstens 200 Fragen und 200 Reviews (wie bisher); „Für mich“ kürzt je Liste bei
  `limit` und meldet `truncated`.
