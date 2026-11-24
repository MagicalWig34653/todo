# Todolino: Deploy-Branch

Dieser Branch enthält nur, was für den Betrieb auf einem Docker-Swarm-Server nötig ist: Setup-, Update- und Einstellungsskripte (`settings.sh` samt Tabellen), die Stack-Dateien, Backup/Restore und die Betriebsdokumentation. Der Quellcode liegt auf dem Branch `main` (https://github.com/MagicalWig34653/todo).

**Dieser Branch wird automatisch erzeugt** (Workflow `deploy-branch.yml` auf `main`, ein Commit pro Änderung). Bitte hier nichts direkt ändern, Änderungen gehören nach `main`.

Das Backend-Image kommt fertig von `ghcr.io`, der Server braucht nur Docker (Swarm) und dieses Verzeichnis.

## Installation

```sh
git clone --branch deploy --depth 1 https://github.com/MagicalWig34653/todo.git
cd todo
deploy/swarm/setup.sh            # interaktiv; zuerst: deploy/swarm/setup.sh --dry-run
```

`setup.sh` fragt die Konfiguration ab, schreibt `deploy/swarm/stack.env` (Modus 600, nicht im Git), legt die Swarm-Secrets an, deployt und prüft Health und AASA-Endpunkt. Optionen: `setup.sh --help`.

## Update

```sh
git pull --ff-only
deploy/swarm/update.sh --dry-run   # zeigt, was passieren würde
deploy/swarm/update.sh
```

Das Update führt zuerst die Migration mit dem neuen Image aus und startet danach das Rolling Update. Vorher die Datenbank sichern.

## Einstellungen

```sh
deploy/swarm/settings.sh                      # Menü (braucht whiptail oder dialog und Bash 4.4+)
deploy/swarm/settings.sh --list               # alle Variablen mit Wert, Default und Quelle
deploy/swarm/settings.sh --set KEY=VALUE      # prüft und speichert (mit Sicherung), rollt nie aus
deploy/swarm/settings.sh --check              # gesamte stack.env prüfen
```

`settings.sh` liest `config-registry.tsv`, `config-extra.tsv`, `config-help.tsv` und `stack.env.example` aus demselben Verzeichnis. Ausgerollt wird nur im Menü ("Anwenden") nach Bestätigung oder mit `update.sh`. Optionen: `settings.sh --help`.

## Backup und Restore

```sh
scripts/backup-db.sh NEUES_BACKUP_VERZEICHNIS
scripts/restore-db.sh BACKUP_VERZEICHNIS NEUE_RESTORE_DATENBANK
```

Details, Grenzen und die S3-Variante stehen in `docs/BETRIEB.md`. Hinweis: Verweise dort auf weitere Dokumente (z. B. `docs/ARCHITEKTUR.md`) zeigen auf Dateien, die nur auf `main` liegen.
