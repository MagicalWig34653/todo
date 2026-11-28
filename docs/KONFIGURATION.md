# Konfiguration: Umgebung oder PWA

Entscheidung und Sicherheitsabwägung: [ADR 0025](adr/0025-konfiguration-ueber-die-pwa.md). API: `contracts/admin-settings.yaml`. Fast alle Betriebseinstellungen kann ein **Administrator in der PWA** ändern (Einstellungen > Verwaltung > Server); ohne Neustart und ohne Env-Datei.

## Die Regel: Umgebung zuerst

Für jede Einstellung gilt: **Umgebungsvariable (falls gesetzt und nicht leer) > Wert aus der PWA > Standard.**

- Eine gesetzte Umgebungsvariable **sperrt** die Einstellung: die PWA zeigt sie schreibgeschützt mit dem Hinweis „per Umgebungsvariable festgelegt“ und der Herkunft „Umgebung“.
- Ohne Umgebungsvariable ist die Einstellung in der PWA änderbar. Herkunft „Datenbank“, wenn ein Wert gespeichert ist, sonst „Standard“.
- Entfernst du später die Variable, greift ein in der PWA gespeicherter Wert (er bleibt erhalten).
- Eine **leere** Variable (`SMTP_PORT=`) zählt als nicht gesetzt. Deshalb nutzen die Stack-Dateien `${X:-}` und kein `${X:-standard}`: Standardwerte stehen im Programm, nicht in der Env-Datei, sonst wäre die Einstellung dauerhaft gesperrt.
- Bestehende Installationen laufen unverändert weiter; ihre Env-Werte sind einfach gesperrt. Wer eine Einstellung in die PWA „abgeben“ will, entfernt die Variable (und `stack.env`-Zeile) und rollt neu aus.

## Was wo einstellbar ist

| Kategorie | Einstellung (PWA-Schlüssel) | Umgebung | Wirkt |
| --- | --- | --- | --- |
| Darstellung | Instanzname `branding.instanceName` | `INSTANCE_NAME` | sofort |
| Anmeldung | Passwort-Anmeldung `auth.passwordLoginEnabled` | `PASSWORD_LOGIN_ENABLED` | sofort |
| E-Mail | `mail.enabled`, `smtpHost`, `smtpSecurity`, `smtpPort`, `smtpUser`, **`smtpPassword`** (Geheimnis), `from`, `fromName` | `MAIL_ENABLED`, `SMTP_HOST`, `SMTP_SECURITY`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD[_FILE]`, `MAIL_FROM`, `MAIL_FROM_NAME` | sofort |
| Push | `push.enabled`, `keyId`, `teamId`, `topics`, `environment`, **`key`** (Geheimnis: Inhalt der .p8) | `APNS_ENABLED`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, `APNS_ENVIRONMENT`, `APNS_KEY[_FILE]` | sofort |
| Anhänge | `attachments.storage`, `s3Endpoint`, `s3Bucket`, `s3Region`, **`s3AccessKey`**, **`s3SecretKey`** | `ATTACHMENT_STORAGE`, `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY[_FILE]`, `S3_SECRET_KEY[_FILE]` | sofort |
| Anhänge | `attachments.maxBytes` | `ATTACHMENT_MAX_BYTES` | **nach Neustart** |
| Aufräumen/Sync | `maintenance.cleanupIntervalMinutes`, `syncRetentionDays` | `CLEANUP_INTERVAL_MINUTES`, `SYNC_RETENTION_DAYS` | **nach Neustart** |
| Live | `live.enabled`, `pollMs`, `waitMaxSeconds`, `maxWaitersPerAccount`, `maxWaitersPerReplica`, `clientPollSeconds` | `LIVE_REFRESH_ENABLED`, `LIVE_POLL_MS`, `LIVE_WAIT_MAX_SECONDS`, `LIVE_MAX_WAITERS_PER_ACCOUNT`, `LIVE_MAX_WAITERS_PER_REPLICA`, `LIVE_CLIENT_POLL_SECONDS` | sofort |
| Limits | `limits.rateWindowSeconds`, `loginLimit`, `passwordLimit`, `registerLimit`, `recoveryLimit`, `recoverySeconds`, `recoverySessionSeconds` | `IDENTITY_RATE_WINDOW_SECONDS`, `IDENTITY_LOGIN_LIMIT`, `IDENTITY_PASSWORD_LIMIT`, `IDENTITY_REGISTER_LIMIT`, `IDENTITY_RECOVERY_LIMIT`, `IDENTITY_RECOVERY_SECONDS`, `IDENTITY_RECOVERY_SESSION_SECONDS` | sofort |
| Sicherheit | Zielschutz für Mail und S3 `security.outboundProtection` (`off`, `standard`, `strict`) | `OUTBOUND_TARGET_PROTECTION` | sofort |
| Apple-Apps | `apple.appIds` | `AASA_APP_IDS` | sofort |

„Sofort“ heißt: auf dem ändernden Replikat gleich, auf den übrigen (Swarm: 3 Replikate) nach höchstens etwa 10 Sekunden. „Nach Neustart“: gespeichert, aber erst beim nächsten Start des Dienstes gelesen (Rolling Update genügt). Die PWA kennzeichnet solche Einstellungen.

**Nur per Umgebung oder Docker-Secret** (in der PWA nur lesbar, mit Hinweis): Datenbank-Verbindung (`DB_*`, `DB_PASSWORD_FILE`), `RP_ID`, `RP_ORIGIN`, `RP_NAME`, `OAUTH_ISSUER`, `WEB_ROOT`, der Konfigurationsschlüssel `SETTINGS_ENCRYPTION_KEY` und `BOOTSTRAP_TOKEN`. Grund: ohne Datenbank gibt es keine gespeicherten Werte (Henne und Ei), und ein Fehler bei `RP_ID`/`RP_ORIGIN`/`OAUTH_ISSUER` würde Passkeys und Tokens unbrauchbar machen oder den Zugang zur PWA selbst verschließen.

## Sicherheit

- **Nur Administratoren** sehen und ändern Einstellungen (serverseitig geprüft: ohne Anmeldung 401, ohne Admin-Recht 403). Das erste Konto (Bootstrap) ist Admin; weitere Admins ernennt ein Admin (`PUT /v1/admin/users/{id}/admin`). Mindestens ein Admin bleibt immer.
- **Geheimnisse werden nie angezeigt**, auch Admins nicht: die PWA zeigt „gesetzt“, einen Fingerabdruck (6 Zeichen) und „Ändern“. In der Datenbank liegen sie mit AES-256-GCM verschlüsselt.
- **Jede Änderung wird protokolliert** (wer, wann, welcher Schlüssel, Aktion; nie der Wert) und ist in der PWA als Änderungsprotokoll sichtbar. Tests (Mail, Push, Speicher) werden ebenfalls protokolliert.
- Eingaben werden serverseitig geprüft (Typ, Bereich, Länge, Abhängigkeiten, z. B. „E-Mail an“ braucht Server und Absender). Fehler erklärt der Server auf Deutsch und nennt die betroffene Einstellung.
- **Gleichzeitige Änderung:** wer eine Einstellung speichert, die inzwischen ein anderer Admin geändert hat, bekommt einen Konflikt („neu laden“) statt sie still zu überschreiben.
- **Zugangsdaten gehören zum Ziel.** Ist SMTP-Benutzer oder -Passwort per Umgebung festgelegt, müssen auch Server, Port und Verschlüsselung per Umgebung festgelegt sein (sonst meldet der Server einen Konfigurationsfehler und behält die letzte gültige Konfiguration). Dasselbe gilt für S3-Schlüssel und S3-Endpunkt. In der PWA gespeicherte Zugangsdaten sperren eine Änderung von Server/Port bzw. Endpunkt: erst Zugangsdaten zurücksetzen, Ziel ändern, Zugangsdaten neu eingeben. So kann kein Admin ein Passwort an einen fremden Server schicken lassen.
- **Zielschutz** (Kategorie Sicherheit): Mail-Versand und S3 verbinden nur mit erlaubten Zielen. `standard` (Vorgabe) sperrt Link-Local- und Metadaten-Adressen (169.254.0.0/16 inkl. 169.254.169.254, fe80::/10, fd00:ec2::254, 0.0.0.0/8); lokale Mailserver, MinIO und private Netze bleiben erlaubt. `strict` sperrt zusätzlich Loopback und private Netze (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7); dann muss der Mailserver/S3 öffentlich erreichbar sein. `off` schaltet den Schutz ab. Geprüft wird die tatsächliche IP nach der DNS-Auflösung (Namen, die auf gesperrte Adressen zeigen, werden abgelehnt); die Fehlermeldung nennt nur, dass das Ziel gesperrt ist, nie eine Antwort des Ziels.
- Restrisiko: Ein kompromittiertes Admin-Konto kann zum Beispiel den Mailserver umlenken (ohne die festgelegten Zugangsdaten mitzunehmen). Schutz: Passkey-Anmeldung, wenige Admins, Änderungsprotokoll prüfen.
- `/health/ready` zeigt anonym nur `status`. Wartung, Mail- und Push-Status stehen in `GET /v1/admin/health` (nur Administratoren).

## Konfigurationsschlüssel (für Geheimnisse in der PWA)

Ohne Schlüssel kann die PWA **keine Geheimnisse speichern** (Meldung „Der Server hat keinen Verschlüsselungsschlüssel“); alle übrigen Einstellungen funktionieren. Geheimnisse bleiben dann per Docker-Secret/Umgebung einstellbar (wie bisher).

**Anlegen** (Swarm, einmalig; `setup.sh` fragt das im Schritt „Konfigurationsschlüssel“ und erzeugt es zufällig):

```sh
openssl rand -base64 32 | tr -d '\n' | docker secret create todo_settings_key -
```

Oder mit dem Einstellungsprogramm (legt das Secret nur an, wenn es fehlt, und setzt das Flag; siehe [unten](#einstellungsprogramm-settingssh-env-datei-per-menü-oder-kommandozeile)): `deploy/swarm/settings.sh --generate SETTINGS_ENCRYPTION_KEY`.

In `stack.env`: `SETTINGS_KEY_ENABLED=true` (optional `SETTINGS_KEY_SECRET=<anderer Name>`). `scripts/swarm-deploy.sh` bindet dann das Overlay `stack.settings.yaml` ein (`SETTINGS_ENCRYPTION_KEY_FILE=/run/secrets/settings_key`). Lokal/Entwicklung: `SETTINGS_ENCRYPTION_KEY` in `.env` (siehe `.env.example`). Format: 32 Zufallsbytes als Base64 (44 Zeichen) oder 64 Hex-Zeichen. Ein falsch geformter Schlüssel verhindert den Start (mit klarer Meldung).

**Rotieren:**

1. Neues Secret anlegen (`openssl rand -base64 32 | tr -d '\n' | docker secret create todo_settings_key_2 -`).
2. In `stack.env`: `SETTINGS_KEY_SECRET=todo_settings_key_2` und `SETTINGS_KEY_PREVIOUS_SECRET=todo_settings_key`. Deployen (Overlay `stack.settings-previous.yaml` macht den alten Schlüssel zusätzlich lesbar).
3. Einmalig neu verschlüsseln: in einem Backend-Container `todo-app settings rotate-key --yes` (auch `-y`; meldet die Anzahl; wiederholbar; ohne `--yes` bricht der Befehl mit `confirmation_required` ab).
4. `SETTINGS_KEY_PREVIOUS_SECRET` entfernen, deployen, altes Secret löschen.

**Schlüssel verloren?** Die gespeicherten Geheimnisse sind dann unlesbar (Anzeige „nicht lesbar“). In der PWA „Zurücksetzen“ und neu eingeben; Nicht-Geheimnisse bleiben unberührt.

**Backup-Hinweis:** Der Schlüssel gehört **nicht** in dasselbe Backup wie die Datenbank (sonst schützt die Verschlüsselung nichts). Sichere ihn getrennt (Passwortmanager, getrennter Tresor). Datenbank-Backups ohne Schlüssel sind für Geheimnisse wertlos, aber vollständig für alles andere; nach einer Wiederherstellung ohne Schlüssel gibst du die Geheimnisse neu ein.

## Deploy-Ziele (ADR 0039)

- Zugangsdaten der Deploy-Ziele werden mit `SETTINGS_ENCRYPTION_KEY` verschlüsselt; ohne Schlüssel lässt sich kein Ziel anlegen. `settings rotate-key` verschlüsselt sie noch **nicht** neu: den alten Schlüssel als `SETTINGS_ENCRYPTION_KEY_PREVIOUS` behalten oder die Zugangsdaten neu eintragen.
- Das Image enthält `rclone`, `ssh-keyscan` und `curl` (prüft beim Holen über FTP/FTPS, ob eine Datei ein Symlink ist). Andere Pfade: `DEPLOY_RCLONE_PATH`, `DEPLOY_SSH_KEYSCAN_PATH`, `DEPLOY_CURL_PATH` (nur Umgebung).
- Private und Loopback-Adressen als Ziel sind gesperrt. `DEPLOY_ALLOW_PRIVATE_HOSTS=1` (nur Umgebung) erlaubt sie, z. B. für einen Server im eigenen Netz.
- Pull Requests mit Server-Änderungen (ADR 0042) brauchen eine GitHub-App: `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY[_FILE]`, `GITHUB_APP_REPOSITORIES` (`<Projekt-ID>=owner/repo`, kommagetrennt), nur Umgebung bzw. Docker-Secret, nicht in der PWA. `GITHUB_API_URL` nur für Tests oder GitHub Enterprise (HTTPS). Ohne Angaben abgeschaltet. Anleitung: [GITHUB-APP-EINRICHTUNG.md](GITHUB-APP-EINRICHTUNG.md).

## Einstellungsprogramm `settings.sh` (Env-Datei per Menü oder Kommandozeile)

`deploy/swarm/settings.sh` bearbeitet die Env-Datei (`deploy/swarm/stack.env`) geprüft statt von Hand: mit Menü (`whiptail` oder `dialog`, wie `raspi-config`) oder per Kommandozeile. Es braucht Bash 4.4 oder neuer (Linux-Server: Bash 5; macOS liefert 3.2, dort `brew install bash`). Es ändert **nur die Datei**; ausgerollt wird nichts, außer du bestätigst im Menü „Anwenden“.

```sh
deploy/swarm/settings.sh                          # Menü
deploy/swarm/settings.sh --list                   # alle Variablen mit Wert, Default und Quelle
deploy/swarm/settings.sh --get LIVE_POLL_MS       # einen Wert lesen (Geheimnisse nie)
deploy/swarm/settings.sh --set SYNC_RETENTION_DAYS=30 --set CLEANUP_INTERVAL_MINUTES=120
deploy/swarm/settings.sh --unset SYNC_RETENTION_DAYS   # zurück auf den Default (Zeile wird auskommentiert)
deploy/swarm/settings.sh --info SETTINGS_KEY_ENABLED   # ausführliche Erklärung
deploy/swarm/settings.sh --check                  # ganze Datei prüfen (Typ, Grenzen, Konflikte, unbekannte Variablen)
deploy/swarm/settings.sh --generate SETTINGS_ENCRYPTION_KEY   # Konfigurationsschlüssel anlegen (siehe unten)
deploy/swarm/settings.sh --env /secure/path/todo.env --check  # andere Datei
```

**Beispiele**

- *Konfigurationsschlüssel erzeugen* (auf einem Swarm-Manager): `settings.sh --generate SETTINGS_ENCRYPTION_KEY`. Das Programm legt das Swarm-Secret (Name aus `SETTINGS_KEY_SECRET`, Standard `todo_settings_key`) mit `openssl rand -base64 32` **nur an, wenn es fehlt**, und setzt `SETTINGS_KEY_ENABLED=true` in der Datei. Gibt es das Secret schon, bleibt es unverändert (ein vorhandener Schlüssel wird nie ersetzt) und nur das Flag wird gesetzt. Der Wert wird nie angezeigt, nie in eine Datei geschrieben und nie als Argument übergeben (er geht über stdin an `docker secret create`).
- *Wert setzen:* `settings.sh --set LIVE_POLL_MS=2000`. Ein Wert in der Datei **sperrt** die Einstellung in der PWA (siehe oben); wer sie in der PWA ändern lassen will, nimmt sie mit `--unset` heraus. Zusammengehörige Werte in **einem** Aufruf setzen (`--set MAIL_ENABLED=true --set SMTP_HOST=... --set SMTP_USER=... --set MAIL_FROM=...`): eine Änderung, die allein einen Fehler erzeugen würde, wird nicht gespeichert.
- *Anwenden:* im Menü „Anwenden“. Es ruft nach einer Bestätigung (mit Hinweis auf die Datenbanksicherung) `deploy/swarm/update.sh --env-file <Datei> --tag <aktueller TODO_IMAGE_TAG> --force --yes` auf. Das ist derselbe Weg wie beim normalen Update (Migration, dann Rolling Update über `scripts/swarm-deploy.sh`, Warten auf den Rollout, Health-Check); nur der Image-Tag bleibt, es wird die Konfiguration ausgerollt. Ohne `TODO_IMAGE_TAG` in der Datei gilt der Stack-Standard `edge`. „Trockenlauf“ zeigt dasselbe mit `--dry-run`. Von Hand geht es genauso mit `deploy/swarm/update.sh --tag <Tag> --force`.

**Woher die Angaben kommen:** `config-registry.tsv` wird aus `SettingsRegistry` erzeugt (Typen, Grenzen, Auswahl, Standardwerte der Server-Einstellungen); `SettingsRegistryTSVTests` schlägt fehl, wenn sie veraltet ist, neu erzeugen mit `UPDATE_CONFIG_TSV=1 swift test --filter SettingsRegistryTSV`. `config-extra.tsv` ist handgepflegt (Deploy-Variablen, die der Server nicht liest: Image-Tag, Replikate, Datenbank, Secret-Namen, Platzierung, `RP_ID`/`RP_ORIGIN`/`OAUTH_ISSUER`); der Test prüft, dass jede `${VARIABLE}` der Stack-Dateien dort oder im Register steht. `config-help.tsv` (optional) enthält ausführliche Erklärungen, `stack.env.example` liefert die Vorlagenwerte als Default der Deploy-Variablen. Die Gruppen des Menüs ergeben sich aus den Tabellen.

**Sicherheitsregeln**

- **Geheimnisse nie in der Datei, nie in der Ausgabe:** DB-Passwort, Bootstrap-Token, Konfigurationsschlüssel sowie SMTP-Passwort, APNs-Schlüssel und S3-Schlüssel sind Swarm-Secrets (oder PWA-Werte). `--set` lehnt sie ab und nennt das passende `docker secret create`; `--get` verweigert sie; `--list`, `--check` und das Menü zeigen höchstens `***`. Steht ein Geheimnis trotzdem in der Datei, meldet `--check` einen Fehler (ohne den Wert), und `--unset` löscht die Zeile (statt sie auszukommentieren).
- **Speichern ist atomar:** neue Fassung in eine temporäre Datei im selben Verzeichnis (Modus 0600), Sicherung `<Datei>.bak.JJJJMMTT-HHMMSS` (Modus 0600), dann `mv`. Bricht etwas ab, bleibt die alte Datei unverändert. Die Sicherungen sind per `.gitignore` ausgenommen und enthalten wie die Datei selbst keine Geheimnisse; alte Sicherungen löschst du von Hand.
- **Nichts wird ohne Bestätigung ausgerollt:** `--set`, `--unset` und `--generate` rufen weder `update.sh` noch `scripts/swarm-deploy.sh` auf. Im Menü rollt nur „Anwenden“ nach ausdrücklicher Bestätigung aus; ein Prüfungsfehler in der Datei verhindert es.
- **Die Datei wird nie ausgeführt:** Werte mit `$`, Backtick, Backslash, Zeilenumbruch oder gemischten Anführungszeichen werden abgelehnt (`update.sh` liest die Datei mit `source`). Die Platzierungsangaben prüft dieselbe Funktion wie das Deploy-Skript (`placement.sh`).
- Unbekannte Variablen sind eine Warnung, wenn sie harmlos aussehen, und ein Fehler, wenn der Name auf ein Geheimnis deutet (`…PASSWORD`, `…KEY`, `…SECRET`, `…TOKEN`).
- `--check` fragt Docker nicht ab; ob die genannten Swarm-Secrets existieren, prüft `setup.sh` bzw. der Deploy.

## Mehrere Replikate

Jedes Replikat prüft alle ~10 Sekunden, ob sich Einstellungen geändert haben, und übernimmt sie ohne Neustart (Mail-Client und APNs-Sender werden neu aufgebaut, bei Fehlern bleibt die alte Konfiguration aktiv und der Fehler steht im Log). Mail- und Push-Worker laufen immer und tun nichts, solange das Feature aus ist. Gespeicherte Einstellungen, die beim Start nicht zusammenpassen, verhindern den Start nicht: der Server startet dann nur mit der Umgebung und meldet es im Log. Ein Fehler in der Umgebung selbst bleibt ein Startfehler.

## Test-Knöpfe

- **E-Mail testen:** sendet sofort eine feste Test-Mail über die aktuell geladene Konfiguration an eine angegebene oder die eigene bestätigte Adresse. Fehler werden nach Stufe erklärt (Verbindung, Verschlüsselung, Anmeldung, Absender, Empfänger).
- **Push testen:** prüft, ob der Schlüssel ein Token signieren kann, und sendet an die eigenen Geräte des Admins.
- **Speicher prüfen:** Datenbank erreichbar; bei S3 Schreiben, Lesen und Löschen eines Probeobjekts.

Je Admin höchstens 6 Tests je Art in 10 Minuten.

## Bei Problemen

- Die PWA sagt „per Umgebungsvariable festgelegt“, obwohl du nichts gesetzt hast: Ein Stack-Overlay oder eine Env-Datei setzt die Variable (auch mit Standardwert). `docker service inspect <stack>_backend --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}'` zeigt es.
- Änderung kommt auf einem Replikat nicht an: `docker service logs <stack>_backend | grep "server settings"`. Meldung „not applied“ heißt, die neue Gesamtkonfiguration war dort ungültig (z. B. fehlt der Schlüssel); `lastError` steht in `GET /v1/admin/settings`.
- „nicht lesbar“ bei einem Geheimnis: falscher oder fehlender `SETTINGS_ENCRYPTION_KEY` auf diesem Replikat (alle Replikate brauchen dasselbe Secret).
