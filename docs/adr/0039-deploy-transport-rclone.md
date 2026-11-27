# ADR 0039: Deploy-Ziele, Transport über rclone (Phase 1a)

Status: angenommen (27.11.2026, Karte 354ADE12, Konzept Orchestrator `docs/konzept-deploy-sftp.md`, Abschnitt 8 vor 1–7)

## Kontext

Todolino soll SFTP-, FTP- und FTPS-Ziele eines Projekts kennen, die Verbindung prüfen und den Server mit dem Repo-Stand vergleichen
(Phase 1a: nur lesen; Holen, Hochladen und die PWA-Sync-Ansicht folgen). Das Backend ist Swift (Vapor) auf Linux. Swift hat auf
Linux keinen fertigen SFTP- oder FTPS-Client.

Möglichkeiten:

1. **Nativ in Swift:** `swift-nio-ssh` plus eigene SFTP-Schicht (oder die Bibliothek Citadel), dazu ein eigener FTP-/FTPS-Client auf
   SwiftNIO und NIOSSL (Steuerkanal, `AUTH TLS`, `PBSZ`/`PROT P`, passive Datenkanäle mit TLS, `MLSD`).
2. **rclone** als Hilfsprogramm im Container, von Swift mit festen Argumenten aufgerufen.
3. `lftp` als Hilfsprogramm.

## Entscheidung

**rclone** (Option 2), dazu `ssh-keyscan` (OpenSSH) nur zum Lesen des Host-Schlüssels beim ersten Verbinden.

Begründung:

- rclone kann SFTP, FTP, FTPS explizit und implizit mit einer Codebasis und ist breit erprobt (MIT-Lizenz). Ein eigener FTPS-Client
  mit TLS-Datenkanälen, Sitzungswiederaufnahme und den Eigenheiten der Server (pure-ftpd, vsftpd, ProFTPD) wäre ein eigenes Projekt;
  SFTP nativ hieße eine neue Abhängigkeit (Citadel, Fork von swift-nio-ssh) im sicherheitskritischen Pfad.
- Die Prüfungen, die wir brauchen, kann rclone belegt (Container-Tests, siehe unten):
  - **SFTP-Host-Schlüssel fest:** `known_hosts_file` mit genau dem bestätigten Schlüssel und `host_key_algorithms` auf dessen Typ.
    Ein anderer Schlüssel bricht mit `knownhosts: key mismatch` ab. Ohne `host_key_algorithms` scheitert auch der richtige Schlüssel,
    weil der Server sonst einen anderen Typ anbietet.
  - **Symlinks:** `skip_links = true`; Symlinks im Basispfad werden weder gelistet noch gelesen (Käfig gegen Verweise nach außen).
  - **FTPS-Zertifikat:** Systemvertrauen, oder ein von der Person hinterlegtes Zertifikat (PEM) als einziger Vertrauensanker
    (`--ca-cert`). Ein anderes Zertifikat bricht mit `x509: certificate signed by unknown authority` ab.
- Zugangsdaten nie auf der Kommandozeile: rclone bekommt eine Konfigurationsdatei (0600) in einem eigenen Temp-Ordner (0700), der
  nach dem Lauf gelöscht wird. Das Passwort wird vorher per `rclone obscure -` über stdin verschleiert. Ausgaben von rclone
  (stderr) gehen nie in Antworten oder Logs, nur feste Fehlercodes.
- Option 3 (`lftp`) kann SFTP nur über einen externen `ssh`-Prozess, das macht die Schlüsselprüfung umständlicher, und es liefert
  kein maschinenlesbares Listing.

## Folgen

- Das Server-Image braucht `rclone` und `openssh-client` (Dockerfile). Pfad überschreibbar mit `DEPLOY_RCLONE_PATH` und
  `DEPLOY_SSH_KEYSCAN_PATH`. Fehlt rclone, antworten Verbindungstest und Abgleich mit `deploy_transport_unavailable`.
- Je Vorgang mehrere Prozessstarts (Liste, dann ein `copy --files-from-raw` für die zu prüfenden Dateien). Für Phase 1a reicht das.
- Grenzen in Phase 1a:
  - FTP kennt keine Symlink-Kennzeichnung; dort ist der Käfig die chroot des Servers. Todolino schickt in jedem Fall nur Pfade
    ohne `..` und unterhalb des Basispfads.
  - Ziel-Host: Literale private Adressen und Namen, die auf private Adressen zeigen, lehnt der Server beim Speichern und vor jeder
    Verbindung ab (gleiche Sperrliste wie der Webhook, ADR 0035), außer `DEPLOY_ALLOW_PRIVATE_HOSTS=1` (Tests, eigenes Netz).
    rclone löst den Namen selbst noch einmal auf; ein DNS-Rebinding zwischen Prüfung und Verbindung ist damit nicht ganz
    ausgeschlossen. Agenten können Hosts nicht wählen (nur Personen legen Ziele an).
  - Das FTPS-Zertifikat wird als Vertrauensanker hinterlegt, nicht als reiner Fingerabdruck.
- Getestet wird gegen echte Server im Container: `atmoz/sftp` und ein eigenes pure-ftpd-Testimage
  (`scripts/deploy-test-servers/pure-ftpd`, weil das übliche `stilliard/pure-ftpd` nur amd64 ist und unter Rosetta nicht startet).
  Skript: `scripts/test-deploy-servers.sh`.

## Verworfen

- Nativ (Option 1): später möglich, wenn rclone stört (z. B. Prozesskosten bei sehr großen Bäumen). Die Swift-Seite kapselt den
  Transport hinter `DeployTransport`, ein Wechsel betrifft nur diese Schicht.
