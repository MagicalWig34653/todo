# ADR 0031 – Live-Ansicht je Karte: nur kompakte, vom Agenten gemeldete Ereignisse

Status: Backend umgesetzt (13.11.2026, Karte `CCCFFB78`, Stufe 1). PWA-Anzeige umgesetzt (14.11.2026, Stufe 2, Tab "Aktivität" im Karten-Detail); App-Anzeige folgt.

## Kontext

Lino möchte an einer Karte sehen, was der Agent gerade tut (aktuelle Aktion, Schritte, Fortschritt, Rückfragen). Frage `5190C437` hatte als Alternative ein vollständiges Transkript (Gedanken, Befehlsausgaben, Dateiinhalte) auf dem Server. Das wäre ein Datenschutz- und Geheimnisrisiko (Tokens und Dateien in Ausgaben), würde viel Speicher und Last erzeugen und wäre nicht aus dem Repository wiederherstellbar.

## Entscheidung (Lino, Frage 5190C437)

1. **Nur kompakte Ereignisse, die der Agent selbst meldet.** Kein Transkript, keine Befehlsausgabe, keine Dateiinhalte auf dem Server. Der Agent ruft per MCP `report_session_step` (aktueller Schritt und Lebenszeichen) und `report_session_event` (Art `tool`, `note`, `question`, `progress`; Text höchstens 280 Zeichen, einzeilig) auf. Lesen: REST `GET /v1/tasks/{id}/live` und MCP `get_task_live`.
2. **Secrets-Filter beim Schreiben** (`SecretFilter`). Der Server speichert nur den gefilterten Text; das Geheimnis liegt nie in der Datenbank, in der REST-/MCP-Antwort oder im Log. Der Filter ist heuristisch (Bearer-/OAuth-Tokens, bekannte API-Key-Formen, JWTs, Private-Key-Blöcke, `password=`/`secret=`/`token=`-Zuweisungen, Authorization-Header, URLs mit `user:pass@`, lange Hex- und Base64-Zeichenfolgen) und maskiert im Zweifel zu viel statt zu wenig; ein 40-stelliger Git-Commit-Hash bleibt lesbar, weil Agenten ihn ständig nennen. Er ersetzt keine Sorgfalt des Agenten (Handbuch weist darauf hin). Die Länge wird vor dem Filtern geprüft (zu lange Texte werden abgelehnt, nicht gekürzt).
3. **Rechte.** Melden wie `post_progress` (Rolle edit, Projekt im OAuth-Grant, Scope `tasks:write`); Lesen wie `get_task_context` (Rolle read, `tasks:read`). Fremde oder unsichtbare Karten: 404. Kein neuer Scope, kein REST-Schreibweg, kein Runner-Weg (der Runner meldet über seine bestehenden Agentenereignisse, ADR 0008).
4. **Live-Hinweis über den vorhandenen Mechanismus** (ADR 0022): Session und Ereignis hängen an der `live_events`-Middleware, jede Meldung ändert das Live-Token; Clients laden `GET /v1/tasks/{id}/live` neu. Kein neuer Stream-Typ. Die beiden Tabellen erscheinen nicht als Hinweis in MCP `wait_for_events`, damit sich ein meldender Agent nicht selbst weckt.
5. **Begrenzung.** Je Session 60 Ereignisse/Minute, je Karte 120/Minute (429 `rate_limited`), höchstens 10 Sessions je Karte, höchstens die neuesten 500 Ereignisse je Karte (ältere werden beim Schreiben verworfen). Wiederholte Schritte innerhalb von 5 s schreiben nicht. Die Grenzen werden ohne Zeilensperre geprüft (Zählabfrage); bei parallelen Meldungen kann sie knapp überschritten werden, die Beschneidung heilt das mit der nächsten Meldung.
6. **Aufbewahrung.** Sessions und Ereignisse werden 3 Tage nach dem Erledigen der Karte gelöscht (`ExpiredCleanup`, Scheduler und Befehl `cleanup-expired`). Maßgeblich ist `tasks.updated_at` einer Karte mit Status `done`; wird sie wieder geöffnet, wird nichts gelöscht, ein erneutes Erledigen startet die Frist neu (jede spätere Änderung an einer erledigten Karte verlängert sie ebenfalls). Offene Karten behalten ihre Daten. Karten-, Projekt- und Kontolöschung löschen über Fremdschlüssel mit Kaskade, nichts blockiert.

## Daten

`task_live_sessions` (Karte, Konto, Name, Modell, Akteur, aktueller Schritt, Status `active|ended`, Start, letztes Lebenszeichen, Ende; eindeutig je Karte und Name) und `task_live_events` (Karte, Session, Art, Text, optionale `client_uuid` eindeutig je Session, `created_at` in Millisekunden). Migration `CreateTaskLiveSessions` ist additiv (zweiter `migrate` ist ein No-op).

## Folgen und Grenzen

- Ein Agent, der nichts meldet, zeigt nichts. Das Plugin/Handbuch muss ihn zum sparsamen Melden anhalten (Handbuch 1.28.0); ein Hook, der aus Tool-Aufrufen automatisch Ereignisse erzeugt, ist bewusst nicht Teil dieses Schritts.
- `stale` (aktiv, aber seit 15 Minuten still) ist eine Anzeigehilfe; Sessions werden nicht automatisch beendet.
- Der Zeitpunkt „erledigt“ ist `updated_at`, nicht ein eigener Zeitstempel: Bearbeitungen einer erledigten Karte verschieben die Löschung. Ein eigener `done_at` wäre genauer, bräuchte aber Eingriffe in alle Statuspfade.
- Filter-Treffer werden nicht gezählt oder protokolliert; der Agent erfährt nicht, dass maskiert wurde (die Antwort zeigt den gespeicherten Text).

## Nachbesserung nach Security-Review (13.11.2026)

- **Längen:** `count` zählt Grapheme (200 000 Kombizeichen = 1). Zusätzlich werden die UTF-8-Bytes hart begrenzt (Eingabe vor dem Trimmen höchstens 8x, danach 4x des Zeichenlimits) für Text, Schritt, Session-Name, Modell und `agentName` (Test mit Kombizeichen-Bombe).
- **Session-Eigentum:** Der Name gehört der Verbindung (OAuth-Grant), die die Session angelegt hat. Eine andere Verbindung bekommt `409 session_name_taken` (kein Lesen, Umbenennen oder Beenden); sie meldet unter einem eigenen Namen. Höchstens 5 Sessions je Verbindung und Karte (insgesamt 10), damit niemand alle Plätze mit Müllnamen belegt. Das Label ändert nur der Eigentümer.
- **Filter erweitert (heuristisch, bleibt unvollständig):** deutsche Begriffe (Passwort, Kennwort, Zugangsdaten, Schlüssel, geheim), `pass`/`auth`/`key`-Zuweisungen, CLI-Flags (`--password x`, `-phunter2`, `-u user:pw`), Cookie/Set-Cookie, maskierte JSON-Anführungszeichen, `glpat-`, `sk_live_`/`sk_test_`, Passwörter in URLs mit `@` oder `/`. Vor den Regeln: NFKC-Normalisierung, Entfernen von Format-Zeichen (Zero-Width), Eingabe auf 2048 Unicode-Zeichen gekürzt (Schutz vor quadratischer Laufzeit); danach eine Zweitprüfung des einmal URL-dekodierten Texts. Bekannt nicht erfasst: Geheimnisse ohne Schlüsselwort und ohne bekanntes Format (zum Beispiel ein Passwort mitten im Satz), andere Kodierungen (doppelt URL-kodiert, Base64 kurz, Homoglyphen), Geheimnisse, die sich über das 280-Zeichen-Limit hinaus auf mehrere Meldungen verteilen. Maskiert wird lieber zu viel (`key: x`).
- **Weitere Grenzen:** Meldungen für erledigte Karten werden mit `409 task_done` abgelehnt (sonst verschwänden sie beim Cleanup); zusätzlich 600 Ereignisse je Minute je Konto.
- **Bekannte Restpunkte (nicht umgesetzt):** (1) Das Live-Token ändert sich bei jedem Ereignis über die globale Middleware; Clients anderer Karten laden dadurch häufiger nach (Rauschen). (2) Rate- und Session-Limits prüfen per Zählabfrage ohne Sperre (TOCTOU, knappes Überschreiten bei Parallelität). (3) Eine `clientUUID` wird nach dem Beschneiden alter Ereignisse nicht mehr als Wiederholung erkannt (dann entsteht ein neues Ereignis).
