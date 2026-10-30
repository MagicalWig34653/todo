# Todo: Deploy-Branch

Dieser Branch enthält nur, was für den Betrieb auf einem Docker-Swarm-Server nötig ist: Setup- und Update-Skripte, die Stack-Dateien, Backup/Restore und die Betriebsdokumentation. Der Quellcode liegt auf dem Branch `main` (https://github.com/MagicalWig34653/todo).

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

## Backup und Restore

```sh
scripts/backup-db.sh NEUES_BACKUP_VERZEICHNIS
scripts/restore-db.sh BACKUP_VERZEICHNIS NEUE_RESTORE_DATENBANK
```

Details, Grenzen und die S3-Variante stehen in `docs/BETRIEB.md`. Hinweis: Verweise dort auf weitere Dokumente (z. B. `docs/ARCHITEKTUR.md`) zeigen auf Dateien, die nur auf `main` liegen.
