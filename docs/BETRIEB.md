# Betrieb

Stand: 26.10.2026. Diese Grundlage setzt `docs/ARCHITEKTUR.md` (Swarm und Konsistenz; Betrieb und Prüfung) um. Eine Stack-Datei allein ist kein Betriebsnachweis. Die Laufzeitprüfungen sind am 26.10.2026 auf einem Einzelknoten (Colima) real gelaufen; Grenzen stehen im letzten Abschnitt.

## Voraussetzungen und Konfiguration

Benötigt werden ein erreichbarer Docker-Daemon mit Swarm-Manager, Bash, curl, OpenSSL und `shasum`. `deploy/swarm/stack.yaml` enthält MariaDB 12.3, drei API-Replikate und Adobe S3Mock 5.2.3 als ausschließlich flüchtiges Testdouble. S3Mock ist kein produktiver Speicher; das bestehende Backend hat noch keine Anhang-/S3-Anbindung. Es gibt keine veröffentlichte DB- oder S3-Schnittstelle. HTTP wird standardmäßig auf Port 38080 über das Routing Mesh veröffentlicht (alle Node-Schnittstellen); für Produktion TLS-Ingress, Netzwerkregeln und echte RP-ID/Origin konfigurieren.

Für lokale Images zuerst im Repository ausführen:

```sh
docker compose build backend
```

Für mehrere Nodes ein unveränderliches, auf allen Nodes abrufbares Registry-Image über `BACKEND_IMAGE` setzen, vorzugsweise mit Digest. Die lokale Image-Variante ist für einen Einzelknoten gedacht. Das Deploy-Skript verwendet `--resolve-image never`; die Bereitstellung des Images ist Aufgabe des Betreibers.

Produktive Secrets außerhalb des Repositorys erzeugen und aus geschützten Dateien einlesen, beispielsweise:

```sh
docker secret create todo_db_password /secure/path/db-password
docker secret create todo_db_root_password /secure/path/db-root-password
docker secret create todo_bootstrap_token /secure/path/bootstrap-token
```

Die Pfade sind Platzhalter. Variablen `DB_PASSWORD_SECRET`, `DB_ROOT_PASSWORD_SECRET` und `BOOTSTRAP_TOKEN_SECRET` ändern die externen Secret-Namen. Keine Geheimnisse als CLI-Argumente oder im YAML hinterlegen. Das Backend unterstützt für alle bisher eingelesenen Einstellungen zusätzlich `<NAME>_FILE`, insbesondere `DB_PASSWORD_FILE` und `BOOTSTRAP_TOKEN_FILE`. Die Datei hat Vorrang vor der alten Umgebungsvariable. Unlesbare Dateien und leere Pfadangaben brechen den Start ab; ausschließlich abschließende/führende Zeilenumbrüche werden entfernt, Leerzeichen bleiben erhalten. Eine leere Bootstrap-Datei deaktiviert den Bootstrap. Bisherige Umgebungswerte und Standardwerte gelten weiter, wenn `_FILE` fehlt. Die Swift-Konfigurationsfunktionen können dafür jetzt Fehler werfen.

Genau den vorgesehenen Daten-Node mit `todo.data=true` markieren:

```sh
docker node update --label-add todo.data=true DATA_NODE_ID
```

MariaDB nutzt ein lokales Volume und bleibt an diesen Node gebunden. Nur einen Daten-Node markieren: Das Label macht das Volume nicht verteilt. Nodeverlust bedeutet Ausfall bis zur Wiederherstellung; dies ist weder MariaDB-HA noch ein repliziertes Backup. DB-Verbindungen sind hier unverschlüsselt innerhalb des Overlay-Netzes. Produktionshärtung und Ressourcenbudgets sind gesondert zu planen.

## Start und Migration

```sh
STACK=todo BACKEND_REPLICAS=3 scripts/swarm-deploy.sh
```

Das Skript nimmt eine verteilte Deploy-Sperre über die einmalig anlegbare Swarm-Config `todo_deployment-lock`. Alle Migrationen und Rollouts müssen diesen Einstieg verwenden; manuelle parallele Migrationen umgehen die Sperre. Beim Erststart werden Infrastruktur und ein Backend-Service mit null Replikaten angelegt. Nach DB-Erreichbarkeit startet genau ein Migrationstask mit `migrate --yes`, ohne automatische Wiederholung. Erst ein erfolgreicher neuer Task erlaubt das Deployment der drei Replikate. Der normale Serverstart migriert niemals. Swarm selbst beachtet keine Compose-`depends_on`-Startreihenfolge.

Bei fehlgeschlagenen Migrationen startet kein neuer Backend-Rollout. Bei Timeout/Abbruch während einer möglicherweise noch laufenden Migration bleibt die Sperre absichtlich bestehen. Mit `docker service ps --no-trunc todo_migrate` und `docker inspect TASK_ID` Zustand und Exitcode untersuchen; laufenden Task gegebenenfalls gezielt stoppen und Schema prüfen. Erst nach gesichertem Ende `docker config rm todo_deployment-lock` ausführen. Eine teilweise ausgeführte Migration erfordert fachliche Bewertung vor einer Wiederholung.

## Rollout und Prüfung

Vor einem Rollout DB/S3 sichern und Schemaänderungen auf Kompatibilität mit laufenden alten Replikaten prüfen. `BACKEND_IMAGE` auf das neue Image setzen und dasselbe Deploy-Skript aufrufen. Bestehende Replikate bedienen während der Migration weiter Anfragen. Destruktive Schemaänderungen benötigen Wartungsfenster bzw. mehrere kompatible Schritte. Das Skript setzt beim Update unveränderte DB-/Secret-Einstellungen des vorhandenen Migrationsservices voraus; Credential-/Secret-Rotation und Infrastrukturwechsel separat koordinieren, bevor dieser Ablauf wieder verwendet wird.

Das YAML aktualisiert je eine Backend-Replika, startet die neue zuerst, wartet fünf Sekunden zwischen Schritten und überwacht Fehler 60 Sekunden mit automatischem Rollback. Ein Image-Rollback rollt keine Schemaänderung zurück. Das Deploy-Skript meldet den Start des Rollouts, nicht dessen erfolgreiche Abnahme. `docker service ps todo_backend`, UpdateStatus und die Health-Zustände aller Container prüfen. Der Container-Healthcheck prüft `/health/live` und `/health/ready`; Readiness führt `SELECT 1` aus und beweist keine vollständige Schema-/S3-Betriebsbereitschaft.

```sh
scripts/swarm-smoke.sh
```

Der Smoke verwendet einen eindeutigen eigenen Stacknamen, zufällige Laufzeit-Secrets, drei Replikate und standardmäßig Port 38080. `BACKEND_PORT` kann einen anderen freien Port wählen. Er initialisiert Swarm nur bei Zustand `inactive`, akzeptiert einen bestehenden Einzelknoten-Manager und verweigert Mehrknoten-Cluster. Ein temporär hinzugefügtes Daten-Label wird entfernt, ein vorhandenes `true` erhalten. Anschließend werden alle drei Container auf Health geprüft, beide Health-Routen direkt je Container aufgerufen und 72 HTTP-Anfragen ohne Passkey aus einem Container im Overlay-Netz gegen die Swarm-VIP `backend:8080` ausgeführt (24 je `/health/live`, `/health/ready`, `/v1/capabilities`). Der veröffentlichte Host-Port wird nur informativ geprüft; auf VM-Hosts wie Colima ist er nicht erreichbar. Eine Route `/health` allein existiert nicht.

Anfrage-Logzeilen werden je Container gezählt, soweit die bestehenden Vapor-Logs sie liefern. Darin können Healthchecks enthalten sein; es gibt keinen Replica-Header. Die Zahlen zeigen daher keine garantierte Gleichverteilung der öffentlichen Anfragen. Stack, eigenes DB-Volume und eigene Secrets werden bei Erfolg/Fehler entfernt. Swarm wird nur verlassen, wenn das Skript ihn selbst initialisiert hat. Keine globalen Prune-/Compose-Down-Befehle; fremde Stacks und Port 13306 bleiben unberührt. SIGKILL oder ein verlorener Docker-Daemon können Cleanup verhindern; in diesem Fall ausschließlich die im Lauf ausgegebenen eigenen Ressourcen prüfen.

Das ist eine passkeyfreie Betriebsprobe. Replicaübergreifender Login, OAuth/Uploads, konkurrierende Jobübernahme, Ausfall einer Replica, Rolling-Update unter Last und verlorene Updates benötigen weitere fachliche Prüfungen.

## MariaDB-Backup und nachgewiesener Restore

MariaDB-Container explizit auswählen; die Skripte suchen keine fremden Container. Sie lesen Root-Zugangsdaten innerhalb des Containers aus `MARIADB_ROOT_PASSWORD_FILE` (alternativ bestehendes `MARIADB_ROOT_PASSWORD`) und übergeben sie nicht als Prozessargument. Ausführung auf dem Node mit dem DB-Container:

```sh
DB_CONTAINER=INTENDED_DB_CONTAINER_ID DB_NAME=todo scripts/backup-db.sh /secure/path/new-backup-directory
DB_CONTAINER=DISPOSABLE_DB_CONTAINER_ID scripts/restore-db.sh /secure/path/new-backup-directory restore_probe
```

Das Backupverzeichnis muss neu sein. Es enthält `database.sql` von `mariadb-dump --single-transaction --quick --hex-blob` einschließlich Routinen, Events und Triggern, exakte Zeilenzahlen aller Basistabellen, den Quelldatenbanknamen und SHA-256-Prüfsummen. Während Dump UND Zählung Schreibvorgänge, Jobs und DDL pausieren. Transaktionskonsistenz gilt für InnoDB; nichttransaktionale Tabellen benötigen eine gesonderte Sperrstrategie. Keine Secrets oder Dumps ins Repository schreiben. Verzeichnis mit restriktiven Rechten speichern, verschlüsseln und auf unabhängigem Speicher mit Aufbewahrungsregeln sichern. Datenbankbenutzer/Grants und Serverkonfiguration sind separat zu sichern.

Restore prüft die Prüfsummen, verlangt einen neuen Namen `restore_*`, legt die Datenbank ohne `IF NOT EXISTS` an und importiert anschließend. Ausschließlich vertrauenswürdige eigene Dumps verwenden; SQL wird mit administrativen Rechten ausgeführt. Danach werden die exakten Tabellenzeilenzahlen verglichen; Abweichungen führen zu einem Fehlerstatus. Die Datenbank bleibt zur Prüfung stehen, auch bei Teilfehlern. Der Vergleich allein beweist keine identischen Inhalte oder fachliche Korrektheit. Vor Freigabe zusätzlich Anwendungsabfragen, Constraints, Inhalte und Migrationstand prüfen. Für echte Wiederherstellung zunächst isoliert wiederherstellen und prüfen, dann kontrolliert Konfiguration/Traffic umstellen; das Skript überschreibt absichtlich keine bestehende produktive Datenbank.

```sh
scripts/backup-restore-smoke.sh
```

Diese Probe erstellt einen eigenen MariaDB-Container mit flüchtigem Datenverzeichnis und zufälligem Secret. Sie legt zwei verknüpfte Tabellen mit zwei bzw. drei Zeilen (inklusive Binärwert und NULL) und eine leere Tabelle an, führt die tatsächlichen Backup-/Restore-Skripte aus und vergleicht die Zeilenzahlen nach SQL-Import in `restore_smoke`. Der Container und die temporären Dateien werden anschließend entfernt. Regelmäßig zusätzlich echte, anonymisierte Anwendungssicherungen in einer isolierten Umgebung zurückspielen und Wiederherstellungszeit messen.

## S3-Sicherung

Für Produktion einen echten gemeinsamen S3-kompatiblen Dienst auswählen. Versionierung, unabhängige Kopie/Replikation, Verschlüsselung, Retention sowie erforderliche IAM-/Bucket-Konfiguration sichern. Versionierung allein schützt nicht gegen Kontoverlust oder sämtliche Löschungen. DB-Metadaten und Objektbestand über einen dokumentierten gemeinsamen Sicherungszeitpunkt bzw. eine Schreibpause konsistent halten. Restore muss Objektversionen, Prüfsummen und die Referenzen aus der DB prüfen. S3Mock wird hier bewusst nicht gesichert und verliert seine Objekte beim Containerersatz.

## Tatsächlich ausgeführte Prüfungen am 26.10.2026

Umgebung: macOS, Docker über Colima (Einzelknoten, Swarm vorher `inactive`).

- `swift test --scratch-path /private/tmp/claude-501/sb-ops` nach Merge von main: 37 Tests, 0 Fehler, 6 übersprungen (MariaDB-Tests ohne `TODO_TEST_DB`). `_FILE`-Tests in `SettingsTests` (Priorität, Zeilenenden, leere Datei, Fehlerfälle) laufen grün.
- `docker compose build backend`: erfolgreich (Image `todo-dev-backend:local`).
- `scripts/backup-restore-smoke.sh`: bestanden. Prüfsummen OK, Zeilenzahlen aller Tabellen (inkl. leerer Tabelle, Binärwerte/NULL) nach Restore in `restore_smoke` identisch, Wegwerf-Container entfernt. Gefundener Fehler: Bind-Mount der Temp-Datei scheitert bei Colima (Host-Temp nicht in der VM); jetzt `docker cp`.
- `scripts/swarm-smoke.sh`: bestanden (Exit 0) mit 3 Replikaten, Migration als einmaliger Task, alle drei Container healthy, Live-/Ready-Check je Container, 72 In-Cluster-Probes über die VIP ohne Fehler, Cleanup vollständig (Stack, Netz, Config, Secrets, Volume, Label; Swarm wieder `inactive`). Gefundene und behobene Fehler: `docker node inspect self` funktioniert mit Node-ID statt `self`; die DB-Wartebedingung (`mariadb-admin ping` ohne Auth) schlug fehl und nutzt jetzt den Container-Healthstatus; Volume-Cleanup wartet auf das Ende der Task-Container.

Grenzen, nicht bewiesen:
- Host-Port 38080 war von macOS aus nicht erreichbar (Colima leitet Swarm-Ingress nicht weiter); das Routing Mesh von außen ist ungeprüft.
- Die Request-Logzählung je Replika liefert 0, da Vapor im Production-Logging keine Zeilen schreibt; Lastverteilung über die VIP ist daher nicht belegt.
- Nur ein Knoten: kein Mehrknoten-Verhalten, kein Node-Verlust, kein Rolling-Update unter Last, kein Rollback, kein Replica-Ausfall, kein Login über Replikas.
- Restore wurde mit synthetischen Daten geprüft, nicht mit einer echten Anwendungsdatenbank; S3 ist nur S3Mock.
