# Security-Review: ausgehender Webhook (ADR 0035, Karte 06EB19A3)

Stand 23.11.2026. Prüfobjekt: Server (`Sources/TodoKit/Webhook`, `Auth/AuthSupport.swift`, `MCP/MCPController.swift`), PWA (`WebhookPage.svelte`, `webhook.ts`), Vertrag `contracts/webhook.yaml`. Prüfer: unabhängiger, schreibgeschützter Agent (`security-auditor`) auf Stand 711da7d; Behebung durch Test-zuerst-Änderungen (Commits 0e1a3d5, 46f66ee, b3fb178, 81743ab, gemergt in main), nachgelaufen im Hauptcheckout. Grenzen: kein echtes TLS gegen ein externes Ziel, kein Zugriff auf Live, Befunde 3, 4, 6 waren aus dem Code abgeleitet und sind danach durch Tests belegt.

## Befunde und Behebung

| Nr | Grad | Befund | Behebung | Beleg (Test in `WebhookSecurityReviewTests`) |
|---|---|---|---|---|
| 1 | hoch | SSRF: `dnsOverride` war mit dem kleingeschriebenen Host geschlüsselt, AsyncHTTPClient schlug aber mit der Schreibweise der Original-URL nach (`https://Example.COM/x`); das Festnageln der geprüften Adresse griff nicht, ein zweiter DNS-Lookup war möglich | Request-URL aus den geparsten Teilen (Host klein, ohne Punkt am Ende); Transport prüft vor dem Senden `request.host == r.host`, sonst `target_blocked` ohne Wiederholung | `testRequestURLIsBuiltFromTheParsedParts…`, `testDeliveryPins…MixedCaseAndTrailingDot…ResolvesOnce`, `testTransportConnectsExactlyOnce…`, `testTransportRefusesToSend…` |
| 2 | hoch | `::ffff:0.0.0.0` / `::ffff:0:0` waren nicht gesperrt (der Guard nimmt eingebettetes 0.0.0.0 aus der Mapped-Regel aus) | `WebhookTarget` sperrt `::ffff:0:0/96`, SIIT `::ffff:0:0:0/96`, `100::/64`, `2001:db8::/32` (OutboundGuard für Mail/S3 unverändert) | `testMappedZeroSiit…`, `testDisguisedLiterals…AtSave`, `testDisguisedAAAA…SaveAndDelivery` |
| 3 | mittel | PUT ohne Ratenbegrenzung, blockierende Namensauflösung, Orakel „gesperrt“ gegen „ungültig“ | 10 PUT mit Hostnamen/Minute/Konto (429), Auflösung mit 5 s Timeout losgelöst vom kooperativen Pool, „nicht auflösbar“, „gesperrt“ und Timeout liefern denselben Code `webhook_url_blocked` | `testPutWithAHostNameIsRateLimited…`, `testUnresolvableAndBlockedHostsGiveTheSameCode…`, `testSlowResolutionAtSave…` |
| 4 | mittel | Worker sendete seriell, Tarpit-Ziele konnten alle Zustellungen aufhalten | TaskGroup, höchstens 8 gleichzeitig und 1 je Ziel-Host, Connect-Timeout 3 s (gesamt 10 s), Lease-Erneuerung vor jedem Start | `testTenSlowTargetsAreNotServed…`, `testOneHostIsNeverServedInParallel`, `testConnectTimeoutIsThreeSeconds…` |
| 5 | mittel | Schleifenschutz fail-open (Aktion zählte als Person, sobald die MCP-Markierung fehlte) | Umgekehrt: nur `requireUser` (Personen-Sitzung) markiert den Request; ohne Markierung oder mit MCP-Markierung löst nichts aus | `testActivityWithoutAPersonSessionMarker…` plus die bestehenden Integrations-Tests |
| 6 | niedrig | Möglicher MariaDB-Deadlock durch die Zeilensperre auf `webhook_endpoints` in der Schreib-Transaktion | Bündeln als einzelner Upsert auf den Unique-Schlüssel (`user_id, open_marker`), keine Sperre auf dem Endpoint | `testEventsRacingWithTheWorker…` (MariaDB, 30 parallele Schreiber plus Worker; fünf Wiederholungen ohne Fehler) |
| 7 | niedrig | Beliebiger Port (Abtasten dritter Hosts über Fehlercodes) | Nur Port 443 (`:443` ausdrücklich erlaubt), sonst `webhook_url_invalid` | `testOnlyPort443IsAccepted` |
| 8 | niedrig | Signatur-Zeitstempel war der Tick-Start | Zeitstempel zum Sendezeitpunkt | `testSignatureTimestampIsTheTimeOfSending…` |
| 9 | niedrig | Passwortmanager bietet für die Felder „Speichern“ an | `autocomplete="new-password"`, `data-1p-ignore`, `data-lpignore`, `data-form-type="other"` | E2E-Spec angepasst (Lauf siehe STATUS) |
| 10 | Info | Maske zeigt den vollen Host (ein Token im Subdomain-Teil wäre sichtbar), steht im Klartext in der DB | bewusst so (ADR 0035 Punkt 2); in ADR und Vertrag benannt, kein Code | Dokumentation |
| 11 | Info | `requireSettingsRuntime()` auch bei reinen Ausschluss-/Ein-Aus-Änderungen | Schlüssel nur noch bei Adresse und Signaturgeheimnis | `testExclusionsAndEnabledCanBeChangedWithoutAnEncryptionKey` |

## Geprüft und in Ordnung

- **Geheimnis-Handling:** Adresse und Signaturgeheimnis nur als AES-256-GCM mit AAD (Zweck, Konto, Feld); nie in API-Antworten, Fehlertexten, Protokoll, Aktivität, Live-Hinweisen oder MCP; Fehlerpfade liefern feste Codes; Löschen und Kontolöschung entfernen den Chiffretext (Kaskade). HMAC über `"<ts>.<body>"` korrekt.
- **Injection über die Nutzlast:** Nutzlast ist ein `Encodable` mit festen Schlüsseln, `kinds` kommen aus einer Bitmaske der Whitelist; keine Titel, Namen oder Kommentartexte (Test mit „IGNORE PREVIOUS“ im Titel). SQL: alles gebunden.
- **Rechte:** Verwaltung nur `requireUser` (OAuth-Token 401, kein MCP-Werkzeug); Ausschlüsse nur eigene lesbare Projekte (404 für unbekannt und fremd, kein Orakel); Protokoll nur eigenes Konto; Test senden 1 je 10 s; Auto-Abschaltung nach 10 Fehlbündeln.
- **SSRF sonst:** nur https, keine Zugangsdaten in der URL, keine Weiterleitungen (3xx = Fehler), kein Umgebungsproxy, Antworttext wird verworfen (Abbruch nach 64 KiB), keine Steuerzeichen in der URL, Prüfung beim Speichern und bei jeder Zustellung.
- **PWA:** kein `{@html}`, kein Storage, keine Konsole; die Adresse steht nur in `$state` und wird nach dem Speichern geleert; Protokollwerte laufen über feste Texte.

## Restrisiken

- Echtes TLS und die Verbindung zu einem externen Ziel sind nur gegen lokale Sockets belegt (Adresse festgenagelt, SNI und Zertifikat gegen den Hostnamen). Der erste echte Aufruf nach dem Deploy (Test senden) ist der Praxistest.
- Das Ratenlimit ist ein festes 60-s-Fenster (ein Burst über die Fenstergrenze lässt bis zu 20 PUT zu) und zählt nur PUTs mit Hostnamen.
- Die Host-Serialisierung im Worker nutzt die Maske; alle Konten am selben Host laufen nacheinander (gewollt).
- Ein Ereignis, das genau beim Schließen eines Bündels eintrifft, landet im alten oder neuen Bündel (gezählt wird es immer).
- Ein Rotationswerkzeug für den Schlüssel gibt es für Webhook-Chiffretext nicht (wie für andere Einstellungsgeheimnisse); bei `encryption_key_unreadable` muss die Person die Adresse neu setzen.
