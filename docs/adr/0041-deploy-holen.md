# ADR 0041: Holen von Server-Änderungen (Phase 2a)

Status: angenommen (27.11.2026, Karte 354ADE12, Konzept Orchestrator `docs/konzept-deploy-sftp.md`, Abschnitte 3, 8.6 und 8.8)

## Kontext

Auf dem Server eines Deploy-Ziels ändern Personen Dateien direkt (Kubus: der Designer per SFTP). Diese „Drift“ soll als Branch
`server/<ziel>-JJJJ-MM-TT` mit verständlichem Commit ins Repo kommen. Der Todolino-Server hat in dieser Phase **keinen Schreibzugriff auf
GitHub und keine neuen Zugangsdaten**; er ändert auf dem Zielserver nichts.

## Entscheidung

1. **Der Server liefert, der Aufrufer committet.** `POST /v1/deploy-targets/{id}/pull` (Person, `edit`) und das MCP-Werkzeug
   `pull_server_changes` geben die Dateien, den Branch-Namen und eine Commit-Nachricht zurück. Branch, Commit und PR entstehen im
   Checkout der Person oder des Agenten. `scripts/deploy-pull-apply.py` macht das sicher (sauberer Baum, nur Pfade im Repo, nie `.git`,
   keine Symlinks auf dem Weg, Rückbau bei Abbruch, `-2` bei vorhandenem Branch).
2. **Repo-Seite = Manifest vom Aufrufer** (wie in Phase 1a). Optional `eol` je Datei (`lf`, `crlf`, `keep`) sagt, welche Zeilenenden die
   Datei im Repo hat. Geliefert wird nur, was nach dieser Umwandlung vom Repo abweicht (CRLF auf dem Server, LF im Repo = gleich).
   Binärdateien (NUL in den ersten 8000 Bytes) bleiben unberührt. Text, der kein gültiges UTF-8 ist oder mit BOM beginnt, geht als base64.
3. **Geheimnisse und Ausschlüsse werden nie geliefert**, nur als Befund genannt (`findings`, Grund `secret_name`, `blocked_path`,
   `secret_content`, `excluded`, `too_large`, `unreadable`). Namen, gesperrte Pfade (`.git`, `.github`) und Ausschlüsse werden nicht einmal
   heruntergeladen; der Inhalt wird vor der Auslieferung geprüft (`DeploySecretGuard`): private Schlüssel, bekannte Token-Formate,
   Zugangsdaten in URLs, `PDO`/`mysqli_connect` mit Klartext-Passwort, in Konfigurationsdateien Zuweisungen von Passwort, Schlüssel oder Token
   an Literale (auch `env('X', 'fallback')`). Eine Konfigurationsdatei, die kein lesbarer Text ist, gilt als Geheimnis (fail closed).
   Die Prüfung ist eine Heuristik: sie darf zu viel zurückhalten, nie zu wenig; die Person sieht die zurückgehaltenen Namen in der Antwort.
4. **Symlinks bei FTP/FTPS.** SFTP listet und liest keine Symlinks (rclone `skip_links`). FTP listet sie wie Dateien, und der Server folgt
   ihnen beim Herunterladen; rclone kann beide nicht unterscheiden (nur zufällig über die Größe). Deshalb wird vor jedem Lesen jedes
   Verzeichnis auf dem Weg mit `curl` (LIST, Unix-Format `l…`) geprüft; Dateien hinter einem Link werden verworfen, ein nicht lesbarer
   `l`-Eintrag bricht ab. Das Image bekommt dafür das Paket `curl`. Zugangsdaten gehen über eine Konfigurationsdatei (0600), das Zertifikat
   des Ziels bleibt einziger Vertrauensanker. `--ftp-skip-pasv-ip`, damit der Server keine fremde Adresse für den Datenkanal vorgeben kann.
5. **Budget.** `maxBytes` (REST 4 MB, MCP 256 kB, höchstens 16 MB) begrenzt die Antwort; eine Datei geht immer durch. Der Rest steht
   in `remaining` (Repo-Pfade), der nächste Aufruf nimmt `paths`. Dateien über 8 MB: Befund `too_large`.
6. **Branch-Name** `server/<ziel>-JJJJ-MM-TT` (Ziel-Name ohne Umlaute und Sonderzeichen, Tag in Europe/Berlin). Die Commit-Nachricht nennt
   Ziel, Datum, geänderte und neue Dateien und die nicht geholten Befunde; der Agent soll nach Zweck gruppieren (Konzept 8.6).
7. Rechte: `edit` am Projekt (Dateiinhalte). Die REST-Route nimmt nur Personen-Sitzungen, MCP prüft Grant und Scope `projects:read`.

## Grenzen (Restrisiko)

- Der Inhaltsschutz ist eine Heuristik. Nicht erkannt werden Werte über mehrere Zeilen, ungewöhnliche Schlüsselnamen in Dateien ohne
  Konfigurationsnamen und Geheimnisse in Binärdateien. Konfigurationsdateien über 2 MiB und nicht lesbare gelten als Geheimnis.
- Server, die Symlinks im LIST auflösen (z. B. ProFTPD mit `ShowSymlinks off`), zeigen keine `l`-Einträge; dort schützt nur die chroot
  des Servers (wie in Phase 1a dokumentiert).
- Ein Link mit „ -> “ im Namen wird mit allen möglichen Namen geprüft (eher zu viel als zu wenig). Benutzernamen mit `:` scheitern an
  curl (nur Anmeldefehler, fail closed).
- Das Budget zählt die Größe auf dem Server; base64 und JSON-Escaping machen die Antwort größer (bis etwa das Vierfache).
- Die erste Datei geht immer durch (bis 8 MB), auch bei MCP mit 256 kB.

## Nicht Teil von 2a (offen)

- Täglicher Abgleich und die Karte „Server-Änderungen <Ziel> <Datum>“ mit Qualifizierung (8.6); dafür braucht der Server den Repo-Stand
  ohne Agent.
- **Entscheidung Lino (27.11.2026 23:36, Frage 845A8C49):** Der Server bekommt später **Schreibzugriff über eine GitHub-App**, die
  Branches `server/*` anlegt und PRs öffnet. Rechte minimal: nur Branches `server/*`, kein Schreibrecht auf `main`, lesen für das Manifest.
  Die App und ihre Schlüssel legt Lino an; bis dahin wurde nichts gebaut und nichts hinterlegt. 2a bleibt lesend (Dateien und Manifest);
  der Schreibweg (App-Anmeldung, Branch und Commit über die GitHub-API, PR mit der Zusammenfassung, Autor aus 8.10) gehört in Phase 2b.
  Beim Bau beachten: Schlüssel der App wie die Deploy-Zugangsdaten verschlüsselt (`SETTINGS_ENCRYPTION_KEY`), nie in Antwort oder Log;
  Branch-Namen nur `server/*` serverseitig erzwingen; Dateien gehen durch denselben Geheimnis-Schutz wie beim Holen.
- GitHub-Konto der Person als Commit-Autor (8.10).
- PWA-Knopf „Holen“ und Diff je Datei (Sync-Ansicht).
- Hochladen (Phase 3).

## Folgen

- Vertrag `contracts/deploy.yaml` 1.1.0, `oauth-mcp.yaml` 1.17.0, Handbuch 1.54.0; keine Migration, keine neuen Scopes.
- Tests: `DeployPullTests` (Transport-Double), `DeployServerTests` (echte SFTP-/FTPS-Container, auch der Käfig bei FTP), E2E
  `scripts/deploy-e2e.sh` (REST und MCP gegen das echte Binary; Branch und Commit in einem lokalen Test-Repo; Server danach unverändert).
