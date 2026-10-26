# ADR 0010 – Passkey-Verwaltung, Recovery und verteilte Anmeldelimits

Status: angenommen, 26.10.2026 (beauftragte Recovery-Grundlage).

## Entscheidung

Zusätzliche Passkeys werden für das authentifizierte Konto registriert. Challenges sind an Konto und Hash der ausstellenden Sitzung gebunden und transaktional einmalig nutzbar. Listen enthalten nur eigene Schlüssel einschließlich Widerrufsdatum. Namen sind getrimmt und 1–100 Zeichen lang. Ein Widerruf sperrt die Kontozeile; parallele Widerrufe dürfen nicht die letzten beiden aktiven Schlüssel beseitigen. Der letzte Schlüssel benötigt einen gültigen Recovery-Code, eine gültige eingeschränkte Recovery-Sitzung oder ein vorhandenes Passwort mit Benutzername bei aktuell aktiviertem Passwort-Login. Ein gespeicherter, serverseitig abgeschalteter Passwortzugang zählt nicht als nutzbarer Ersatz.

Normale Sitzungen werden ausschließlich für das eigene Konto ohne Token/-Hash aufgelistet. Einzelwiderruf erlaubt auch die aktuelle Sitzung; „alle anderen“ erhält genau den vorgelegten Token. Widerrufe wirken bei der nächsten Authentifizierungsprüfung auf jeder Replik. Bereits autorisierte laufende Requests werden nicht abgebrochen.

Ein Admin stellt für ein bestehendes Konto einen zufälligen 256-Bit-Recovery-Code aus. Die sichere Übergabe an die richtige Person liegt beim Admin; kein Versandkanal wird impliziert. Die API gibt den Klartext einmal zurück und speichert SHA-256. Neuausstellung invalidiert vorherige Codes und Recovery-Sitzungen dieses Kontos. Ein Code ist standardmäßig eine Stunde gültig und einmalig einlösbar. Einlösung erzeugt einen zufälligen, getrennt gehashten Recovery-Bearer mit fünf Minuten Laufzeit. Kontozeilensperren serialisieren Einlösung, Neuausstellung und Recovery-Abschluss. Der Bearer steht niemals in `sessions`, setzt kein Cookie und autorisiert ausschließlich die beiden Recovery-Passkey-Routen. Er erlaubt weder normale Anmeldung noch Kontoverwaltung. Der Code bleibt nach Einlösung verbraucht, auch wenn die eingeschränkte Sitzung abläuft. Nur Admin-Neuausstellung ermöglicht dann einen weiteren Versuch.

Erfolgreiche Wiederherstellung fügt einen Passkey hinzu, löscht die Recovery-Berechtigung und widerruft alle normalen Kontositzungen atomar. Anschließend ist eine normale Anmeldung mit dem neuen Schlüssel erforderlich. Alte Passkeys bleiben erhalten, bis sie ausdrücklich widerrufen werden. Fehler bei WebAuthn rollen die Transaktion zurück; ein gültiger Recovery-Bearer kann bis zum Ablauf erneut versuchen. Rate-Limits begrenzen diese Versuche.

## Passwort-Schalter

`PASSWORD_LOGIN_ENABLED=false` sperrt Passwort-Login sowie Passwortanlage/-änderung serverseitig. Bestehende Hashes werden erhalten; Einschalten aktiviert sie erneut. Bestehende Sessions bleiben gültig. Passkey-Login, Einladungen und Admin-Recovery bleiben unabhängig verfügbar. Der Schalter wird beim Eintritt in den Passwort-Handler geprüft; ein bereits zugelassener laufender Request kann abschließen. Es gibt keine separat offenen Passwort-Challenges. Konfigurationswechsel erfordern konsistente Einstellung und Neustart aller Repliken; bei gemischter Konfiguration gelten jeweils die Einstellungen der bearbeitenden Replik. Vor Abschalten für Konten ohne aktive Passkeys zuerst Recovery bereitstellen.

## Limits und Sperrlogik

`identity_rate_limits` hält gemeinsame feste Zeitfenster mit atomarem Upsert und Zählerprüfung in einer Transaktion. Die DB-Uhr bestimmt das Fenster. Die Unique-Zeile sperrt nur einen SHA-256-Schlüssel aus Zweck, Subjekt und Fenster; kein Prozesszustand und kein globaler Lock. Alle Versuche zählen, auch erfolgreiche und ungültig formatierte. Nach Überschreitung folgt HTTP 429 mit konservativem `Retry-After`; Freigabe erfolgt im nächsten Fenster. Feste Fenster erlauben an ihrer Grenze zwei unmittelbar aufeinanderfolgende Budgets. Es gibt keine permanente Kontosperre.

Budgets gelten pro direkter Peer-IP; Passwort zusätzlich pro kleingeschriebenem Benutzername und Recovery-Einlösung zusätzlich pro Code. Weitergeleitete IP-Header werden nicht vertraut. Hinter Reverse-Proxys muss die Infrastruktur eine geeignete Peer-Grenze bereitstellen; sonst teilen Clients das Peer-Budget. Rate-Limits sind kein vollständiger Schutz gegen verteilte Angriffe auf Passkeys. DB-Ausfall führt zu Fehlern statt unlimitiertem Fallback.

| Umgebungsvariable | Standard |
| --- | ---: |
| `IDENTITY_RATE_WINDOW_SECONDS` | 60 |
| `IDENTITY_LOGIN_LIMIT` (Begin und Finish zusammen) | 60 |
| `IDENTITY_PASSWORD_LIMIT` | 10 |
| `IDENTITY_REGISTER_LIMIT` (öffentlicher Register-Begin) | 10 |
| `IDENTITY_RECOVERY_LIMIT` (Einlösung und Recovery-Passkey-Versuche) | 5 |
| `IDENTITY_RECOVERY_SECONDS` | 3600 |
| `IDENTITY_RECOVERY_SESSION_SECONDS` | 300 |

Werte werden auf mindestens 1 begrenzt. Repliken müssen dieselben Grenzen verwenden. Abgelaufene Zähler können im Betrieb regelmäßig mit `DELETE FROM identity_rate_limits WHERE expires_at < UNIX_TIMESTAMP()` entfernt werden; Aufbewahrung ist für Korrektheit unerheblich, für Speicherwachstum relevant. Für große Datenmengen in kleinen Batches bereinigen. Recovery-Datensätze werden bei Neuausstellung ersetzt bzw. beim erfolgreichen Abschluss gelöscht.

## Integration und Prüfgrenzen

Additive `IdentityMigration` nach der Initialmigration; kein automatischer Migrationslauf beim Serverstart. `Routes.swift` und `Configure.swift` enthalten je eine Registrierungszeile. `Auth/*` bleibt unverändert; die globale Middleware erfasst bestehende Login-/Register-Routen inklusive unbekannter Konten und kaputter Bodies. Vertrag: `contracts/identity.yaml`.

Die Identity-Tests verwenden virtuelle WebAuthn-Schlüssel. MariaDB-Konkurrenztests laufen mit eigener Datenbank über `TODO_TEST_DB` und zwei separaten Application-/Pool-Instanzen. SQLite ist kein Nachweis für MariaDB-Sperrverhalten. Echte Browser/Geräte sowie Linux müssen separat geprüft werden. Der konkrete Ausführungsstand und Infrastrukturgrenzen stehen in STATUS unter „Identität“.
