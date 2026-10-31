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
| Apple-Apps | `apple.appIds` | `AASA_APP_IDS` | sofort |

„Sofort“ heißt: auf dem ändernden Replikat gleich, auf den übrigen (Swarm: 3 Replikate) nach höchstens etwa 10 Sekunden. „Nach Neustart“: gespeichert, aber erst beim nächsten Start des Dienstes gelesen (Rolling Update genügt). Die PWA kennzeichnet solche Einstellungen.

**Nur per Umgebung oder Docker-Secret** (in der PWA nur lesbar, mit Hinweis): Datenbank-Verbindung (`DB_*`, `DB_PASSWORD_FILE`), `RP_ID`, `RP_ORIGIN`, `RP_NAME`, `OAUTH_ISSUER`, `WEB_ROOT`, der Konfigurationsschlüssel `SETTINGS_ENCRYPTION_KEY` und `BOOTSTRAP_TOKEN`. Grund: ohne Datenbank gibt es keine gespeicherten Werte (Henne und Ei), und ein Fehler bei `RP_ID`/`RP_ORIGIN`/`OAUTH_ISSUER` würde Passkeys und Tokens unbrauchbar machen oder den Zugang zur PWA selbst verschließen.

## Sicherheit

- **Nur Administratoren** sehen und ändern Einstellungen (serverseitig geprüft: ohne Anmeldung 401, ohne Admin-Recht 403). Das erste Konto (Bootstrap) ist Admin; weitere Admins ernennt ein Admin (`PUT /v1/admin/users/{id}/admin`). Mindestens ein Admin bleibt immer.
- **Geheimnisse werden nie angezeigt**, auch Admins nicht: die PWA zeigt „gesetzt“, einen Fingerabdruck (6 Zeichen) und „Ändern“. In der Datenbank liegen sie mit AES-256-GCM verschlüsselt.
- **Jede Änderung wird protokolliert** (wer, wann, welcher Schlüssel, Aktion; nie der Wert) und ist in der PWA als Änderungsprotokoll sichtbar. Tests (Mail, Push, Speicher) werden ebenfalls protokolliert.
- Eingaben werden serverseitig geprüft (Typ, Bereich, Länge, Abhängigkeiten, z. B. „E-Mail an“ braucht Server und Absender). Fehler erklärt der Server auf Deutsch und nennt die betroffene Einstellung.
- **Gleichzeitige Änderung:** wer eine Einstellung speichert, die inzwischen ein anderer Admin geändert hat, bekommt einen Konflikt („neu laden“) statt sie still zu überschreiben.
- Restrisiko: Ein kompromittiertes Admin-Konto kann zum Beispiel den Mailserver umlenken. Schutz: Passkey-Anmeldung, wenige Admins, Änderungsprotokoll prüfen.

## Konfigurationsschlüssel (für Geheimnisse in der PWA)

Ohne Schlüssel kann die PWA **keine Geheimnisse speichern** (Meldung „Der Server hat keinen Verschlüsselungsschlüssel“); alle übrigen Einstellungen funktionieren. Geheimnisse bleiben dann per Docker-Secret/Umgebung einstellbar (wie bisher).

**Anlegen** (Swarm, einmalig; `setup.sh` fragt das im Schritt „Konfigurationsschlüssel“ und erzeugt es zufällig):

```sh
openssl rand -base64 32 | tr -d '\n' | docker secret create todo_settings_key -
```

In `stack.env`: `SETTINGS_KEY_ENABLED=true` (optional `SETTINGS_KEY_SECRET=<anderer Name>`). `scripts/swarm-deploy.sh` bindet dann das Overlay `stack.settings.yaml` ein (`SETTINGS_ENCRYPTION_KEY_FILE=/run/secrets/settings_key`). Lokal/Entwicklung: `SETTINGS_ENCRYPTION_KEY` in `.env` (siehe `.env.example`). Format: 32 Zufallsbytes als Base64 (44 Zeichen) oder 64 Hex-Zeichen. Ein falsch geformter Schlüssel verhindert den Start (mit klarer Meldung).

**Rotieren:**

1. Neues Secret anlegen (`openssl rand -base64 32 | tr -d '\n' | docker secret create todo_settings_key_2 -`).
2. In `stack.env`: `SETTINGS_KEY_SECRET=todo_settings_key_2` und `SETTINGS_KEY_PREVIOUS_SECRET=todo_settings_key`. Deployen (Overlay `stack.settings-previous.yaml` macht den alten Schlüssel zusätzlich lesbar).
3. Einmalig neu verschlüsseln: in einem Backend-Container `todo-app settings rotate-key --yes` (meldet die Anzahl; wiederholbar).
4. `SETTINGS_KEY_PREVIOUS_SECRET` entfernen, deployen, altes Secret löschen.

**Schlüssel verloren?** Die gespeicherten Geheimnisse sind dann unlesbar (Anzeige „nicht lesbar“). In der PWA „Zurücksetzen“ und neu eingeben; Nicht-Geheimnisse bleiben unberührt.

**Backup-Hinweis:** Der Schlüssel gehört **nicht** in dasselbe Backup wie die Datenbank (sonst schützt die Verschlüsselung nichts). Sichere ihn getrennt (Passwortmanager, getrennter Tresor). Datenbank-Backups ohne Schlüssel sind für Geheimnisse wertlos, aber vollständig für alles andere; nach einer Wiederherstellung ohne Schlüssel gibst du die Geheimnisse neu ein.

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
