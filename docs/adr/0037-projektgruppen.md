# ADR 0037 – Projektgruppen und Auswahlregeln für Brain-Vollmacht und Verbindungen

Status: umgesetzt 26.11.2026 (Karte `BEF08998`, Teil 3), nicht deployt. Ergänzt ADR 0007, 0032 und 0036. Zwei Punkte sind **vorläufig** und werden von Lino im Review entschieden (unten markiert).

## Anlass

Lino 26.11.: „Aber immer wieder alle Projekte auszuwählen nervt. Vielleicht kann man ja Projekttags oder Gruppen einbauen die man dann direkt vergeben kann.“

## Entscheidung

1. **Gruppe** = benannte Projektmenge einer Person (`project_groups`, `project_group_members`). Name je Person ohne Groß/Klein eindeutig, höchstens 50 Gruppen mit je 200 Projekten. Ein Projekt darf in mehreren Gruppen sein. Keine Vererbung auf Unterprojekte (wie ADR 0032). Mitglied werden kann nur ein Projekt, das die Person gerade lesen kann.
2. **Auswahl** eines Grants bzw. einer Vollmacht = ausdrückliche Projekte (bisherige Spalte `projects`, im Code `explicitProjects`) plus optional eine Regelzeile in `project_selections` (Id = Id des Grants bzw. Mandats): `mode` `selected` | `all_except`, `group_ids`, `excluded_project_ids`, `excluded_group_ids`.
3. **Eine Auflösung** (`Connections/ProjectSelection.swift`, `ProjectSelectionResolver.resolve`): (ausdrücklich + Mitglieder der Gruppen + bei `all_except` die eigenen Projekte) − ausgeschlossene Projekte und Gruppen, geschnitten mit den aktuellen Leserechten der Person. Ausschluss gewinnt immer. Nichts wird zwischengespeichert: MCP löst je Anfrage auf, Entscheidungen unter Sperre.
4. **„Eigene“ Projekte** (`all_except`):
   - **Vorläufig (Lino entscheidet im Review):** Teamprojekte zählen nicht, auch nicht für Team-Admins. Nur Besitz als Person (`project_sharing` vor `projects.owner_id`). Teamprojekte und fremde geteilte Projekte kommen nur durch ausdrückliche Wahl oder eine Gruppe dazu.
   - **Vorläufig (Lino entscheidet im Review):** Per MCP `create_project` angelegte Projekte (`agent_created_projects`) fallen nicht automatisch unter „alle außer“, auch nicht bei der anlegenden Verbindung (die bekommt sie wie bisher ausdrücklich). Sonst könnte ein Agent mit `projects:write` fremde Grants und Vollmachten vergrößern. Die Person nimmt sie per Gruppe oder Wahl auf; die Vorschau nennt sie.
5. **Schreiben nur durch die Person** (REST mit Sitzung): Gruppen (`/v1/project-groups`, `/v1/projects/{id}/groups`), Vorschau (`/v1/project-selection/preview`), optionales `selection` bei Vollmacht, `PUT /oauth/grants/{id}/projects` und Zustimmung. MCP nur lesend: `list_project_groups` (nur Gruppen mit erreichbaren Projekten, nur diese), `get_connection.selection` und `brainMandate`.
6. **Einzelprojekte bleiben verträglich** (Teilen-Fenster, Zugriffshinweis, `set_connection_projects`): Hinzufügen hebt einen Ausschluss genau dieses Projekts auf; eine ausgeschlossene Gruppe lehnt ab (`409 excluded_by_group`, nichts wird angewendet). Entfernen eines Projekts, das eine Gruppe oder „alle“ mitbringt, schließt es aus. Ausgeschlossene Projekte erzeugen keine Zugriffshinweise.
7. **Wirkung sofort.** Entfernen aus einer Gruppe oder Löschen wirkt beim nächsten Aufruf. Wird eine **ausgeschlossene** Gruppe gelöscht, bleiben ihre aktuellen Projekte einzeln ausgeschlossen: Löschen erweitert nie.
8. **Vorher/Nachher und Protokoll.** Jede Gruppenänderung berechnet je aktiver Vollmacht und Verbindung die Differenz (`changes[]`, `?dryRun=true` rechnet nur und verwirft). Änderungen an einer aktiven Vollmacht schreiben je Projekt `mandate.group_added` / `mandate.group_removed` in `brain_connection_audits`.
9. **Übernahme (ADR 0036):** Die Regel des Mandats wandert mit, ausdrückliche Projekte bleiben ausdrücklich (Gruppenmitglieder werden nicht festgeschrieben). Jedes Projekt der alten Vollmacht, das die Seite nicht gezeigt hat oder das die neue Auswahl der Verbindung nicht enthält, und jedes abgewählte alte Projekt wird in der neuen Regel ausgeschlossen (auch spätere Gruppenmitgliedschaft oder „alle außer“ bringt es nicht zurück). Vorausgewählt sind nur ausdrücklich genannte Projekte; Gruppen einer Mandatsregel werden nicht in die Verbindung übernommen (vorläufig, die Verbindung wird nie von selbst breiter). Hat sich die Mandatsregel seit dem Anzeigen geändert: `409 takeover_changed`. Die Regel der Verbindung wählt die Person im Formular (vorbelegt mit der alten).

## Sperren (MariaDB)

Reihenfolge überall: Freigabegraph (`sharing_lock`) → Person → Mandat → Grant → Gruppen/Regelzeilen. Gruppenänderungen sperren zusätzlich alle Mandate, dann alle Grants der Person (je nach Id), bevor sie schreiben; Entscheidungen sperren Mandat, dann Grant und lesen dann Regel, Gruppen und Mitglieder mit `FOR UPDATE` (sperrende Lesezugriffe vor dem ersten einfachen Lesen, wegen `innodb_snapshot_isolation`). Alle Wege, die eine Regelzeile anlegen können, halten den Freigabegraph; Widerruf der Vollmacht jetzt ebenfalls.

Gruppenänderungen sperren die Zeilen der Person ohne `ORDER BY id`, sonst läuft MariaDB den ganzen Primärschlüssel ab und sperrt fremde Zeilen.

## Angriffsfläche

- Kein MCP-Schreibweg für Gruppen, Mitgliedschaften, Regeln oder Vollmachten. `create_project`: siehe 4. `move_project` und Unterprojekte: keine Vererbung, daher keine Wirkung (Test). `set_connection_projects` bleibt auf die wirksame Menge der eigenen Vollmacht begrenzt.
- Ein `OAuthGrant` ohne Auflösung erreicht nichts (`effectiveProjects` ist dann leer, Debug-Builds brechen ab): eine vergessene Auflösung fällt geschlossen aus.
- ~~Bewusst offen: Wer einer Person ein Projekt überträgt, erweitert deren „alle außer“.~~ Behoben 26.11.2026, siehe Nachtrag.
- Bewusst offen: Wer eine Gruppe wählt, vertraut auf künftige Mitgliedschaften; die PWA sagt das beim Wählen.

## Daten und Betrieb

Migration `CreateProjectGroups`: vier neue Tabellen, keine Änderung an Bestandsspalten; ohne Regelzeile gilt die bisherige Liste (Migrationstest mit Altstand). `App migrate --yes` vor `serve`. Zurückrollen auf ein altes Image: Regeln werden ignoriert, es gilt die ausdrückliche Liste (enger bei Gruppen, aber bei `all_except` mit Ausschlüssen bleibt nur die ausdrückliche Liste ohne Ausschlussprüfung: ein ausdrücklich genanntes und per Regel ausgeschlossenes Projekt wäre dann wieder erreichbar).

## Verworfen

Tags an Projekten (zweite Vokabelwelt neben Labels, kein Mehrwert gegenüber Gruppen); Vererbung auf Unterprojekte (ein `move_project` würde Rechte verschieben); aufgelöste Liste in der Spalte `projects` nachführen (jede Quelle für Rechte- und Besitzänderungen müsste nachziehen, vergessene Stelle = veraltete Rechte).

## Offen

- Apple-App (Karte `80738AEA`).
- Passkey-Step-up beim Erteilen (offen seit ADR 0032).

## Nachtrag 26.11.2026 – Security-Review (Karte `0E5CCA05`)

1. **Übertragene Projekte (Befund 1).** Ein Projekt, das eine **andere** Person angelegt und der Person übertragen hat (`PUT /v1/projects/{id}/owner`, MCP-Aktion `transfer_project_owner`, Verwaltung „Projekte übertragen“, Team→Person), fällt nicht mehr automatisch unter „alle außer“ – weder bei Verbindungen noch bei der Brain-Vollmacht. Es wird wie ein von Agenten angelegtes behandelt: Aufnahme nur per Gruppe oder ausdrücklicher Wahl; die Vorschau nennt es (`agentCreatedProjectIDs`, Name aus Verträglichkeit behalten; PWA und Zustimmungsseite: „von einem Agenten angelegt oder dir übertragen“). Erkennung ohne neue Spalte: `projects.owner_id` ist die anlegende Person und folgt keinem Besitzerwechsel; „eigen“ für „alle außer“ heißt jetzt Besitz als Person **und** selbst angelegt. Damit sind alle Übertragungswege abgedeckt, auch künftige. Eigene Projekte, die an sich selbst oder über ein Team zurück übertragen werden, bleiben drin. Folge für Bestand: vor dem Fix übertragene Projekte fallen aus „alle außer“ heraus (enger, nie breiter).
2. **Ausschlussliste (Befund 2).** Einzelentfernen (`OAuthGrant.exclude`: Teilen-Fenster, Zugriffshinweis, `set_connection_projects`) darf über 500 Ausschlüsse kommen: Engerwerden darf nie scheitern. Beim Ausschließen werden Ausschlüsse **gelöschter** Projekte entfernt (Ids werden nicht wiederverwendet, Löschen ist endgültig); nur gerade unlesbare bleiben stehen, sonst würde ein späteres erneutes Teilen still verbreitern. Speichern (`PUT /oauth/grants/{id}/projects`, Vollmacht) prüft gegen `max(500, bisherige Anzahl)`: zurückspeichern geht immer, Wachstum darüber nicht. Die Vorschau rechnet nur und prüft keine Grenze. Die Liste ist damit durch die vorhandenen Projekte begrenzt. Verworfen: Grenze ganz streichen (Speichern könnte dann beliebig wachsen); beim Überlauf ablehnen (Engerwerden schlüge fehl).
3. **Teilen-Fenster (Befund 3, Leistung).** `ConnectionService.candidateGrants` lädt Verbindungen und Regelzeilen nur noch von Personen, die das Projekt lesen können (`SyncRecorder.readers`, nur Vererbungskette und Freigaben); vorher alle Regeln aller Personen und je Person der ganze Freigabegraph. Verhalten unverändert, weil die Auflösung ohnehin mit den Leserechten schneidet.
4. **Altbestand.** Vor der Migration `CreateProjectGroups` per MCP `create_project` angelegte Projekte sind nicht in `agent_created_projects` und gelten als eigene; nachtragen lässt sich das nicht (die Herkunft ist nicht gespeichert). Wer das nicht will, schließt sie aus oder wählt „ausgewählte“.
5. **Restrisiken.** (a) Wird das Konto der anlegenden Person gelöscht, setzt die Kontolöschung `projects.owner_id` auf die Nachfolge; ein früher übertragenes Projekt zählt dann als eigenes (selten, durch Kontolöschung der anderen Person ausgelöst). (b) Gleichzeitiges Löschen eines Projekts während einer Gruppen- oder Regeländerung kann unter MariaDB als Fremdschlüssel-/Sperrfehler (1020, Datensatz geändert) abbrechen; die Änderung schlägt dann geschlossen fehl (nichts geschrieben), ein erneuter Versuch hilft.
6. **Verträge.** `connections.yaml` 1.9.0 (Auflösung, Vorschau, Grenze). Agenten-Handbuch unverändert: MCP-Werkzeuge verhalten sich gleich, nur die aufgelöste Menge kann enger sein.

