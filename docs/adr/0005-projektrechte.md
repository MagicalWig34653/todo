# ADR 0005 – Projektrechte und Vererbung

Status: angenommen für den beauftragten Backend-Schnitt (25.10.2026).

## Entscheidung und Zugriffsmatrix

Die zentrale Prüfung `ProjectAccess` verwendet `SharingAccess`. Kontoadministration ist kein Projektzugriff. Aufgaben folgen ihrem aktuellen Projekt, niemals ihrer Ersteller-ID. Fehlende und unsichtbare Ressourcen liefern 404; sichtbare Ressourcen mit unzureichender Rolle liefern 403.

| Aktion | Read | Comment | Edit | Manage | Eigentümerfähigkeit |
| --- | --- | --- | --- | --- | --- |
| Projekt, Aufgaben, wirksame eigene Sichtbarkeit lesen | ja | ja | ja | ja | ja |
| Kommentare schreiben (späterer Schnitt) | nein | ja | ja | ja | ja |
| Aufgaben erstellen, bearbeiten, verschieben | nein | nein | ja | ja | ja |
| Projekt ändern, verschieben, Unterprojekt erstellen | nein | nein | nein | ja | ja |
| Direkte Freigaben lesen/ändern, Vererbung ändern | nein | nein | nein | ja | ja |
| Eigentümer wechseln, Projekt/Aufgaben löschen | nein | nein | nein | nein | ja |
| Team verwalten | nein | nein | nein | nein | nur aktive Teamadministration |
| Agent starten | nein | nein | nein | nein | separate spätere Runner-/OAuth-Freigabe |

Die Rollen heißen auf der Leitung `read`, `comment`, `edit`, `manage`. Bei mehreren Zugriffswegen gilt die stärkste Rolle. `comment` ist bereits definiert; Kommentarrouten gehören nicht zu diesem Schnitt. Agentenstart bleibt ausdrücklich gesperrt.

## Eigentum und Teams

Ein Projekt hat genau einen Eigentümer: Person oder Team. Persönliches Eigentum verleiht Manage sowie Eigentümerwechsel und Projektlöschung. Bei Teameigentum haben aktive Mitglieder Read; aktive Teamadministratoren haben Manage und die Eigentümerfähigkeiten. Teammitgliedschaft öffnet keine persönlichen Projekte. Eigentümerschaft selbst wird nicht an Unterprojekte vererbt; vererbt werden ausschließlich explizite Grants. Neue Unterprojekte gehören zunächst der anlegenden Person.

Die additive Tabelle `sharing_projects` überschreibt die alte persönliche Eigentümerangabe. Ohne Zeile gelten der bisherige Eigentümer und aktivierte Vererbung. `projects.owner_id` und `tasks.owner_id` bleiben aus Kompatibilitätsgründen Erstellerangaben; nach einem Eigentümerwechsel entstehen daraus keine Rechte. Die bisherige Löschkaskade beim Löschen eines Benutzerkontos bleibt eine Grenze: vor einer künftigen Kontolöschfunktion muss sie migriert werden. Eine solche Route existiert derzeit nicht.

Teams haben eine dauerhaft aktive Gründungsadministration, die nicht entfernt oder herabgestuft werden kann. Weitere Administratoren können eingeladen werden. Mitgliedereinladungen richten sich an vorhandene Konto-UUIDs und bleiben bis zur eigenen Annahme unwirksam. Die vorhandene Konto-/Passkey-Einladung bleibt separat. E-Mail-Versand, Ablauf und Einladungen für noch nicht registrierte Konten sind ein Folgeschritt. Entfernen widerruft auch eine offene Einladung. Teamauflösung ist nicht Teil dieses Vertrags.

## Vererbung

1. Direkte Grants auf dem angefragten Projekt gelten immer.
2. Bei aktivierter Vererbung werden Grants der Eltern bis zur Wurzel einbezogen.
3. Ein Projekt mit `inherits=false` beendet den Aufstieg **nach** seinen direkten Grants. Seine direkten Grants gelten daher weiterhin für normal erbende Nachkommen.
4. Direkte Grants und eigenes Eigentum bleiben bei einer Einschränkung erhalten. Es gibt keine negativen Grants und keine Rollenherabstufung durch einen schwächeren direkten Grant.
5. Ein Zugang zum Unterprojekt erzeugt keinen Zugang zu Eltern oder Geschwistern. Listen liefern nur sichtbare Projekte und Aufgaben; die Eltern-ID wird bei unsichtbaren Eltern ausgeblendet. Es gibt derzeit keine Such-, Datei- oder Zählerrouten. Künftige Endpunkte müssen dieselbe Prüfung vor Ausgabe und Aggregation verwenden.

`GET /v1/projects/{id}/visibility` zeigt die wirksame Rolle und die separaten Fähigkeiten der anfragenden Person. Mit `?userID=…` kann Manage auch die tatsächlich wirksame Sichtbarkeit eines anderen vorhandenen Kontos prüfen, einschließlich fehlenden Zugriffs. Die Grantliste bleibt Manage vorbehalten. Clients sollen nach Änderungen die Projektliste sowie die Sichtbarkeit neu laden. Eine Vorschau hypothetischer Verschiebungen ist noch nicht implementiert.

## Konsistenz und Migration

`CreateSharingSchema` ist eine eigene additive Migration, einmal in `configureMigrations` registriert. Eindeutigkeitsbedingungen verhindern doppelte Mitgliedschaften, Grants und Projektregeln. Typ/UUID-Prinzipale werden unter der gemeinsamen DB-Sperre geprüft; polymorphe Eigentümer-/Grant-Verweise haben keinen SQL-Fremdschlüssel. Personen und Teams können über die implementierten Routen nicht gelöscht werden.

Alle Projekt-/Aufgabenschreibvorgänge und Sharing-Mutationen erwerben vor dem Lesen von Rechten eine gemeinsame persistente Sperrzeile per UPDATE innerhalb der Transaktion. Dadurch werden Freigabeänderungen, Entzug, Verschiebungen und Zyklusprüfung auch zwischen Replikaten geordnet. Die Sperre ist bewusst eine einfache erste Lösung und begrenzt den Schreibdurchsatz; vor größeren Installationen sind geordnet erworbene Teilbaum-/ACL-Sperren zu entwerfen und erneut auf MariaDB zu prüfen. Versionsprüfungen für Projekte, Eigentum und Vererbung verwenden dieselbe Projektversion. Grant-PUT ist pro Prinzipal idempotent und bei unterschiedlichen parallelen Rollen gewinnt der zuletzt serialisierte Aufruf.

Lesezugriffe haben keinen Rechtecache. Nach abgeschlossenem Entzug gestartete Zugriffe sehen den Entzug; bereits laufende Antworten werden nicht rückwirkend abgebrochen. Listen sind noch nicht paginiert und die Auswertung lädt Projekte/Grants wiederholt; dies ist eine dokumentierte Skalierungsgrenze.

Verschiebungen erfordern Manage auf Quelle und Ziel; Verschiebungen ändern die geerbten Grants. Zyklische Verschiebungen liefern 422. Löschkaskaden werden nur erlaubt, wenn die anfragende Person auf **jedem** Nachkommen die Eigentümer-Löschfähigkeit hat; andernfalls 409 ohne Namen oder IDs verborgener Nachkommen.

## Abnahme und Fortsetzung

Tests unter `Tests/TodoKitTests/SharingTests.swift` prüfen getrennte SQLite-TestApps mit gemeinsam genutzter Replikatdatenbank, den Erhalt direkter Grants nach Team-Entzug, Rollen, isolierte Unterprojekte, Eltern-ID-Redaktion, direkten/geerbten Zugriff, Unterbrechung, Teamannahme/-entzug, Eigentümerwechsel und Kaskadenschutz. Der MariaDB-Test verwendet zwei App-Instanzen für gegenläufige Verschiebungen, konkurrierende Grant-PUTs und Entzug über Replikate. Tatsächliche Prüfergebnisse und Umgebungsgrenzen stehen im Abschnitt „Teams/Freigaben“ von STATUS.md; das Vorhandensein eines Tests ist kein Ausführungsnachweis.

Nächster Schritt dieses Arbeitsstrangs: MariaDB-Abnahme, anschließend Clients zur Anzeige/Änderung der wirksamen Freigaben anschließen. Der globale Arbeitsplan bleibt wegen des ausdrücklich eingeschränkten Dateiumfangs unverändert; dieser Checkpoint und STATUS dokumentieren den Teilplan.
