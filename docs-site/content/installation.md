# Installation ohne Quellcode

Für den Betrieb auf einem Docker-Swarm-Server braucht es keinen Quellcode und keinen Build. Der Branch `deploy` enthält nur die Betriebsdateien; das Backend-Image (mit eingebauter PWA) kommt fertig von GHCR. Details und Grenzen: [Betrieb und Swarm](betrieb.html).

## Voraussetzungen

- Ein Server mit Docker im Swarm-Modus und Zugriff auf `ghcr.io`.
- Eine MariaDB (Version 12.3 geprüft), standardmäßig extern; Anhänge liegen in der Datenbank, S3 ist optional.
- Eine öffentliche HTTPS-Adresse (Reverse Proxy mit TLS, außerhalb dieses Stacks). Sie ist zugleich WebAuthn-Origin und OAuth-Issuer.

## Erstinstallation

```sh
git clone --branch deploy --depth 1 https://github.com/MagicalWig34653/todo.git
cd todo
deploy/swarm/setup.sh --dry-run     # zeigt, was passieren würde
deploy/swarm/setup.sh               # interaktiv; auch --non-interactive --answers-file
```

`setup.sh` fragt Stack-Name, Image-Tag (Vorschlag: neuestes `sha-<commit>`), Domain und Datenbank ab, schreibt `deploy/swarm/stack.env` (Modus 600, nicht im Git), legt die Swarm-Secrets an, deployt (Migration zuerst, dann Rolling Update der Replikate) und prüft Health und den AASA-Endpunkt. Wiederholter Aufruf ist idempotent.

## Update

```sh
git pull --ff-only
deploy/swarm/update.sh --dry-run
deploy/swarm/update.sh
```

`update.sh` ermittelt den neuesten `sha-<commit>`-Tag auf GHCR, schreibt ihn in die Env-Datei, führt die Migration mit dem neuen Image aus und startet das Rolling Update. Vorher die Datenbank sichern (`scripts/backup-db.sh`).

## Wichtige Einstellungen

| Variable | Bedeutung |
| --- | --- |
| `RP_ORIGIN`, `RP_ID`, `RP_NAME` | WebAuthn-Origin, -Domain und Anzeigename (Todolino). |
| `OAUTH_ISSUER` | Öffentliche Basis-URL für OAuth und MCP; sonst abgeleitet aus `RP_ORIGIN` (nie localhost in Produktion), siehe [ADR 0016](adr/0016-oauth-issuer-ableitung.md). |
| `AASA_APP_IDS` | App-IDs für Passkeys in den nativen Apps; leer = AASA-Endpunkt antwortet 404. |
| `TODO_IMAGE_TAG` | Image-Tag; für Produktion einen festen `sha-<commit>` oder eine Version. |
| `CLEANUP_INTERVAL_MINUTES`, `SYNC_RETENTION_DAYS` | Cleanup und Sync-Aufbewahrung, siehe [Sync-Aufbewahrung](sync-aufbewahrung.html). |

## Image

`ghcr.io/magicalwig34653/todo-backend` wird für `linux/amd64` und `linux/arm64` gebaut und enthält die PWA ([ADR 0015](adr/0015-pwa-im-backend-image.md)): `/` liefert die App, `/v1`, `/mcp`, `/oauth` und `/.well-known` das Backend. Die Mindestprüfung nach dem Rollout: `curl -sI https://<host>/` und `curl -s https://<host>/.well-known/oauth-protected-resource/mcp`.

## Backup und Restore

`scripts/backup-db.sh <Verzeichnis>` und `scripts/restore-db.sh <Backup> <neue Datenbank>` sichern per `mariadb-dump` mit Prüfsummen und stellen in eine neue Datenbank wieder her. Ein Restore-Smoke ist auf einem Colima-Einzelknoten bestanden; einen echten Server-Restore gibt es als Nachweis noch nicht.

## Was nicht belegt ist

Der Server-Klon des Branches und der Mehrknoten-Betrieb (Rollout und Rollback) sind nicht real getestet, TLS und Reverse Proxy liegen außerhalb des Stacks. Der Stand steht im [Status](status.html).
