# ADR 0021 – APNs-Push für die Apple-Apps

Status: umgesetzt (31.10.2026), Versand gegen Apple ungeprüft. Ergänzt ADR 0014 (Fragen, Reviews), ADR 0019 (Lease-Muster) und die Planung (Erinnerungen).

## Kontext

Erinnerungen (`task_planning.reminders`) wurden nie zugestellt, offene Rückfragen und Reviews der Agenten fielen erst beim Öffnen der App auf. Der Nutzer wollte zuerst iOS/macOS (APNs); die API-Schlüssel richtet er selbst ein ([PUSH-EINRICHTUNG.md](../PUSH-EINRICHTUNG.md)). Web-Push ist ausdrücklich später.

## Entscheidung

**Geräte (`push_devices`).** `POST /v1/push/devices` ist idempotent über den SHA-256 des Tokens (eindeutiger Index). Ein Token, das ein anderes Konto meldet (Anmeldung auf demselben Gerät), wird diesem Konto zugeordnet und wieder aktiviert. Felder: Plattform `ios|macos`, Umgebung `sandbox|production` (Standard `APNS_ENVIRONMENT`), `bundle_id` als apns-topic, App-Version, Locale, `last_seen_at`, `revoked_at`. Höchstens 20 aktive Geräte je Konto; darüber wird das am längsten ungesehene automatisch widerrufen (Neuinstallationen erzeugen neue Tokens). `DELETE` widerruft (Zeile bleibt 30 Tage). Das Token wird nie geloggt und nie ausgegeben (kein Feld in `PushDeviceDTO`; der Transport reduziert Netzwerkfehler auf einen festen Text, weil die Request-URL das Token enthält). Registrierung ist auch bei `APNS_ENABLED=false` möglich, damit Clients vor der Serverfreischaltung registrieren können; bei aktiviertem Push muss die Bundle-ID in `APNS_TOPIC` stehen.

**Einstellungen (`push_prefs`).** `GET/POST(PUT) /v1/me/push-prefs`: Kategorien `reminders`, `agent_questions`, `agent_reviews` (Standard an), `assignments`, `comments` (Standard aus), `showContent` (Standard **aus**), `badge` (Standard an). Teilaktualisierung; unbekannte Kategorien: 400. Ruhezeiten nicht gebaut (iOS-Fokus-Modi decken das ab).

**Inhalt und Datenschutz.** Titel und Kurztexte von Aufgaben sind sensibel (Sperrbildschirm, Apples Server, geteilte Teams). Deshalb ist der Standard **generisch** („Rückfrage vom Agenten“ / „Eine Aufgabe wartet auf deine Antwort.“); mit `showContent` kommen Aufgabentitel und bei Fragen/Reviews der Text (auf 160 Zeichen gekürzt) dazu, bei Kommentaren nie der Kommentartext. Die Nachricht trägt `mutable-content: 1`, damit die App per Notification Service Extension Inhalte mit eigener Authentifizierung nachladen kann, und Deep-Link-Felder (`kind`, `taskID`, `projectID`, `subjectID`) im Top-Level-userInfo; `thread-id` ist die Projekt-ID, `aps.category` `TODO_REMINDER|TODO_QUESTION|TODO_REVIEW|TODO_COMMENT`. Die Outbox speichert nur Kennungen (`PushEvent`), nie Text: der Inhalt wird beim Senden nach der Rechteprüfung aufgelöst.

**Auslöser (Worker-Scans statt Hooks).** Statt die Fachtransaktionen zu verändern, findet der `PushWorker` neue Auslöser durch Lesen der bestehenden Tabellen und schreibt die Outbox (`push_outbox`, eindeutig über `(user_id, dedupe_key)`): Erinnerungszeitpunkte im Fenster der letzten 6 Stunden (Schlüssel `reminder:<task>:<unix>`, Empfänger: Besitzer der Aufgabe, nur offene Aufgaben), offene `task_questions` (`question:<id>`, Empfänger: alle Konten mit Gerät und Recht `comment` außer dem fragenden Menschen), ausstehende `task_reviews` (`review:<id>`; Empfänger der benannte Reviewer, sonst alle mit Recht `edit`, außer dem Anforderer), `comment.created`-Aktivitäten der letzten Stunde (`comment:<id>`; Empfänger Aufgabenbesitzer und frühere Kommentatoren, nicht der Autor; nur wenn die Kategorie aktiv ist). Zuweisungen: das Modell kennt keine, also kein Auslöser. Kandidaten sind nur Konten mit aktivem Gerät; ohne Kandidaten entfällt der Scan. Latenz: ein Worker-Takt (15–30 s). Die Dedupe-Schlüssel bleiben 3 Tage erhalten (Aufräumen im Worker), länger als jedes Auslösefenster.

**Rechte doppelt.** Beim Erzeugen prüft `ProjectAccess` pro Empfänger die Rolle; beim Senden wird erneut geprüft (Rolle, Objekt noch da, Frage noch offen, Review noch ausstehend, Erinnerung noch eingetragen und Aufgabe nicht erledigt, Kategorie noch aktiv). Sonst `skipped` mit Grund; es wird nichts gesendet.

**Worker (`PushWorker`).** Wie der Cleanup-Scheduler (ADR 0019): ein Lease-Eintrag `push-worker` in `maintenance_leases`, Datenbankuhr, atomares `UPDATE`, Übernahme nach Ablauf (120 s), Mindestabstand 15 s, Abfrage alle ~7,5 s mit Jitter, Start nur bei `serve`. Läuft nur, wenn `APNS_ENABLED=true`. Pro Lauf: Auslöser einsammeln, bis zu 50 fällige Zeilen senden, alte Zeilen löschen. Fehler stürzen nichts ab, kein Pfad der Requests wartet auf den Worker.

**Sender.** `APNsTransport`-Protokoll (Test-Double) mit Produktionsimplementierung über den Vapor-Client (AsyncHTTPClient, HTTP/2 per ALPN) gegen `api.push.apple.com` bzw. `api.sandbox.push.apple.com` je Gerät. Header: `authorization: bearer <JWT>`, `apns-topic`, `apns-push-type: alert`, `apns-priority` (10 für Erinnerung/Frage/Review, 5 für Kommentare und Test), `apns-expiration` (12–24 h, Test 5 min), `apns-collapse-id` (Hash des Dedupe-Schlüssels, höchstens 64 Bytes). JWT: ES256 mit swift-crypto aus der `.p8`, Header `{alg,kid}`, Claims `{iss=Team-ID, iat}`, 50 Minuten gecacht (Apple lehnt >60 min ab und Erneuerung öfter als alle 20 min), Erneuerung bei `ExpiredProviderToken` nur, wenn das Token mindestens 20 min alt ist. Fehlerklassen: 410, `BadDeviceToken`, `DeviceTokenNotForTopic`, `Unregistered` widerrufen das Gerät; 429/5xx/Netzwerk/`ExpiredProviderToken` wiederholen mit 30 s · 2ⁿ (max. 1 h, höchstens 6 Versuche, danach `failed`); alles andere (`InvalidProviderToken`, `TopicDisallowed`, Payload) ist dauerhaft und lässt die Geräte unberührt, damit eine Fehlkonfiguration keine Registrierungen vernichtet. Bei mehreren Geräten kann eine Wiederholung das erfolgreiche Gerät erneut ansprechen; `apns-collapse-id` fasst das zusammen.

**Konfiguration.** `APNS_ENABLED` (Standard `false`), `APNS_KEY_FILE` (Pfad zum Docker-Secret), `APNS_KEY_ID`, `APNS_TEAM_ID` (ohne Standardwert), `APNS_TOPIC` (Standard `de.linolaske.todo`, kommagetrennt), `APNS_ENVIRONMENT` (Standard `production`). Ist Push aktiviert und etwas fehlt oder der Schlüssel nicht lesbar ist, bricht der Start mit klarer Meldung ab (auch `migrate`, weil dieselben Einstellungen geladen werden; die Overlay-Datei hängt das Secret deshalb an beide Services). `deploy/swarm/stack.push.yaml` wird nur bei `APNS_ENABLED=true` eingebunden; alte Env-Dateien funktionieren unverändert. Dev-Compose: aus. `/health/ready` zeigt informativ `push {enabled, environment}`.

**Betrieb.** `App push-test <konto-id> --yes` sendet eine generische Nachricht an alle aktiven Geräte des Kontos und zeigt das Ergebnis je Gerät (ohne Token).

## Folgen

- Additive Migration `CreatePushSchema` (3 Tabellen, Fremdschlüssel mit Kaskade auf `users`); Kontolöschung räumt mit auf. Alte Replikate ignorieren sie.
- Kein neues MCP-Tool, kein Handbuchänderung nötig.
- Vertrag: `contracts/push.yaml` 1.0.0 (nicht im OpenAPI-Routenabgleich von `openapi.yaml`).
- Apple-Client: Registrierung, Berechtigungsabfrage, Entitlement `aps-environment`, Deep-Links, Einstellungs-UI, optional Notification Service Extension (siehe PUSH-EINRICHTUNG.md und Apple-Status).

## Grenzen

- Ungeprüft gegen Apple (kein Schlüssel/Gerät in der Entwicklung): Header-Details, HTTP/2-Aushandlung des Clients, tatsächliche Fehlertexte. Geprüft sind Logik, Persistenz und JWT mit Test-Schlüssel; MariaDB-Lauf der neuen Tests steht aus (Docker-VM voll).
- Reminder gehen nur an den Aufgabenbesitzer, nicht an alle Beteiligten (Erinnerungen sind aufgabenweit, nicht je Konto).
- Scans lesen pro Takt die Reminder-Kandidaten (`reminders <> '[]'`, offene Aufgaben, höchstens 5000); für sehr große Bestände wäre ein Index-/Zeitfeld nötig.
- Kein Web-Push, keine Ruhezeiten, keine Zuweisungsbenachrichtigung.
