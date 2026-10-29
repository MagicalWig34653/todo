# ADR 0011 – Projektspalten (Board pro Projekt)

Status: Backend und PWA-Board-UI implementiert (29.10.2026); Apple-Anbindung offen.

## Anforderung (Nutzer)

Todoist begrenzt die Zahl der Projekte. Der Nutzer hat deshalb ein Projekt als Board missbraucht, dessen Spalten seine eigentlichen Projekte waren (u. a. eine Spalte „Projektideen“). Hier gilt: **Projekte sind unbegrenzt** (es gibt weder ein Limit noch einen Zwang, Projekte als Spalten zu führen), und **jedes Projekt hat eigene, projektspezifische Spalten** (wie Todoist-Abschnitte), in die seine Aufgaben einsortiert werden. Auch ein „Projektideen“-Projekt mit Unterprojekten bleibt ein normales Projekt. Ein früherer Entwurf mit Portfolio-Spalten/Lebenszyklus-Stufen wurde auf Nutzerwunsch verworfen und nie committet.

## Entscheidung

- **Entität `project_columns`**: `id`, `project_id` (FK, Kaskade beim Projektlöschen), `name` (1–100 Zeichen, getrimmt, Nutzerdaten, beliebige Sprache), `color` (optional `#RRGGBB`), `is_done`, `position` (dicht 0..n-1), `version`. Höchstens 200 Spalten je Projekt (422 `too_many_columns`), nur als Missbrauchsschutz.
- **Aufgaben**: neue Felder `tasks.column_id` (nullable = „Ohne Spalte“) und `tasks.board_position` (0-basiert innerhalb der Spalte). Beide erscheinen in `TaskDTO` (`columnID`, `boardPosition`). Kein SQL-Fremdschlüssel auf `column_id` (portabel zwischen SQLite und MariaDB); der Dienst ordnet Aufgaben vor dem Löschen einer Spalte um, unter der Sharing-Graph-Sperre.
- **Keine Zwangsspalten.** Ein neues Projekt hat keine Spalten. `GET /v1/projects/{id}/board` liefert dann `mode: "status"` mit virtuellen Spalten Offen / In Arbeit / In Prüfung / Erledigt aus `task.status` (Reihenfolge wie bisher aus `task_planning.position`). Der Nutzer kann stattdessen eigene Spalten anlegen oder per `POST …/columns/template` die Vorlage `status` (Offen / In Arbeit / Erledigt, deutsche Standardnamen) bzw. die Spalten eines anderen lesbaren Projekts kopieren. Eigene Spalten gibt es also erst auf ausdrücklichen Wunsch; vorhandene Aufgaben werden bei der Vorlage nach Status eingeordnet.
- **Status vs. Spalte.** Der Aufgabenstatus bleibt die Wahrheit für Fertig/Offen (Suche, Heute, Wiederholungen, Agenten). Eine Spalte mit `is_done=true` koppelt die Spalte an `done`:
  - Verschieben in eine `is_done`-Spalte setzt `status=done` (über denselben Pfad wie `PATCH`, also mit Aktivität und Wiederholungs-Nachfolger); Verschieben einer erledigten Aufgabe in eine andere Spalte setzt `open`.
  - Umgekehrt zieht ein Statuswechsel per PATCH/Sync/MCP die Aufgabe in die erste `is_done`-Spalte (bei `done`) bzw. in die erste Nicht-Erledigt-Spalte (beim Wiedereröffnen aus einer Erledigt-Spalte), jeweils ans Ende. Hat das Projekt keine `is_done`-Spalte, bleibt die Spalte unverändert. Zwischenstatus (`in_progress`, `in_review`) bewegen eine Aufgabe nicht von selbst; Spalten sind frei benannt und nicht an sie gebunden.
  - Neue Aufgaben mit `columnID` einer `is_done`-Spalte werden direkt als `done` angelegt.
- **Verschieben von Aufgaben zwischen Projekten** (`projectID` im PATCH/MCP): `column_id` wird auf `null` gesetzt und `board_position` auf 0 („Ohne Spalte“ im Zielprojekt); Spalten sind nie projektübergreifend. Der Client kann danach `PUT /v1/tasks/{id}/column` aufrufen.
- **Löschen einer Spalte** (`DELETE …/columns/{columnID}?moveTo=<id>|none&version=n`): die Aufgaben werden in der bisherigen Reihenfolge ans Ende der Zielspalte angehängt. Standard ohne `moveTo`: erste verbleibende Spalte, sonst „Ohne Spalte“. `moveTo=none` verwirft die Zuordnung. Wandert eine Aufgabe dabei über die `is_done`-Grenze, folgt der Status wie oben. Verbleibende Spalten werden dicht neu nummeriert.
- **Vererbung**: keine. Jedes Projekt, auch jedes Unterprojekt, hat seine eigenen Spalten; sichtbare Elternspalten betreffen es nicht. Ein Unterprojekt kann Spalten per Vorlage `source=<projektId>` kopieren.
- **Rechte** (zentral `ProjectAccess`, keine Umgehung; gleiche Dienstklasse `ColumnService` für REST, MCP und Sync-Feed): Lesen von Spalten und Board mit Rolle `read`; Spalten anlegen/ändern/löschen/Vorlage und Aufgaben verschieben mit Rolle `edit` (wie Aufgaben bearbeiten). Unsichtbare oder fremde Projekte/Aufgaben/Spalten: 404, auch wenn die Spalte zu einem anderen Projekt als im Pfad gehört; sichtbare Objekte mit zu geringer Rolle: 403. Quellprojekt einer Vorlage braucht `read`.
- **Reihenfolge und Konkurrenz.** Alle Schreibvorgänge nehmen zuerst `lockSharingGraph` (gemeinsame Sperrzeile, replikasicher) und bei Aufgaben zusätzlich `lockRow(tasks)`. Positionen sind dicht und werden nach jeder Einfügung/Verschiebung/Löschung neu nummeriert; veränderte Geschwister erhöhen ihre Spaltenversion (Spalten) bzw. nicht ihre Aufgabenversion (nur `board_position` ändert sich, bewusst: Nachbarn sollen durch ein Verschieben keinen 409 für unabhängige Bearbeitungen bekommen). Optimistische Versionen: Spalte (`version` bei PATCH, optional beim Löschen) und Aufgabe (`version` beim Verschieben, immer um 1 erhöht); Abweichung ergibt 409 `version_conflict`. Index außerhalb des Bereichs wird begrenzt, negativ ist 400.
- **Idempotenz**: gleiches Verschieben mit aktueller Version ist kein No-op (die Version steigt); Clients wiederholen nach Netzfehler zuerst die Aufgabe laden und mit der neuen Version senden. Kein Idempotenzschlüssel (bewusst, wie `PATCH /v1/tasks`).
- **Sync-Feed (billig, daher dabei)**: Spalten erscheinen als `entityType: "column"` mit `column: ColumnDTO` (Upsert) bzw. Tombstone (`kind: "delete"`) für die Projektleser; Sichtbarkeitsgewinn/-verlust sowie Projektlöschung erzeugen Spalten-Upserts/Tombstones wie bei Aufgaben. Aufgaben-Upserts tragen `columnID`/`boardPosition`. Ein Verschieben ändert Aufgabe (Upsert) und ggf. Spaltenversionen. **Folgearbeit:** Spalten-Mutationen über `POST /v1/sync/mutations` (Offline-Schreiben); bis dahin laufen Spaltenoperationen online über REST.
- **MCP**: `list_columns` (Scope `projects:read`, liefert das Board eines freigegebenen Projekts) und `move_task_to_column` (Scope `tasks:write`; Aufgabe und Projekt müssen im Grant liegen). Kein Spalten-Schreiben per MCP (Folgearbeit bei Bedarf).
- **Migration** `CreateProjectColumns` (Tabelle plus zwei `ALTER TABLE tasks`, je Spalte ein Statement wegen SQLite), vor `CreateSyncSchema` registriert, weil dessen Backfill das Aufgabenmodell liest. Additiv: alte Replikate ignorieren die neuen Spalten; bestehende Aufgaben haben `column_id=null`, `board_position=0`.

## Verworfen

- Benutzerdefinierte Portfolio-Spalten über Projekte hinweg und Projekt-Platzierung je Konto: erzwingt das Todoist-Missbrauchsmuster und manuelles Einsortieren.
- Automatisch abgeleitete Projektstufen (Idee/Aktiv/Pausiert/Erledigt): nicht gewünscht.
- Gebrochene (fraktionale) Positionen: bei dicht nummerierten, kleinen Spalten und globaler Schreibsperre unnötig; Neunummerierung ist einfacher und eindeutig.
- Spaltenvererbung an Unterprojekte: überraschend und kollidiert mit Eltern-Redaktion bei isolierten Unterprojekten.

## Grenzen / Folgearbeit

- Apple-Anbindung offen. PWA-Board umgesetzt (siehe STATUS „PWA-Umstrukturierung und Board“).
- Sync-Mutationen für Spalten; Spalten-Aktivität im Aufgabenverlauf (aktuell nur die vorhandenen Statusereignisse).
- Spaltenwechsel schreibt keine eigene Aktivität (nur Statuswechsel und Projektwechsel wie bisher).
- Das alte `GET /v1/planning/board` (Status-Spalten, `task_planning.position`) und `PUT /v1/planning/board/reorder` bleiben unverändert für Statusboards bestehen; Boards mit eigenen Spalten nutzen `GET /v1/projects/{id}/board`.
- `GET /v1/projects/{id}/board` ist unpaginiert (wie die Aufgabenliste).

## Prüfung

`Tests/TodoKitTests/ColumnTests.swift`: Statusboard, Vorlagen (Status, Kopie), CRUD/Reihenfolge/Validierung/Versionen, Verschieben mit Positionen, Erledigt-Spalten-Regel in beide Richtungen (auch PATCH), Löschen mit Zielspalte/`none`, Projektwechsel, Kaskade, Rechte (read/edit/Fremder, Pfad-Mismatch, Unauthentifiziert), Sync-Feed inkl. Tombstones, MCP (Scopes, Grant-Grenze, 409), sowie ein MariaDB-Test mit zwei Replikaten (8 gleichzeitige Verschiebungen mit gleicher Version: genau ein Gewinner; 10 parallele Spalten- und 10 Aufgaben-Anlagen: dichte Positionen).
