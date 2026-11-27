# Kartentexte für Karte 354ADE12 (Erwartung f-59a9e0c9)

Todolino-MCP war in dieser Sitzung nicht angemeldet. Das Brain trägt diese Texte ein.

## post_progress (Zwischenstände)

1. ADR 0039 (Transport rclone, `c11501e`): rclone kann SFTP/FTP/FTPS, Host-Schlüssel-Pin über known_hosts + host_key_algorithms, FTPS-Zertifikat als einziger Vertrauensanker (--ca-cert), Symlinks aus (skip_links); im Container belegt.
2. Rot `1666ff2`: DeployTargetTests 8 Tests / 56 Fehler, DeployServerTests (echte Container atmoz/sftp, pure-ftpd TLS) 5 Tests / 10 Fehler.
3. Grün `82c750f`: Modell + Migration `CreateDeployTargets`, REST nur Personen, Verbindungstest, Host-Schlüssel-Bestätigung, Abgleich nur lesen, MCP list/test/compare_deploy_target; Deploy-Tests 13/13 grün.

## record_decision (je mit Commit)

- Transport rclone statt nativer SFTP/FTPS-Schicht (ADR 0039, `c11501e`).
- Repo-Seite des Abgleichs = Manifest vom Aufrufer (path, size, sha256), kein Git-Abruf durch den Server in 1a (ADR 0039 Nachtrag).
- FTPS-Pin als PEM-Zertifikat (einziger Vertrauensanker) statt reinem Fingerabdruck (rclone kann nur CA-Datei).
- Private/Loopback-Ziele standardmäßig gesperrt (`DEPLOY_ALLOW_PRIVATE_HOSTS=1` für Tests/eigenes Netz).
- Container-Tests nicht in GitHub CI, lokal per `scripts/test-deploy-servers.sh` (wie MariaDB).
- Selbst umgesetzt statt delegiert (Lino 26.11.: Subagenten sparsam); Gegenlesen per Verifier (Sonnet).

## Letzte Notiz (Abschluss)

Siehe Ende dieser Datei (wird mit Testzahlen, CI-Läufen und Lehre ergänzt).
