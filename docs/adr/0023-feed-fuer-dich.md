# ADR 0023 – Feed "Für dich"

Status: Backend umgesetzt (31.10.2026), SQLite geprüft, MariaDB ungeprüft. Apple/PWA folgen (Etappen 2/3).

## Kontext

Nutzerwunsch (Todolino-Eintrag): erster Tab der Swift-App wie ein Social-Feed. Ganz oben, was einen aktiv braucht, darunter kleine Projektfortschrittsbeiträge; Screenshots direkt sichtbar. Im Klassisch-Modus (je Projekt, PWA) soll kein Agenten-Rauschen erscheinen.

## Entscheidung

`GET /v1/feed?cursor&limit&projectID&mode` (contracts/feed.yaml) liefert eine kontoweite Lesesicht, **keine neue Tabelle, keine Migration**.

- **needsYou** (nur erste Seite, höchstens 10, `needsYouTotal` ehrlich): offene Fragen (blockierende zuerst), ausstehende Reviews, blockierte Aufgaben mit Grund, überfällige/bald fällige Aufgaben. Jede Karte trägt fertige `actions` (Methode, Pfad, Body) auf **bestehenden** Endpunkten, damit REST, MCP und Apps dieselben Fachregeln verwenden; Rechtegrenzen (Frage >= comment und nicht die eigene, Review >= edit und benannter Reviewer, kein Selbst-Review) werden schon beim Zusammenstellen berücksichtigt, die Endpunkte prüfen weiterhin selbst. Fällig: nur Aufgaben, die das Konto angelegt hat (es gibt keine Zuweisung; Annahme, bei Einführung von Assignees ersetzen).
- **posts** werden aus `activity_events` gebildet (eine sortierbare Quelle mit Zeit, Autor, aufgabenbezogen) und mit Fachzeilen angereichert: Fortschrittsnotiz (Text, Prozent), Build-Screenshot (Label, Bild mit `previewURL`), Erledigt (nur wenn die Aufgabe aktuell done ist), Review-Entscheidung, beantwortete Frage, Kommentar, Agentenlauf Start/Ende. Nicht gezeigt: Frage gestellt/Review angefordert (stehen in needsYou), Aufgabe angelegt/verschoben. Plain-Anhänge ohne Build-Eintrag erzeugen kein Ereignis und erscheinen nicht (offen: eigenes Ereignis `attachment.added`).
- **Klassisch** (`mode=classic`): posts nur Kommentare und Erledigtes, needsYou nur Fälligkeiten. `all` = `management`. Der Modus ist ein Abfragefilter; die Zuordnung Projekt -> Modus bleibt Sache des Clients (PWA speichert sie je Projekt), er fragt mit `projectID` + `mode` je Projekt oder kontoweit.
- **Cursor:** das Muster des Aktivitätsfeeds (Zeitstempel als gerundete Zahl) verlor Ereignisse an Seitengrenzen. Hier trägt der Cursor das exakte Bitmuster von `Date.timeIntervalSinceReferenceDate` (nicht `since1970`: die Umrechnung ist nicht verlustfrei, ein Test fand das) plus Ereignis-ID. Die Datenbank engt nur grob ein (`createdAt <= cursor + 1 s`, sortiert, begrenzt); die genaue Grenze und die Gleichstandsreihenfolge (createdAt absteigend, dann id-String absteigend) werden auf den geladenen Werten in Swift entschieden, damit Kollation (SQLite-Text vs. MariaDB-Binary) und Zeitstempelgenauigkeit nichts verschieben. Eine am Abrufrand abgeschnittene Zeitstempelgruppe wird verworfen und mit größerem Fenster erneut gelesen. Getestet mit gleichen Zeitstempeln und Millisekunden-Nachbarn bei limit 1/4/7/100.
- Mehrere Screenshots derselben Build-ID einer Aufgabe werden **innerhalb einer Seite** zu einem Post mit mehreren Bildern; über Seitengrenzen hinweg können sie getrennt erscheinen (bewusst, sonst wäre der Cursor nicht stabil).
- Rechte: `CommandCenterScope` (sichtbare Projekte inkl. Teilprojekte); fremdes/unsichtbares `projectID` ist 404; Inhalte unsichtbarer Projekte tauchen nie auf, Bilder nur von lesbaren Aufgaben. OAuth-Grant-Einschränkung ist über `allowedProjects` vorbereitet, MCP-Werkzeug folgt nicht (nicht verlangt).
- Aktualisierung: der Feed hängt an denselben Tabellen wie der Live-Token (ADR 0022); Clients holen bei Token-Änderung Seite 1 neu. `GET /v1/capabilities.feed = true`.

## Folgen / offen

- MariaDB ungeprüft (Joins über `UUID`-Binärspalten wie im Command Center, aber nicht ausgeführt).
- Skalierung: needsYou lädt je Projektblock (200) offene Fragen/Reviews/Blockierte/Fällige ohne Limit; bei sehr großen Konten Index/Limit nachziehen.
- Zeitzone: "fällig" = innerhalb 24 h ab jetzt, nicht Kalendertag des Nutzers.
