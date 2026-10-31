# E-Mail-Versand einrichten (SMTP)

Optional und standardmäßig aus. Entscheidung und Hintergründe: [ADR 0024](adr/0024-mailversand.md), API: `contracts/mail.yaml`.

**Wofür der Server Mail sendet:** (1) Bestätigung einer E-Mail-Adresse (Double-Opt-In), (2) Test-Mail an die eigene bestätigte Adresse, (3) auf Wunsch des Admins der Recovery-Code eines Kontos. Mails enthalten nie Aufgabentitel oder Projektnamen. Keine Zusammenfassungen, keine Benachrichtigungsmails (noch nicht gebaut).

> **Wichtig zu Recovery per Mail:** E-Mail ist kein sicherer Kanal. Wer die Mail des Recovery-Codes lesen kann, kann das Konto übernehmen. Deshalb gilt der Code nur eine Stunde, ist einmalig, wird nach dem Versand aus der Warteschlange gelöscht und geht nur an eine **bestätigte** Adresse. Wer das Risiko nicht will, lässt `sendEmail` aus und gibt den Code wie bisher persönlich weiter.

## 1. SMTP-Zugang besorgen

Du brauchst von deinem Mail-Anbieter (oder eigenem Mailserver) den **Postausgangsserver** für ein Konto, das Mails versenden darf:

| Angabe | Beispiel | Hinweis |
| --- | --- | --- |
| Server (`SMTP_HOST`) | `smtp.example.org` | Hostname des Postausgangsservers |
| Verschlüsselung (`SMTP_SECURITY`) | `starttls` | `starttls` meist Port 587, `tls` meist Port 465. `none` nur für lokale Tests (Server verweigert das mit Zugangsdaten außerhalb von localhost) |
| Port (`SMTP_PORT`) | `587` | Standard ergibt sich aus der Verschlüsselung (587/465/25) |
| Benutzername (`SMTP_USER`) | `todolino@example.org` | oft die volle Adresse |
| Passwort | - | als Docker-Secret, siehe Schritt 2 |
| Absender (`MAIL_FROM`) | `todolino@example.org` | Viele Anbieter lehnen Absender ab, die nicht zum Konto gehören. SPF/DKIM der Absenderdomain sollten stimmen, sonst landen Mails im Spam. |
| Absendername (`MAIL_FROM_NAME`) | `Todolino` | optional |

Der Client unterstützt STARTTLS und implizites TLS (mindestens TLS 1.2, Zertifikat und Hostname werden geprüft) sowie die Anmeldung per `AUTH PLAIN` oder `AUTH LOGIN`. Tipp: ein eigenes Postfach oder einen eigenen App-Zugang nur für Todolino anlegen, nicht das persönliche Passwort verwenden.

## 2. Server konfigurieren

### Variante A: setup.sh (empfohlen)

`deploy/swarm/setup.sh --reconfigure` (oder beim ersten Setup): Schritt „E-Mail-Versand (optional)“ fragt Server, Verschlüsselung, Port, Benutzer, Absender und Secret-Namen und legt das Secret aus der verdeckten Passwort-Eingabe an. Der Trockenlauf `deploy/swarm/setup.sh --dry-run` zeigt vorher, was passieren würde. Nicht interaktiv: `MAIL_ENABLED=true`, `SMTP_HOST`, `SMTP_USER`, `MAIL_FROM` und `SMTP_PASSWORD` (oder `SMTP_PASSWORD_FILE`) in der Antwortdatei.

### Variante B: von Hand

1. Passwort als Secret anlegen (nichts davon landet in Repository oder Env-Datei):

```sh
printf '%s' 'DAS-SMTP-PASSWORT' | docker secret create todo_smtp_password -
```

2. In `deploy/swarm/stack.env` ergänzen (Beispiel in `stack.env.example`):

```sh
MAIL_ENABLED=true
SMTP_HOST=smtp.example.org
SMTP_SECURITY=starttls
SMTP_PORT=587
SMTP_USER=todolino@example.org
MAIL_FROM=todolino@example.org
MAIL_FROM_NAME=Todolino
#SMTP_PASSWORD_SECRET=todo_smtp_password   # nur, wenn das Secret anders heißt
```

3. Deploy wie gewohnt (`scripts/swarm-deploy.sh` bindet bei `MAIL_ENABLED=true` das Overlay `deploy/swarm/stack.mail.yaml` ein; `deploy/swarm/update.sh` bei Updates). Die Migration legt additiv die Tabellen `user_emails`, `email_verifications` und `mail_outbox` an.

Der Swarm-Overlay verlangt Benutzername und Passwort. Ein Relay ganz ohne Anmeldung ist nur außerhalb des Swarms nutzbar (`SMTP_SECURITY=none` ohne `SMTP_USER`).

### Alle Variablen

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `MAIL_ENABLED` | `false` | `true` schaltet Adress-Funktionen und den Sende-Worker ein. Dann sind `SMTP_HOST` und `MAIL_FROM` Pflicht, sonst bricht der Start mit klarer Meldung ab. |
| `SMTP_HOST` | - | Hostname oder IP des Postausgangsservers |
| `SMTP_SECURITY` | `starttls` | `starttls`, `tls` oder `none` |
| `SMTP_PORT` | 587 / 465 / 25 | je nach Verschlüsselung |
| `SMTP_USER` | - | zusammen mit dem Passwort oder gar nicht |
| `SMTP_PASSWORD_FILE` | - | Pfad der Secret-Datei; im Stack `/run/secrets/smtp_password` (Secret `todo_smtp_password`, Name über `SMTP_PASSWORD_SECRET`) |
| `MAIL_FROM` | - | Absenderadresse |
| `MAIL_FROM_NAME` | `Todolino` | Absendername |

Das Passwort steht nie im Log und nie in einer API-Antwort. Fehler werden nur als Klasse gespeichert (z. B. `connect`, `tls`, `auth_535`, `recipient_550`), nie mit Servertext oder Adresse.

## 3. Prüfen

- Der Start schlägt bei `MAIL_ENABLED=true` mit unvollständiger Konfiguration fehl, mit Meldung zur fehlenden Variable (`docker service logs todo_backend`, auch im Migrationstask). Im Log steht beim Start `mail enabled (SMTP host:port …)`.
- `GET /health/ready` enthält informativ `"mail": {"enabled": true}`. Das beeinflusst den Status nie.
- **Test-Mail:** In der PWA unter *Konto > Allgemein > E-Mail* die Adresse eintragen, **Bestätigungsmail senden**, den Link in der Mail öffnen (24 Stunden gültig, einmalig). Danach erscheint **Test-Mail senden**. Der Server-Status („Der Server kann E-Mails senden“ oder „nicht aktiviert“) und die letzte Mail mit Ergebnis (gesendet, fehlgeschlagen + Fehlerklasse) stehen auf derselben Karte. Der Versand läuft über die Warteschlange und dauert wenige bis etwa 15 Sekunden.

## 4. Recovery-Code per Mail

1. Das Konto, das den Code braucht, hinterlegt und bestätigt seine Adresse (Schritt 3).
2. Als Admin: *Konto > Verwaltung > Recovery-Code ausstellen*, Konto-ID eintragen, Haken **Zusätzlich per E-Mail senden** setzen. Der Code wird wie bisher einmalig angezeigt; zusätzlich steht darunter, ob eine Mail unterwegs ist (`queued`), das Konto keine bestätigte Adresse hat oder der Versand nicht aktiv ist. Es geht nie eine Mail an unbestätigte Adressen.
3. Die Mail enthält den Code im Klartext und einen Link (`…/recover#code=…`), der das Eingabefeld ausfüllt; der Code im Fragment gelangt nicht in Server-Logs. Der Link löst den Code **nicht** allein ein, die Person muss den Passkey selbst anlegen.
4. Gültigkeit eine Stunde, einmalig; eine neue Ausstellung macht ältere Mails wirkungslos (der Server verschickt sie dann nicht mehr).

## 5. Fehlersuche

| Fehlerklasse (`lastMail.error`) | Ursache | Abhilfe |
| --- | --- | --- |
| `connect` | Server nicht erreichbar, falscher Host/Port, Firewall, Zeitüberschreitung | Host/Port prüfen; aus dem Backend-Container `nc -vz HOST PORT`. Ausgehender Port 587/465 ist bei manchen Hostern gesperrt. |
| `tls` oder `tls_NNN` | Zertifikat/Hostname passt nicht, Server bietet kein STARTTLS, falsche Verschlüsselung für den Port | `SMTP_SECURITY` zum Port passend wählen (587 starttls, 465 tls); Hostname muss im Zertifikat stehen. |
| `auth` oder `auth_535` | Benutzer/Passwort falsch, Anbieter verlangt App-Passwort, kein PLAIN/LOGIN angeboten | Secret neu anlegen (Secrets sind unveränderlich: neues Secret mit neuem Namen, `SMTP_PASSWORD_SECRET` anpassen, deployen). |
| `sender_NNN` | Absender abgelehnt | `MAIL_FROM` muss zum SMTP-Konto gehören. |
| `recipient_5NN` | Empfänger abgelehnt (Adresse existiert nicht) | endgültig, keine Wiederholung; Adresse prüfen. |
| `recipient_4NN`, `timeout` | vorübergehend (Greylisting, Drosselung) | Der Server wiederholt mit 30 s, 60 s, … bis 1 h, höchstens 6 Versuche. |
| `mail_disabled` (Zeile übersprungen) | Beim Versand war `MAIL_ENABLED` nicht gesetzt | Konfiguration prüfen. |

Landen Mails im Spam: SPF-, DKIM- und DMARC-Einträge der Absenderdomain beim Anbieter prüfen; Todolino sendet nur Text und einfaches HTML ohne Bilder und Tracking.

## 6. Datenschutz

- Adressen sind eindeutig je Konto und werden nie an andere Konten ausgegeben. Die Antwort auf „Adresse hinterlegen“ ist immer gleich, auch wenn die Adresse schon vergeben ist (keine Konto-Aufzählung; an die vergebene Adresse geht keine Mail).
- Bestätigungslinks und Recovery-Codes stehen nur bis zum Versand (oder Ablauf) in der Warteschlange und werden danach geleert. Erledigte Zeilen verschwinden nach 3 Tagen.
- Mail-Server des Anbieters sehen Absender, Empfänger und Inhalt (inklusive Recovery-Code, falls genutzt).
- Adresse entfernen: *Konto > E-Mail > Adresse entfernen*.
