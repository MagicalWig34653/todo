# ADR 0042: Pull Request mit Server-Änderungen über eine GitHub-App (Phase 2b, Schreibweg)

Status: angenommen (28.11.2026, Karte 354ADE12; Entscheidung Lino 27.11.2026, Frage 845A8C49: „GitHub-App legt Branches server/*
an und öffnet PRs“). Aufbauend auf ADR 0041 (Holen). Einrichtung: `docs/GITHUB-APP-EINRICHTUNG.md`.

## Entscheidung

1. **Ein Aufruf, ein neuer Branch, ein Commit, ein PR.** `POST /v1/deploy-targets/{id}/pull-request` (Person, `edit`) und MCP
   `open_server_changes_pr` (`projects:write`, Projekt im Grant, `edit`). Die Dateien sind genau die des Holens (gleiche Regeln,
   gleicher Geheimnis-Schutz). Auf dem Zielserver wird nur gelesen.
2. **Basis = Commit des Aufrufers.** Er schickt das Manifest wie beim Holen und `baseCommit`. Der Server prüft, dass der Commit auf
   dem Standard-Branch liegt (sonst käme fremde, ungemergte Arbeit in den PR), setzt den neuen Commit darauf und öffnet den PR gegen
   den Standard-Branch. Hat sich `main` inzwischen geändert, zeigt GitHub Konflikte, statt dass etwas still überschrieben wird. Ein
   Manifest, das nicht zum `baseCommit` passt, ergibt einen entsprechend falschen PR; den sieht eine Person vor dem Merge. Das
   Manifest serverseitig aus dem Repository zu bilden (für die tägliche Drift-Karte) bleibt offen.
3. **Nur `server/*`, nur neu.** Erlaubt sind `server/` plus `a–z`, `0–9`, `-` (geprüft auf Bytes, in der Anfrage **und** im
   GitHub-Client, also vor jedem Aufruf). Der Client kennt nur Lesen sowie Anlegen von Blob, Tree, Commit, Ref und PR; es gibt keinen
   Aufruf zum Verschieben, Löschen oder Mergen. Ein belegter Name bekommt `-2` … `-20`.
4. **Konfiguration nur über Umgebung bzw. Docker-Secret** (`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`,
   `GITHUB_APP_PRIVATE_KEY[_FILE]`, `GITHUB_APP_REPOSITORIES`, optional `GITHUB_API_URL`). Der Schlüssel liegt damit nie in der
   Datenbank oder PWA; die in ADR 0041 notierte Verschlüsselung mit `SETTINGS_ENCRYPTION_KEY` entfällt, weil nichts gespeichert wird.
   Nichts gesetzt: `deploy_github_not_configured`. Unvollständig oder falsch: `deploy_github_config_invalid`, eine Warnung mit den
   Variablennamen; der Server startet.
5. **Betreiber gibt je Projekt frei.** `GITHUB_APP_REPOSITORIES` ordnet Projekt-IDs Repositorys zu. Ohne Eintrag schreibt ein Projekt
   nirgends hin, auch wenn die Installation das Repository erreicht. Repository-Bindungen zählen nicht: sie kann jede Projektleitung
   selbst setzen (mandantenübergreifender Schreibzugriff wäre möglich).
6. **Token je Installation und Lauf**, per RS256-JWT der App (9 Minuten), eingeschränkt auf das eine Repository und
   `contents: write`, `pull_requests: write`. Schlüssel, JWT und Token kommen in keine Antwort und kein Log; Fehlertexte von GitHub
   werden nicht weitergegeben (feste Codes, im Log Schritt und HTTP-Status). Keine Weiterleitungen; HTTPS (HTTP nur zu
   `127.0.0.1`/`localhost` für Tests).
7. **Schutz vor dem Inhalt** (der Server des Ziels ist nicht vertrauenswürdig):
   - nur **private** Repositorys (`deploy_github_repository_public`), weil die Geheimnis-Prüfung eine Heuristik ist;
   - nie Pipeline-Definitionen (`.github`, `.gitlab*`, `Jenkinsfile`, `.circleci`, `.forgejo`, `.gitea`, `.woodpecker*`,
     `.buildkite`, `.semaphore`, `azure-pipelines.yml`, `bitbucket-pipelines.yml`, `.travis.yml`, `.drone.yml`, `.cirrus.yml`,
     `appveyor.yml`, `cloudbuild.yaml`): Befund `blocked_path`;
   - Pfade, an denen im Repository ein Symlink, Submodul oder Datei/Ordner-Konflikt steht: `blocked_path` (Vergleich der Namen nach
     Bytes); vorhandene Datei behält ihren Modus;
   - `@…`, `#1`, `GH-1` in Commit-Nachricht und PR-Text entschärft, PR-Text als Codeblock;
   - höchstens 500 Dateien, davon 50 Binärdateien je Lauf (`remaining`).
8. `pull` bleibt unverändert; `deploy-pull-apply.py` bleibt der Weg ohne App.

## Nachtrag 28.11.2026 (Karte E51E8B8C): eine Betreiber-App, Installation je Nutzer

Auslöser (Lino 28.11.): „Es soll nicht jeder gezwungen sein, eine GitHub-App anzulegen. Ich dachte, das mache ich als Betreiber?“
Entscheidung 4 und 5 oben (eine Installation je Instanz, Zuordnung nur durch den Betreiber in der Umgebung) gelten nur noch als
Übergang. Contracts: `deploy.yaml` 1.3.0, Handbuch 1.58.0; Anleitung: `docs/GITHUB-APP-EINRICHTUNG.md` (Betreiber / Nutzer).

1. **Eine App „Any account“, Installation je Person.** Am Server stehen nur App-ID, privater Schlüssel (Docker-Secret), Slug,
   Client-ID und Client-Secret (Docker-Secret). Nichts je Nutzer in Umgebung oder Settings. Neue Tabellen
   `github_connections` (Person, Installations-ID, Konto, GitHub-Nutzer-ID und -Login), `github_connect_states` (nur Hash,
   10 Minuten, einmalig, an die Person gebunden) und `github_project_repositories` (Projekt → Repository, Repository-ID,
   zuordnende Person). Konto löschen räumt alles ab.
2. **Verbinden gegen Fälschung.** `POST /v1/github/connect` gibt die GitHub-Adresse mit einmaligem `state`; der Rückweg
   (`/github/setup`, `/github/callback`) ist nur mit Personen-Sitzung und passendem, ungebrauchtem `state` gültig (Sperre im
   Datensatz: zwei gleichzeitige Rückrufe verbrauchen ihn nur einmal). Die Installations-ID aus der Adresse gilt **nur**, wenn
   GitHub sie mit dem Nutzer-Token der App (`GET /user/installations`, Code gegen Token getauscht, danach verworfen) für genau
   diese Person nennt (sonst 403 `github_installation_not_yours`). Es wird nur eine Installation **dieser App** akzeptiert.
3. **Zuordnen nur mit `manage`, nur aus eigener Verbindung, nur wo das eigene GitHub-Konto schreiben darf** (Collaborator-
   Berechtigung `admin`/`write`, gleiche GitHub-Nutzer-ID), nur private Repositorys, das Konto der Installation muss der Besitzer
   des Repositorys sein. Wer am Projekt lesen darf, sieht Repository und zuordnende Person, nie die Verbindung. Agenten haben kein
   Werkzeug dafür und sehen nur Codes.
4. **Jede Nutzung prüft neu** (kein Webhook nötig, kein Zwischenspeicher): zuordnende Person nicht gesperrt und weiter `manage`
   (`deploy_github_assignment_revoked`, ohne Aufruf an GitHub), Installation vorhanden und nicht ausgesetzt, Repository noch
   ausgewählt, gleiche Repository-ID, Schreibrecht derselben GitHub-Nutzer-ID. Erst danach wird der Zielserver gelesen. Der Token
   bleibt je Lauf auf das eine Repository und `contents`/`pull_requests: write` begrenzt; alle Schranken aus Entscheidung 3, 6 und
   7 (nur `server/*`, keine Pipeline-Dateien, nur private Repositorys, keine Weitergabe von GitHub-Texten) gelten unverändert.
5. **Übergang.** `GITHUB_APP_INSTALLATION_ID` und `GITHUB_APP_REPOSITORIES` werden weiter gelesen (allein oder neben den neuen
   Variablen) und erscheinen als Quelle „operator“. Ein Repository, das beide Wege nennen, zählt einmal (Betreiber zuerst).
   Mehrere Wege für ein Projekt: wie bisher `repository` angeben (`deploy_github_repository_required`).
6. **Verworfen.** Ein Webhook für Deinstallation und Rechteänderungen (zusätzliche Angriffsfläche und Betrieb; die Prüfung beim
   Zugriff genügt und ist nie veraltet); die Nutzer-Anmeldung über GitHub als Zugang zu Todolino (der Ablauf nutzt GitHub nur als
   Nachweis, wem eine Installation gehört); ein eigener Zwischenspeicher der Repository-Listen.

### Grenzen des Nachtrags

- Der Betreiber besitzt den Schlüssel einer App, die auf Konten **aller** Nutzer installiert ist: technisch erreicht er jedes
  freigegebene Repository (wie bei jeder GitHub-App). Gegenmaßnahmen siehe Anleitung, Abschnitt 5 (Betreiber).
- Die Rechte hängen am GitHub-Konto der Person, die zugeordnet hat; verlässt sie eine Organisation, stoppt die Nutzung (und muss
  neu zugeordnet werden).
- Die Repository-Liste prüft höchstens 100 Repositorys einer Installation (`truncated`); Zuordnung per Namen ist trotzdem möglich.
- Nur gegen nachgestellte GitHub-APIs geprüft (Python- und Swift-Double mit mehreren Nutzern, Installationen, Rechten): Antwortformen
  von `/user/installations`, die Rückkehr mit `code` bei Installation und das Verhalten von GitHub bei Organisationen mit
  Genehmigung sind erst mit der echten App belegt. Das App-Manifest der Anleitung ist ungeprüft.
- Tests: `GitHubConnectTests` (14), E2E `scripts/github-e2e.sh api` (zwei Nutzer, echte SFTP-Server, echte Git-Repositorys) und
  `pwa` (Browser, hell/dunkel, `web/e2e/github-connect.spec.ts`), `web/tests/github.test.ts`.

## Grenzen (Restrisiko)

- `contents: write` erlaubt technisch jeden Branch; die Beschränkung liegt im Server. Rulesets im Repository sind die zweite
  Schranke (Anleitung, Schritt 4).
- Build-Skripte des Projekts selbst lassen sich nicht erkennen: CI darf für `server/**` keine Secrets bekommen (Anleitung).
- Kein Schutz vor vielen Aufrufen (jeder öffnet einen neuen PR; GitHub-Limits gelten für die ganze Installation), kein Zusammenfassen
  mit offenem PR, keine Sperre je Ziel.
- Je Anfrage eine neue HTTPS-Verbindung, Zeitlimit je Anfrage, keines für den ganzen Lauf.
- Nur gegen nachgestellte GitHub-APIs geprüft, nie gegen github.com; Antwortformen und das Verhalten ohne Recht *Workflows* sind erst
  mit der echten App belegt.
- Eine Installation je Instanz (gilt nur noch für die Variablen des Betreibers; siehe Nachtrag: Installation je Nutzer).

## Folgen

- Vertrag `contracts/deploy.yaml` 1.2.0, `oauth-mcp.yaml` 1.18.0, Handbuch 1.55.0; keine Migration, keine neuen Scopes. Neues
  Programmziel `_CryptoExtras` aus dem schon genutzten `swift-crypto`.
- Betrieb: Overlay `deploy/swarm/stack.github.yaml` (`GITHUB_APP_ENABLED=true`), Secret `todo_github_app_key`.
- Tests: `DeployPublishTests` (GitHub-Double mit Signaturprüfung), E2E `scripts/deploy-e2e.sh` Teil 3 (echter SFTP-Container,
  `scripts/fake-github-api.py` über einem echten Git-Repository).
