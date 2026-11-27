# Kartentexte für Karte 354ADE12 (Erwartung f-59a9e0c9)

Todolino-MCP war in dieser Sitzung nicht angemeldet. Das Brain trägt diese Texte ein.

## post_progress (Zwischenstände)

1. ADR 0039 (Transport rclone, `c11501e`): rclone kann SFTP/FTP/FTPS, Host-Schlüssel-Pin über known_hosts + host_key_algorithms, FTPS-Zertifikat als einziger Vertrauensanker (--ca-cert), Symlinks aus (skip_links); im Container belegt.
2. Rot `1666ff2`: DeployTargetTests 8 Tests / 56 Fehler, DeployServerTests (echte Container atmoz/sftp, pure-ftpd TLS) 5 Tests / 10 Fehler.
3. Grün `82c750f`: Modell + Migration `CreateDeployTargets`, REST nur Personen, Verbindungstest, Host-Schlüssel-Bestätigung, Abgleich nur lesen, MCP list/test/compare_deploy_target; Deploy-Tests 13/13 grün.
4. Gegenlesen (Verifier, Sonnet): kein Blocker, 8 Befunde; rot `01bc04a` (2 Tests, 50 Fehler), grün `034f8d6`.
5. Volle Suiten auf `5ffbceb`: SQLite 1095 Tests, 26 übersprungen, 0 Fehler; MariaDB 12.3 1095 Tests, 14 übersprungen, 0 Fehler. E2E `scripts/deploy-e2e.sh` (`eeff1e9`) SQLite und MariaDB je 0 Fehler.

6. Push `1c85aa9`; GitHub grün: CI 46021112677 (Linux 1095 Tests, 31 übersprungen, 0 Fehler), Docker publish 46021112729, Pages 46021112548, E2E 46022940609. Linux-Smoke mit dem veröffentlichten Image gegen SFTP/FTPS: 14 ok.

## record_decision (je mit Commit)

- Transport rclone statt nativer SFTP/FTPS-Schicht (ADR 0039, `c11501e`).
- Repo-Seite des Abgleichs = Manifest vom Aufrufer (path, size, sha256), kein Git-Abruf durch den Server in 1a (ADR 0039 Nachtrag).
- FTPS-Pin als PEM-Zertifikat (einziger Vertrauensanker) statt reinem Fingerabdruck (rclone kann nur CA-Datei).
- Private/Loopback-Ziele standardmäßig gesperrt (`DEPLOY_ALLOW_PRIVATE_HOSTS=1` für Tests/eigenes Netz).
- Container-Tests nicht in GitHub CI, lokal per `scripts/test-deploy-servers.sh` (wie MariaDB).
- Selbst umgesetzt statt delegiert (Lino 26.11.: Subagenten sparsam); Gegenlesen per Verifier (Sonnet).

## Letzte Notiz (Abschluss)

- Phase 1a fertig: Deploy-Ziele, Zugangsdaten, Verbindungstest, Abgleich nur lesen (REST + MCP). Kein Upload, kein Holen, keine PWA-Ansicht, kein Deploy.
- Nächster Schritt 1b: PWA-Ziele (Host-Schlüssel bestätigen, FTP-Warnung) und Sync-Ansicht nur lesen.
- Lehre: Zeit gekostet haben Eigenheiten der Testserver (stilliard-Image nur amd64, pure-ftpd braucht Capabilities, OpenSSH sperrt nach Fehlanmeldungen) und zwei volle Suiten, die neu laufen mussten. Nächstes Mal vor dem vollen Lauf nach festen Versionsprüfungen suchen (`grep` auf alte Handbuch-/Vertragsversion) und das Gegenlesen vor den vollen Lauf legen.
