# Push-Benachrichtigungen einrichten (APNs)

Stand: 31.10.2026. Diese Anleitung ist für den Betreiber (Team `J2DU2P47XW`, App-ID `de.linolaske.todo`). Sie beschreibt, was im Apple Developer Portal und auf dem Server zu tun ist, damit die iOS-/macOS-App Push-Benachrichtigungen für Erinnerungen, Agenten-Rückfragen und Reviews erhält. Die Entscheidungen dahinter stehen in [ADR 0021](adr/0021-apns-push.md), die API in `contracts/push.yaml`.

**Ehrlicher Stand:** Der Server-Code ist mit einem Test-Transport geprüft (Registrierung, Deduplizierung, Widerruf bei 410, Wiederholung, Rechteprüfung, JWT-Aufbau). Ein echter Versand an Apple wurde **noch nie ausgeführt**, weil dafür dein Schlüssel und ein Gerät nötig sind. Schritt 5 ist der erste echte Test; Abschnitt „Fehlersuche“ listet die typischen Fehlermeldungen.

Ohne diese Einrichtung bleibt Push einfach aus (`APNS_ENABLED` ist standardmäßig `false`); nichts anderes ändert sich.

## 1. Schlüssel im Developer Portal anlegen

Du brauchst einen APNs-Authentifizierungsschlüssel (`.p8`). Er ersetzt die alten Zertifikate, gilt für alle Apps des Teams und für Sandbox und Produktion.

1. [developer.apple.com/account](https://developer.apple.com/account) öffnen, mit der Apple-ID des Teams anmelden (Rolle Account Holder oder Admin).
2. **Certificates, Identifiers & Profiles** > **Keys** > Plus-Zeichen.
3. Einen Namen vergeben (z. B. `Todolino APNs`), **Apple Push Notifications service (APNs)** ankreuzen, **Configure** und bei der Umgebung **Sandbox & Production** wählen (ein Schlüssel für beide). **Continue** > **Register**.
4. **Download** drücken: Die Datei `AuthKey_XXXXXXXXXX.p8` kann **nur einmal** heruntergeladen werden. Die zehn Zeichen im Dateinamen sind die **Key-ID**; sie steht auch auf der Seite des Schlüssels. Notiere sie.
5. Die **Team-ID** (`J2DU2P47XW`) steht oben rechts im Portal unter „Membership details“.
6. Datei sofort in einen Passwortmanager oder verschlüsselten Tresor legen. Pro Team gibt es höchstens zwei APNs-Schlüssel; bei Verlust muss ein neuer erzeugt werden (siehe Rotation).

## 2. App-ID: Push aktivieren

1. **Identifiers** > `de.linolaske.todo` öffnen.
2. Unter **Capabilities** **Push Notifications** ankreuzen > **Save**. Ein Zertifikat ist für tokenbasiertes Push nicht nötig; es genügt die aktivierte Capability.
3. macOS: Die AASA-Konfiguration kennt zwei Bundle-IDs (`de.linolaske.todo` und `de.linolaske.todo.mac`). Hat die Mac-App eine eigene App-ID, dort dieselbe Capability aktivieren und beide IDs in `APNS_TOPIC` eintragen (Schritt 4). Teilen sich iOS und macOS dieselbe ID (Universal Purchase), genügt eine.
4. Provisioning-Profile werden bei automatischer Signierung in Xcode neu erzeugt; bei manuellen Profilen neu laden.

## 3. Xcode und Entitlements (macht der Client-Agent)

- Capability **Push Notifications** in den Targets iOS und macOS; Xcode setzt den Entitlement-Schlüssel `aps-environment` (macOS: `com.apple.developer.aps-environment`) automatisch: `development` für Debug-Builds, `production` für Archive, TestFlight und App Store.
- Daraus folgt die Umgebung des Geräte-Tokens: **Debug-Builds liefern Sandbox-Tokens, TestFlight/App Store Production-Tokens.** Die App meldet die Umgebung bei der Registrierung selbst mit (`environment`); der Server nutzt dann pro Gerät den passenden Apple-Host. `APNS_ENVIRONMENT` ist nur der Standard für Geräte ohne Angabe.
- Die App fragt die Berechtigung an, registriert sich bei APNs und sendet das Token an `POST /v1/push/devices` (Details siehe ADR 0021 und `contracts/push.yaml`).

## 4. Server konfigurieren

### Variante A: setup.sh (empfohlen für neue Installationen und Änderungen)

`deploy/swarm/setup.sh --reconfigure` fragt am Ende „Push aktivieren?“. Bei **Ja** werden Key-ID, Team-ID (Vorschlag aus der AASA-Konfiguration), Bundle-ID(s), Standard-Umgebung und der **Pfad der `.p8`-Datei** abgefragt; das Skript legt das Docker-Secret `todo_apns_key` aus der Datei an und schreibt die (nicht geheimen) Variablen in `stack.env`. Mit `--dry-run` siehst du vorher den Plan, ohne dass etwas angelegt wird. Bei **Nein** passiert nichts.

### Variante B: von Hand

```sh
docker secret create todo_apns_key ./AuthKey_XXXXXXXXXX.p8
```

Dann in `stack.env` ergänzen (Vorlage: `deploy/swarm/stack.env.example`):

```sh
APNS_ENABLED=true
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=J2DU2P47XW
APNS_TOPIC=de.linolaske.todo            # mehrere kommagetrennt, z. B. de.linolaske.todo,de.linolaske.todo.mac
APNS_ENVIRONMENT=production             # Standard für Geräte ohne Angabe: production oder sandbox
#APNS_KEY_SECRET=todo_apns_key          # nur, wenn das Secret anders heißt
```

### Deploy

Mit `APNS_ENABLED=true` hängt `scripts/swarm-deploy.sh` automatisch die Overlay-Datei `deploy/swarm/stack.push.yaml` an (Secret als Datei `/run/secrets/apns_key`, `APNS_KEY_FILE` darauf gesetzt). Dann wie gewohnt:

```sh
deploy/swarm/update.sh --force      # --force, weil sich nur die Konfiguration ändert, nicht das Image
```

Es gibt keine Migration, die du extra beachten musst: die neuen Tabellen (`push_devices`, `push_prefs`, `push_outbox`) legt der normale Migrationslauf additiv an; alte Replikate stören sich nicht daran.

### Danach aufräumen

Die `.p8`-Datei danach **nicht** im Repository, im Downloads-Ordner, in Backup-Ordnern oder im Docker-Build-Kontext liegen lassen. Das Docker-Secret ist die einzige Kopie auf dem Server; die Archivkopie liegt im Tresor. Das Image enthält den Schlüssel nie, er erscheint auch nicht in `stack.env`, Logs oder `/health/ready`.

### Prüfen

- Der Start schlägt mit einer klaren Meldung fehl, wenn `APNS_ENABLED=true` ist, aber Schlüsseldatei, Key-ID oder Team-ID fehlen oder die Datei kein gültiger `.p8`-Schlüssel ist (`docker service logs todo_backend`, auch im Migrationstask).
- `GET /health/ready` enthält informativ `"push": {"enabled": true, "environment": "production"}`. Das beeinflusst den Status nie.
- Im Log steht beim Start `push enabled (APNs production default, topics …)`. Im Betrieb loggt der Worker nur Kategorie und Fehlergrund, **nie** Geräte-Tokens.

## 5. Test

1. In der App anmelden, Push erlauben; die App registriert das Gerät. Prüfen: im Browser eingeloggt `https://DEINE-DOMAIN/v1/push/devices` öffnen (Liste ohne Tokens).
2. Deine Konto-ID: `https://DEINE-DOMAIN/v1/me` (Feld `id`).
3. Testnachricht an alle Geräte des Kontos:

```sh
docker exec -it "$(docker ps -q -f name=todo_backend | head -n 1)" todo-app push-test KONTO-ID --yes
```

Ausgabe pro Gerät: `delivered`, `revoke(...)` (Token tot, wurde widerrufen), `retry(...)` oder `permanent(...)` mit dem Apple-Grund. Die Nachricht ist generisch („Testbenachrichtigung: Push funktioniert.“).
4. Echter Ablauf: eine Aufgabe mit Erinnerung in 1–2 Minuten anlegen, oder einem Agenten eine Rückfrage an einer Aufgabe stellen lassen. Der Worker arbeitet etwa alle 15–30 Sekunden.

## 6. Fehlersuche

| Meldung (`reason`) | Ursache | Abhilfe |
| --- | --- | --- |
| `BadDeviceToken` (400) | Token passt nicht zur Umgebung: Debug-Build (Sandbox) an den Production-Host oder umgekehrt, oder Token ungültig | Das Gerät muss `environment` korrekt melden (`sandbox` bei Debug, `production` bei TestFlight/App Store). Der Server widerruft das Token; die App registriert sich beim nächsten Start neu. |
| `Unregistered` / HTTP 410 | App deinstalliert oder Token abgelaufen | Normal. Token wird widerrufen, die App registriert beim nächsten Start ein neues. |
| `DeviceTokenNotForTopic` | Token gehört zu einer anderen Bundle-ID als der gesendete Topic | `bundleId` bei der Registrierung prüfen und in `APNS_TOPIC` eintragen. |
| `TopicDisallowed` (403) | Der Schlüssel darf diese Bundle-ID nicht, oder Push-Capability fehlt an der App-ID | Schritt 2 prüfen; ist der Schlüssel auf bestimmte Topics eingeschränkt, passenden Schlüssel nehmen. |
| `ExpiredProviderToken` (403) | Provider-Token älter als 60 Minuten | Der Server erneuert nach spätestens 50 Minuten automatisch; tritt es dauerhaft auf, ist die Serveruhr falsch (NTP prüfen). |
| `InvalidProviderToken` (403) | Key-ID, Team-ID oder `.p8` passen nicht zusammen, oder der Schlüssel wurde im Portal widerrufen | Key-ID aus dem Dateinamen, Team-ID aus „Membership details“ prüfen; Secret mit der richtigen Datei neu anlegen. Kein Gerät wird deswegen widerrufen. |
| `TooManyProviderTokenUpdates` (429) | Provider-Token zu oft erneuert | Selten; der Server nutzt einen Cache. Mehrere Instanzen mit demselben Schlüssel verteilen die Last, kein Eingriff nötig. |
| `TooManyRequests` (429), 5xx | Apple drosselt oder ist gestört | Der Server wiederholt mit Wartezeit (30 s, 60 s, … bis 1 h, höchstens 6 Versuche). |
| HTTP/2-Verbindungsfehler, „network“ | Der Server erreicht `api.push.apple.com:443` bzw. `api.sandbox.push.apple.com:443` nicht | Ausgehende Firewall, DNS und Proxy prüfen (HTTPS, Port 443). Port 2197 ist nicht nötig. |
| 403 „Zertifikat“ / `BadCertificate…` | Es wird ein Zertifikat statt tokenbasierter Anmeldung erwartet oder ein falscher Schlüsseltyp | Es muss ein **APNs-Schlüssel (.p8)** sein, kein Zertifikat und kein anderer Schlüsseltyp. |
| Start bricht ab: `APNS_ENABLED=true needs …` | Variable oder Secret fehlt | Meldung nennt die fehlende Angabe; Schritt 4 prüfen. |
| Nichts kommt an, kein Fehler | Kategorie im Konto aus (Standard: Kommentare und Zuweisungen aus), kein Gerät registriert, Rechte verloren oder Erinnerung älter als 6 Stunden | `GET /v1/me/push-prefs` und `/v1/push/devices` prüfen. Der Test mit `push-test` umgeht die Einstellungen. |

## 7. Schlüsselrotation und Widerruf

Docker-Secrets sind unveränderlich. Rotation ohne Ausfall:

1. Im Portal einen **neuen** Schlüssel anlegen (Schritt 1; höchstens zwei sind erlaubt, notfalls den alten zuerst widerrufen).
2. `docker secret create todo_apns_key_2 ./AuthKey_NEU.p8`.
3. In `stack.env`: `APNS_KEY_SECRET=todo_apns_key_2` und die neue `APNS_KEY_ID`; `deploy/swarm/update.sh --force`.
4. Prüfen (Schritt 5), dann das alte Secret entfernen (`docker secret rm todo_apns_key`) und den alten Schlüssel im Portal widerrufen. Neue `.p8` wieder aus dem Arbeitsordner löschen.

Bei Verdacht auf Kompromittierung: Schlüssel sofort im Portal widerrufen (Push stoppt, die Geräteliste bleibt), dann wie oben einen neuen einsetzen.

## 8. Datenschutz und Hinweise

- **Inhalte:** Benachrichtigungen laufen über Apples Server. Standardmäßig sind sie **generisch** („Rückfrage vom Agenten“, „Eine Aufgabe ist fällig.“); Aufgabentitel und Kurztexte werden nur gesendet, wenn das Konto es in den Push-Einstellungen aktiviert (`showContent`). Kommentartexte werden nie gesendet. Die Nachrichten enthalten außerdem IDs für Deep-Links (`taskID`, `projectID`, `kind`); die App kann sie über eine Notification Service Extension (`mutable-content` ist gesetzt) mit den Daten vom Server anreichern.
- **Rechte:** Es bekommt nur Push, wer das Objekt zum Erzeugungs- und zum Sendezeitpunkt lesen darf (Fragen: kommentieren, Reviews: bearbeiten). Wer eine Freigabe verliert, bekommt nichts mehr.
- **Geräte-Tokens** sind Zugangsdaten für Pushes an das Gerät: sie werden nie geloggt und nie über die API zurückgegeben. Löschen eines Kontos entfernt Geräte und Warteschlange. Widerrufene Geräte werden nach 30 Tagen gelöscht, abgearbeitete Warteschlangeneinträge nach 3 Tagen.
- **Mehrere Replikate:** Nur eine Replika sendet gleichzeitig (Lease in der Datenbank). Doppelte Auslöser werden pro Konto durch einen Schlüssel verhindert; zusätzlich nutzt der Versand `apns-collapse-id`, sodass Apple seltene Wiederholungen zusammenfasst.
- **Nicht enthalten:** Web-Push für die PWA, Ruhezeiten (iOS-Fokus-Modi übernehmen das), Push für Zuweisungen (das Datenmodell kennt keine Zuweisung; die Kategorie `assignments` ist vorbereitet, löst aber noch nichts aus).
