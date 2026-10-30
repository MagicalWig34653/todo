# Betrieb

Stand: 26.10.2026. Diese Grundlage setzt `docs/ARCHITEKTUR.md` (Swarm und Konsistenz; Betrieb und Prüfung) um. Eine Stack-Datei allein ist kein Betriebsnachweis. Die Laufzeitprüfungen sind am 26.10.2026 auf einem Einzelknoten (Colima) real gelaufen; Grenzen stehen im letzten Abschnitt.

## Voraussetzungen und Konfiguration

Benötigt werden ein erreichbarer Docker-Daemon mit Swarm-Manager, Bash, curl, OpenSSL und `shasum`. `deploy/swarm/stack.yaml` enthält nur noch die drei API-Replikate und den einmaligen Migrationsservice. **MariaDB ist extern** und muss von allen Swarm-Nodes erreichbar sein; der Stack enthält weder DB-Container noch Volumes. Anhänge liegen standardmäßig in dieser Datenbank; **S3 ist optional** (Abschnitt „Anhang-Speicher“, Overlay `deploy/swarm/stack.s3.yaml`). Der Entwicklungsstack `compose.yaml` enthält `db`; `s3` (S3Mock) nur unter dem optionalen Profil `s3`. HTTP wird standardmäßig auf Port 38080 über das Routing Mesh veröffentlicht (alle Node-Schnittstellen); für Produktion TLS-Ingress, Netzwerkregeln und echte RP-ID/Origin konfigurieren.

Konfiguration über Umgebungsvariablen: Vorlage `deploy/swarm/stack.env.example` (nur Platzhalter) kopieren, außerhalb des Repositorys ausfüllen und vor dem Deploy laden (`set -a; . /secure/path/todo.env; set +a`). Pflicht ist `DB_HOST`; weiter `DB_PORT`, `DB_NAME`, `DB_USER`, `ATTACHMENT_STORAGE` (Standard `database`), `ATTACHMENT_MAX_BYTES`, `RP_ID`, `RP_ORIGIN`, `BACKEND_REPLICAS`, `BACKEND_PORT`; nur bei S3 zusätzlich `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`. Passwörter und Schlüssel sind ausschließlich externe Swarm-Secrets (siehe unten).

Das Backend-Image kommt aus GHCR: `ghcr.io/magicalwig34653/todo-backend:${TODO_IMAGE_TAG:-edge}` (Name wie in `.github/workflows/docker-publish.yml`; Tags `edge`, `sha-<commit>`, `<version>`, `<major>.<minor>`). Für Produktion `TODO_IMAGE_TAG` auf einen festen Tag setzen statt `edge` (den setzt `deploy/swarm/update.sh` automatisch auf den neuesten `sha-<commit>`-Tag; `latest` gibt es erst nach einem `v*`-Tag). Das Deploy-Skript verwendet `--resolve-image never`; Nodes ziehen das Image beim Taskstart selbst. Für lokale Tests dient der Smoke (er überschreibt das Image per Override-Datei mit `todo-dev-backend:local`, vorher `docker compose build backend`).

Produktive Secrets außerhalb des Repositorys erzeugen und aus geschützten Dateien einlesen, beispielsweise:

```sh
docker secret create todo_db_password /secure/path/db-password
docker secret create todo_s3_access_key /secure/path/s3-access-key
docker secret create todo_s3_secret_key /secure/path/s3-secret-key
docker secret create todo_bootstrap_token /secure/path/bootstrap-token
```

Die Pfade sind Platzhalter. Variablen `DB_PASSWORD_SECRET`, `BOOTSTRAP_TOKEN_SECRET` (und nur mit S3 `S3_ACCESS_KEY_SECRET`, `S3_SECRET_KEY_SECRET`) ändern die externen Secret-Namen. Keine Geheimnisse als CLI-Argumente oder im YAML hinterlegen. Das Backend unterstützt für alle bisher eingelesenen Einstellungen zusätzlich `<NAME>_FILE`, insbesondere `DB_PASSWORD_FILE`, `BOOTSTRAP_TOKEN_FILE`, `S3_ACCESS_KEY_FILE` und `S3_SECRET_KEY_FILE` (S3-Schlüssel jetzt ebenfalls). Die Datei hat Vorrang vor der alten Umgebungsvariable. Unlesbare Dateien und leere Pfadangaben brechen den Start ab; ausschließlich abschließende/führende Zeilenumbrüche werden entfernt, Leerzeichen bleiben erhalten. Eine leere Bootstrap-Datei deaktiviert den Bootstrap. Bisherige Umgebungswerte und Standardwerte gelten weiter, wenn `_FILE` fehlt. Die Swift-Konfigurationsfunktionen können dafür jetzt Fehler werfen.

Datenhaltung, Verfügbarkeit und Sicherung von MariaDB (und, falls genutzt, S3) liegen beim externen Betreiber (HA, Backup, TLS der DB-Verbindung). Das Backend nutzt die DB-Verbindung so, wie sie konfiguriert ist; Produktionshärtung und Ressourcenbudgets sind gesondert zu planen. Der frühere Node-Label `todo.data` wird nicht mehr benötigt.

## Start und Migration

```sh
STACK=todo BACKEND_REPLICAS=3 scripts/swarm-deploy.sh
```

Das Skript nimmt eine verteilte Deploy-Sperre über die einmalig anlegbare Swarm-Config `todo_deployment-lock`. Alle Migrationen und Rollouts müssen diesen Einstieg verwenden; manuelle parallele Migrationen umgehen die Sperre. Beim Erststart werden das Netz und ein Backend-Service mit null Replikaten angelegt. Das Skript wartet nicht mehr auf eine Stack-DB; ist die externe DB nicht erreichbar, schlägt der einzelne Migrationstask fehl (ohne Wiederholung). Es startet genau ein Migrationstask mit `migrate --yes`, ohne automatische Wiederholung. Erst ein erfolgreicher neuer Task erlaubt das Deployment der drei Replikate. Der normale Serverstart migriert niemals. Swarm selbst beachtet keine Compose-`depends_on`-Startreihenfolge.

Bei fehlgeschlagenen Migrationen startet kein neuer Backend-Rollout. Bei Timeout/Abbruch während einer möglicherweise noch laufenden Migration bleibt die Sperre absichtlich bestehen. Mit `docker service ps --no-trunc todo_migrate` und `docker inspect TASK_ID` Zustand und Exitcode untersuchen; laufenden Task gegebenenfalls gezielt stoppen und Schema prüfen. Erst nach gesichertem Ende `docker config rm todo_deployment-lock` ausführen. Eine teilweise ausgeführte Migration erfordert fachliche Bewertung vor einer Wiederholung.

## Rollout und Prüfung

Vor einem Rollout die externe DB und den S3-Speicher sichern und Schemaänderungen auf Kompatibilität mit laufenden alten Replikaten prüfen. `TODO_IMAGE_TAG` auf das neue Image setzen und dasselbe Deploy-Skript aufrufen. Bestehende Replikate bedienen während der Migration weiter Anfragen. Destruktive Schemaänderungen benötigen Wartungsfenster bzw. mehrere kompatible Schritte. Das Skript setzt beim Update unveränderte DB-/Secret-Einstellungen des vorhandenen Migrationsservices voraus; Credential-/Secret-Rotation und Infrastrukturwechsel separat koordinieren, bevor dieser Ablauf wieder verwendet wird.

Das YAML aktualisiert je eine Backend-Replika, startet die neue zuerst, wartet fünf Sekunden zwischen Schritten und überwacht Fehler 60 Sekunden mit automatischem Rollback. Ein Image-Rollback rollt keine Schemaänderung zurück. Das Deploy-Skript meldet den Start des Rollouts, nicht dessen erfolgreiche Abnahme. `docker service ps todo_backend`, UpdateStatus und die Health-Zustände aller Container prüfen. Der Container-Healthcheck prüft `/health/live` und `/health/ready`; Readiness führt `SELECT 1` aus und beweist keine vollständige Schema-/S3-Betriebsbereitschaft.

```sh
scripts/swarm-smoke.sh
```

Da der Stack keine DB enthält, startet der Smoke eine Wegwerf-MariaDB (`mariadb:12.3`) als normalen Container in einem eigenen attachbaren Overlay-Netz und hängt Migration/Backend per Override-Datei (`STACK_EXTRA_FILES`) daran; Der Smoke läuft ohne S3 und ohne S3-Secrets (Standardspeicher Datenbank). Er verwendet einen eindeutigen eigenen Stacknamen, zufällige Laufzeit-Secrets, drei Replikate und standardmäßig Port 38080. `BACKEND_PORT` kann einen anderen freien Port wählen. Er initialisiert Swarm nur bei Zustand `inactive`, akzeptiert einen bestehenden Einzelknoten-Manager und verweigert Mehrknoten-Cluster. Ein temporär hinzugefügtes Daten-Label wird entfernt, ein vorhandenes `true` erhalten. Anschließend werden alle drei Container auf Health geprüft, beide Health-Routen direkt je Container aufgerufen und 72 HTTP-Anfragen ohne Passkey aus einem Container im Overlay-Netz gegen die Swarm-VIP `backend:8080` ausgeführt (24 je `/health/live`, `/health/ready`, `/v1/capabilities`). Der veröffentlichte Host-Port wird nur informativ geprüft; auf VM-Hosts wie Colima ist er nicht erreichbar. Eine Route `/health` allein existiert nicht.

Anfrage-Logzeilen werden je Container gezählt, soweit die bestehenden Vapor-Logs sie liefern. Darin können Healthchecks enthalten sein; es gibt keinen Replica-Header. Die Zahlen zeigen daher keine garantierte Gleichverteilung der öffentlichen Anfragen. Stack, Test-DB-Container, Test-Netz und eigene Secrets werden bei Erfolg/Fehler entfernt. Swarm wird nur verlassen, wenn das Skript ihn selbst initialisiert hat. Keine globalen Prune-/Compose-Down-Befehle; fremde Stacks und Port 13306 bleiben unberührt. SIGKILL oder ein verlorener Docker-Daemon können Cleanup verhindern; in diesem Fall ausschließlich die im Lauf ausgegebenen eigenen Ressourcen prüfen.

Das ist eine passkeyfreie Betriebsprobe. Replicaübergreifender Login, OAuth/Uploads, konkurrierende Jobübernahme, Ausfall einer Replica, Rolling-Update unter Last und verlorene Updates benötigen weitere fachliche Prüfungen.

## MariaDB-Backup und nachgewiesener Restore

Die Backup-Skripte arbeiten gegen einen explizit gewählten MariaDB-Container (z. B. ein Wartungs-/Restore-Container oder die externe DB, sofern als Container erreichbar); für eine rein externe DB stattdessen deren eigene Backupwerkzeuge nutzen. Container explizit auswählen; die Skripte suchen keine fremden Container. Sie lesen Root-Zugangsdaten innerhalb des Containers aus `MARIADB_ROOT_PASSWORD_FILE` (alternativ bestehendes `MARIADB_ROOT_PASSWORD`) und übergeben sie nicht als Prozessargument. Ausführung auf dem Node mit dem DB-Container:

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

## Anhang-Speicher (Datenbank oder optional S3)

Standard ist `ATTACHMENT_STORAGE=database` (ADR 0013): Anhänge liegen in `attachment_blobs` (Blöcke zu 1 MiB, `LONGBLOB`), Metadaten in `attachments`. Kein weiterer Dienst, keine Secrets, Sicherung mit `scripts/backup-db.sh`.

- **Limit:** `ATTACHMENT_MAX_BYTES`, Standard 10485760 (10 MiB), erlaubt 1024 bis 134217728. Uploads werden im Speicher gesammelt; Reverse-Proxy `client_max_body_size` und Timeouts passend setzen (bei 10 MiB mindestens `11m`).
- **MariaDB:** `max_allowed_packet` mindestens 2 MiB (Standard 16 MiB genügt). Wegen der 1-MiB-Blöcke hängt es nicht vom Dateilimit ab. Datenbankgröße und Backup wachsen mit den Anhängen; `innodb_buffer_pool_size` und Backup-Fenster entsprechend planen. Prüfen: `SHOW VARIABLES LIKE 'max_allowed_packet';`.
- **Mehrere Replikate:** keine Besonderheit; alles liegt in der gemeinsamen Datenbank.
- **Aufräumen:** `App cleanup-uploads` regelmäßig planen (entfernt abgelaufene Uploads und Anhänge gelöschter Aufgaben samt Blöcken).
- **S3 aktivieren (optional):** `ATTACHMENT_STORAGE=s3`, `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION` und die zwei Swarm-Secrets für die Schlüssel; `scripts/swarm-deploy.sh` ergänzt das Overlay `deploy/swarm/stack.s3.yaml`, sobald `S3_ENDPOINT` gesetzt ist. Beim Start mit `ATTACHMENT_STORAGE=s3` und fehlenden S3-Angaben bricht das Backend ab. Die Einstellung wirkt nur auf neue Uploads; jede Anhangszeile merkt sich ihren Speicher (`attachments.storage`).
- **Speicher wechseln:** `App attachments migrate-storage --from s3 --to database` (oder umgekehrt) kopiert vollständige Anhänge geprüft (SHA-256), schaltet die Zeile erst nach erfolgreichem Schreiben um und ist wiederholbar. `--dry-run` zählt nur, `--delete-source` löscht die Quelle erst nach dem Umschalten. Im Swarm als einmaliger Container mit den Umgebungswerten und Secrets des Backends starten (`docker run --rm` mit Image, Netz und denselben Variablen, Kommando `attachments migrate-storage …`). Vorher Datenbank sichern. Reihenfolge für S3 nach Datenbank: S3-Variablen/Secrets bereitstellen, Befehl ausführen, dann `ATTACHMENT_STORAGE=database` und S3-Konfiguration entfernen.

## S3-Sicherung (nur bei ATTACHMENT_STORAGE=s3)

Gilt nur, wenn S3 genutzt wird (nicht der Standard). Für Produktion einen echten gemeinsamen S3-kompatiblen Dienst auswählen. Versionierung, unabhängige Kopie/Replikation, Verschlüsselung, Retention sowie erforderliche IAM-/Bucket-Konfiguration sichern. Versionierung allein schützt nicht gegen Kontoverlust oder sämtliche Löschungen. DB-Metadaten und Objektbestand über einen dokumentierten gemeinsamen Sicherungszeitpunkt bzw. eine Schreibpause konsistent halten. Restore muss Objektversionen, Prüfsummen und die Referenzen aus der DB prüfen. Der Stack enthält keinen S3-Dienst; das Backup liegt vollständig beim externen Anbieter.

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

## Nachtrag 27.10.2026: externe DB/S3

Stack auf externe DB/S3 umgestellt (Image `ghcr.io/magicalwig34653/todo-backend`, `stack.env.example`). `docker stack config` mit gesetztem `DB_HOST`/`S3_ENDPOINT` ist gültig (ohne diese Variablen bricht es bewusst ab). `scripts/swarm-smoke.sh` lief danach erneut grün (3 Replikate, Migration, 72 Probes, vollständiges Cleanup) mit externer Wegwerf-DB. Die Aussagen zu Single-Node-Grenzen oben gelten unverändert; die frühere Beschreibung der Stack-DB/S3Mock in den Prüfungen vom 26.10. ist historisch.

## Apple App Site Association (Passkeys in nativen Apps)

Das Backend liefert `GET /.well-known/apple-app-site-association` und `GET /apple-app-site-association` öffentlich (ohne Authentifizierung, ohne Redirect) als `application/json`. Inhalt aus `AASA_APP_IDS` (kommagetrennte App-IDs `TeamID.BundleID`, z. B. `J2DU2P47XW.de.linolaske.todo,J2DU2P47XW.de.linolaske.todo.mac`): `{"webcredentials":{"apps":[...]}}`. Ist `AASA_APP_IDS` nicht gesetzt oder leer, antwortet der Endpunkt mit 404. Produktionsbeispiel für die Domain `todo.linolaske.de`: `RP_ID=todo.linolaske.de`, `RP_ORIGIN=https://todo.linolaske.de` (siehe `deploy/swarm/stack.env.example`). Der Reverse Proxy muss den Pfad unverändert und ohne Redirect durchreichen. Test: `AASATests` (SQLite).

## Erstinstallation mit setup.sh

`deploy/swarm/setup.sh` ist der geführte Assistent für einen produktiven Docker Swarm. Er läuft auf einem Swarm-Manager und führt durch alle Einstellungen des Stacks:

1. Voraussetzungen: `docker`, `curl`, `openssl`; Swarm aktiv und Manager. Ist kein Swarm aktiv, bietet das Skript `docker swarm init` an (nur nach ausdrücklicher Bestätigung, mit Abfrage der Advertise-Adresse; nicht interaktiv nur mit `--swarm-init`).
2. Stack-Name und Image-Tag (Vorschlag: neuestes `sha-<commit>`-Tag auf GHCR, gleiche Suche wie `update.sh`, gemeinsam in `deploy/swarm/lib.sh`).
3. Öffentliche Domain, `RP_ID`, `RP_ORIGIN` (Host muss zur RP_ID passen), Apple Team ID plus Bundle-IDs (ergibt `AASA_APP_IDS`, Format `TeamID.BundleID` wird geprüft), `PASSWORD_LOGIN_ENABLED` (Standard `false`; Passkeys sind der Regelweg).
4. Ingress-Port, Replikate, CPU-/Speicher-Limit je Replikat (`BACKEND_CPU_LIMIT`, `BACKEND_MEMORY_LIMIT`, `0` = unbegrenzt).
5. Externe MariaDB (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`). Danach der optionale Anhang-Speicher: `ATTACHMENT_STORAGE` (Standard `database`, „nein, in der Datenbank speichern“) und `ATTACHMENT_MAX_BYTES`; nur bei `s3` folgen `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION` und die Namen der beiden S3-Secrets. Ein Env-File aus der Zeit vor ADR 0013 mit gesetztem `S3_ENDPOINT` behält als Vorgabe `s3`.
6. Secrets: DB-Passwort, nur bei S3 S3-Access-/Secret-Key (Eingabe verdeckt, doppelt) und Bootstrap-Token (zufällig per `openssl rand -hex 32`, wird genau einmal angezeigt). Vorhandene Secrets werden nie überschrieben; Swarm-Secrets sind unveränderlich, zum Rotieren einen neuen Secret-Namen wählen (`--reconfigure`).
7. Verbindungsprüfungen (abschaltbar mit `--skip-checks`): `select 1` über einen Wegwerf-Container `mariadb:12.3` (optional im Netz `CHECK_NETWORK`) und, nur bei S3, eine Erreichbarkeitsprüfung des S3-Endpunkts samt HEAD auf den Bucket (ohne Signatur, nur Hinweis; die Schlüssel werden nicht geprüft).
8. Zusammenfassung und Bestätigung, dann Env-Datei (`deploy/swarm/stack.env`, Modus 600, in `.gitignore`, ohne Secret-Werte; bestehende Datei wird als `.bak` gesichert), Secrets anlegen, `scripts/swarm-deploy.sh` (Migration, dann Rollout), Rollout abwarten, `/health/ready` über die Domain (sonst Fallback über den Ingress-Port des Knotens, mit Warnung) und der AASA-Endpunkt prüfen (Exit-Code 2, wenn keine Health-Prüfung gelingt).

Aufrufe:

```sh
deploy/swarm/setup.sh                                   # interaktiv
deploy/swarm/setup.sh --reconfigure                     # alle Werte erneut abfragen, vorhandene als Vorgabe
deploy/swarm/setup.sh --dry-run --non-interactive --answers-file answers.env   # Plan, Env in Temp-Verzeichnis, keine Docker-Aufrufe
deploy/swarm/setup.sh --non-interactive --yes --answers-file answers.env --swarm-init
```

Antwortdatei: `KEY=VALUE`-Zeilen (wird geparst, nicht ausgeführt) mit denselben Namen wie in der Env-Datei, zusätzlich `PUBLIC_DOMAIN`, `APPLE_TEAM_ID`, `APPLE_BUNDLE_IDS`, `CHECK_NETWORK`, `SWARM_ADVERTISE_ADDR` und die Secret-Werte `DB_PASSWORD`, `BOOTSTRAP_TOKEN` (nur bei S3 zusätzlich `S3_ACCESS_KEY`, `S3_SECRET_KEY`) (alternativ `<NAME>_FILE` mit Dateipfad). Dieselben Schlüssel gehen als Umgebungsvariable mit Präfix `SETUP_`. Vorrang: Antwortdatei, `SETUP_*`, vorhandene Env-Datei, Standardwert. Eine Antwortdatei mit Secret-Werten gehört außerhalb des Repositorys und mit Modus 600 abgelegt.

Wiederholter Aufruf ist idempotent: Eine vorhandene Env-Datei wird ohne `--reconfigure` unverändert wiederverwendet, vorhandene Secrets bleiben, der Deploy wird als Update ausgeführt. Vor einem Update einer laufenden Installation die Datenbank sichern (`scripts/backup-db.sh`). `update.sh` liest den Stack-Namen (`TODO_STACK`) aus derselben Env-Datei.

Nicht Teil des Skripts: TLS, Reverse Proxy und DNS sind extern. Der Proxy muss auf den veröffentlichten Port der Swarm-Knoten zeigen und `/.well-known/apple-app-site-association` ohne Redirect durchreichen. Labels für einen bestimmten Proxy (z. B. Traefik) sind bewusst nicht enthalten. Nach dem Deploy: App unter `RP_ORIGIN` öffnen, erstes Administrator-Konto mit dem Bootstrap-Token anlegen (danach ist es wirkungslos; das Secret bleibt bestehen, weil `stack.yaml` es referenziert), Backups einrichten (`scripts/backup-db.sh`, Bucket-Sicherung).

**Nachweise (30.10.2026):** `shellcheck` sauber für `setup.sh`, `lib.sh`, `update.sh`. Trockenläufe nicht interaktiv (Antwortdatei, Fehlerfälle für ungültige AASA-IDs und fremden Origin, Wiederverwendung einer erzeugten Env-Datei, Tag-Suche gegen GHCR) und interaktiv über ein Pseudo-Terminal. Realtest auf einem Einzelknoten-Swarm (Colima, nur für den Test initialisiert und danach wieder verlassen; Stack `todosetup`, Wegwerf-MariaDB im eigenen Overlay-Netz, Platzhalter-S3-Endpunkt, lokales Test-Image als `setup-test` getaggt): Lauf 1 legte Env-Datei (600) und vier Secrets an, DB-Test per `mariadb:12.3`-Container erfolgreich, Migration, Rollout 2/2, Bootstrap-Token einmal angezeigt. Lauf 2 (idempotent): Secrets unverändert, Env-Datei unverändert, Update-Deploy erfolgreich. Auf Colima ist der Ingress-Port vom Host aus nicht erreichbar und die Domain im Test fiktiv; daher griff die Rückfallprüfung von innen (`/health/ready` = 200, AASA 200 mit `webcredentials`) mit Warnung. Die Prüfung über echte Domain und echten Ingress-Port sowie echte S3-Schlüssel sind damit nicht getestet. Aufräumen vollständig (Stack, Secrets, Netz, DB-Container, Swarm wieder inaktiv; Timetrack- und andere Container unberührt). Die danach verkürzten Wartezeiten der Hostprüfung wurden nur per shellcheck und Trockenlauf geprüft.

## Update auf das neueste Image (27.10.2026)

`deploy/swarm/update.sh [--env-file F] [--tag TAG] [--stack todo] [--dry-run] [--force] [--yes]` ermittelt den neuesten `sha-<commit>`-Tag auf GHCR (über den Tag `edge`, per Image-Label verifiziert), schreibt ihn als `TODO_IMAGE_TAG` in die Env-Datei (Sicherung als `.bak`), führt über `scripts/swarm-deploy.sh` die Migration mit dem neuen Image aus (mit Deployment-Lock) und beobachtet danach das Rolling Update und `/health/ready`. Vorher die Datenbank sichern (`scripts/backup-db.sh`). Der Trockenlauf (`--dry-run`) wurde gegen die echte Registry geprüft; ein echtes Update auf einem Swarm wurde damit nicht getestet.

## Nachtrag 30.10.2026: Anhänge in der Datenbank (ADR 0013)

S3 ist nicht mehr Pflicht. Stack, `stack.env.example`, `setup.sh` (S3-Fragen nur bei `ATTACHMENT_STORAGE=s3`), `compose.yaml` (`s3` nur im Profil `s3`, Backend ohne `depends_on: s3`) und `scripts/swarm-smoke.sh` (keine S3-Secrets) sind angepasst. **Rollout-Hinweis:** Die Migration `AddAttachmentBlobStorage` ist additiv (Spalte `attachments.storage` mit Default `s3` für Bestandszeilen, neue Tabelle `attachment_blobs`) und läuft wie üblich über den Migrationsdienst. Bestehende Installationen mit S3 setzen `ATTACHMENT_STORAGE=s3` (bzw. behalten die S3-Variablen in der Env-Datei; `swarm-deploy.sh` ergänzt das Overlay), damit neue Uploads dort bleiben, oder migrieren mit `attachments migrate-storage --from s3 --to database`. Ohne diese Einstellung gehen neue Uploads in die Datenbank, alte Anhänge bleiben über ihre Zeilenmarke in S3 lesbar, solange S3 konfiguriert ist.

## PWA im Backend-Image (30.10.2026, ADR 0015)

Das Image liefert die PWA unter `/` und die API unter `/v1`, `/oauth`, `/mcp`, `/.well-known`, `/health` aus derselben Origin (nötig für Passkeys; `RP_ORIGIN` muss die öffentliche URL sein, z. B. `https://todo.linolaske.de`). Die PWA liegt im Image unter `/srv/web` (`WEB_ROOT`, Standard). Fehlt das Verzeichnis, antwortet das Backend wie zuvor nur als API. Der Reverse Proxy reicht alles unverändert an das Backend durch (kein eigener Static-Pfad nötig). Tiefe Links wie `/inbox` liefern `index.html` (nur `GET`/`HEAD` mit `Accept: text/html`); unbekannte API-Pfade bleiben JSON-404. Caching: `/_app/immutable/` ein Jahr, `immutable`; alles andere `no-cache`. Prüfen nach dem Update: `curl -sI https://<host>/` (200, `text/html`) und `curl -s https://<host>/health/ready`. Tests: `WebRootTests` (SQLite).

## Installation ohne Quellcode (deploy-Branch)

Für den Server genügt ein Klon des Branches `deploy`. Er enthält nur die Betriebsdateien (`deploy/swarm/*` mit `setup.sh`, `update.sh`, `lib.sh`, `healthcheck.sh`, `stack.yaml`, `stack.s3.yaml`, `stack.env.example`; `scripts/swarm-deploy.sh`, `backup-db.sh`, `restore-db.sh`, `db-common.sh`; diese Datei; `.gitignore`, ein kurzes `README.md`). Das Backend-Image kommt von GHCR, es wird nichts gebaut.

```sh
git clone --branch deploy --depth 1 https://github.com/MagicalWig34653/todo.git
cd todo && deploy/swarm/setup.sh --dry-run     # dann ohne --dry-run
# später: git pull --ff-only && deploy/swarm/update.sh
```

Der Branch wird nicht von Hand gepflegt: Der Workflow `.github/workflows/deploy-branch.yml` schreibt ihn bei jedem Push auf `main`, der diese Dateien ändert (Pfadfilter im Workflow), mit einem Commit je Sync linear fort (Autor `github-actions[bot]`, kein Force-Push). Quelle der README und der `.gitignore` des Branches ist `deploy/branch/`. Wer eine neue Datei in den Betrieb aufnimmt (z. B. ein weiteres Skript, das `setup.sh` aufruft), muss sie in der Dateiliste und im Pfadfilter des Workflows ergänzen. Verweise in dieser Datei auf andere Dokumente (z. B. `docs/ARCHITEKTUR.md`) zeigen im Branch ins Leere, sie liegen nur auf `main`.

## Image: Multi-Arch (30.10.2026)
Das Backend-Image wird für `linux/amd64` und `linux/arm64` gebaut (Fehler vorher auf arm64-Nodes: `no matching manifest for linux/arm64/v8`). `.github/workflows/docker-publish.yml`: Matrix-Jobs auf `ubuntu-24.04` und `ubuntu-24.04-arm` (nativ, kein QEMU), je Plattform Push per Digest (`push-by-digest`, GHA-Cache mit Scope je Plattform, Provenance/SBOM aus), danach ein Merge-Job mit `docker buildx imagetools create` für `edge`, `sha-<commit>`, `<version>`, `<major>.<minor>`. Alle Tags zeigen auf denselben Index-Digest; `deploy/swarm/lib.sh` (Label-Suche über Index, Plattform-Manifest, Config-Blob) funktionierte unverändert. Gemischte Swarm-Cluster ziehen automatisch die passende Plattform. Dauer des Laufs: ca. 11 Minuten (beide Plattformen parallel).

