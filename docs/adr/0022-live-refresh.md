# ADR 0022 – Live-Refresh per Head-Token und Long-Poll

Status: umgesetzt (31.10.2026), SQLite geprüft, MariaDB und Betrieb hinter Zoraxy ungeprüft.

## Kontext

Nutzerwunsch: nahezu Live-Aktualisierung in PWA und Swift-App; 5-s-Polling wäre genug, WebSocket vielleicht übertrieben. Das Backend läuft als 3 Replikate (Routing Mesh) hinter Zoraxy. Der Sync-Feed (ADR 0009) deckt Projekte, Aufgaben, Spalten, Labels, Planung ab, **nicht** Kommentare, Fragen, Reviews, Fortschrittsnotizen, Anhänge, Agentenaufträge, Projektkommentare/-aktivität.

## Entscheidung

**Token.** `l<sync_counter>.<max(live_events.id)>.<count der letzten 500 live_events>`. `live_events` ist eine reine Insert-Tabelle (id, kind); Fluent-Middleware (`LiveEventMiddleware`) hängt für Kommentare, Aktivität, Kriterien, Workflow, Fragen, Reviews, Fortschritt, Builds, Briefing, Anhänge, Agentenaufträge/-fragen, Projektkommentare/-aktivität/-zustand, Abhängigkeiten, Meilensteine und Einstellungen in der Schreibtransaktion eine Zeile an. Bewusst **kein** Zählerzeilen-Update: eine heiße Zeile hätte neue Sperrreihenfolgen gegenüber Zeilensperren der Fachtabellen und dem Sharing-Graph-Lock erzeugt (Deadlock-Risiko). Insert-only ist sperrenfrei; der Count über das Fenster erkennt auch spät committende Transaktionen mit kleinerer id. Der Token ist kontoübergreifend (kein Rechteleck: er enthält keine Daten, nur dass sich etwas geändert hat; Fremdänderungen führen höchstens zu einem überflüssigen Refresh, der nur Sichtbares liefert). Zeilen werden vom Hub gelegentlich auf die neuesten 5000 gekürzt.

**Stufe 1 `GET /v1/sync/head`:** `{cursor, token}`, ETag, `If-None-Match` -> 304. Drei indizierte Lesezugriffe.

**Stufe 2 `GET /v1/sync/wait?since&timeout`:** Long-Poll statt SSE. Gründe: SSE ist hinter Reverse-Proxys/Mesh puffer- und timeoutanfällig, `EventSource` kann keine Bearer-Header (die PWA nutzt Cookie-Sitzung, die Apple-App Bearer), Reconnect-/Heartbeat-Logik entfällt, jede Antwort ist eine normale, vollständige HTTP-Antwort. Nutzen für den Anwender identisch. WebSocket bewusst nicht: Aufwand (Upgrade, Framing, Heartbeats, Auth ohne Header), Proxy-/Mesh-Verhalten (Upgrade-Weiterleitung, Idle-Timeouts), zusätzlicher Zustand je Verbindung, kein Mehrwert, da der Server nur Hinweise sendet und Daten über REST geholt werden.

**Replika-sicher ohne Kopplung:** Jede Replika hält einen `LiveHub` (Actor). Nur wenn Wartende existieren, läuft ein Poller (Standard 1,5 s, `LIVE_POLL_MS`), der **eine** Token-Abfrage für alle Wartenden dieser Replika macht und die mit abweichendem `since` weckt. Keine Replika-zu-Replika-Kommunikation; Latenz höchstens Pollintervall plus Commit. Ohne Wartende kein Datenbankzugriff.

**Grenzen:** max. 8 Wartende je Konto, 500 je Replika (429 mit Retry-After 5), Timeout 1..120 s (Standard 25), Sitzungsprüfung bei jedem Aufwachen und mindestens alle 10 s (Widerruf/Ablauf -> 401), Shutdown weckt alle mit `retryAfter: 2`. Token bleibt nach Ablauf gleich -> `changed:false`.

**Abgebrochene Anfragen (Karte A1A4690B, Nachtrag):** Vapor meldet einem Handler nicht, dass der Browser die Verbindung geschlossen hat. Jeder Seitenwechsel mit vollem Laden und jedes Neuladen brach die wartende Anfrage ab, der Server hielt sie weiter als Wartende bis zum Timeout (bis 25 s) und zählte sie gegen das Limit von 8 je Konto; die neunte Seitenladung binnen 25 s bekam 429. Beleg: `web/e2e/live-wait-reload.spec.ts` (12 Ladungen, rot mit 4x 429, grün nach dem Fix) und `LiveRefreshDisconnectTests`. Entscheidung: optionaler Query-Parameter `client` (8 bis 64 Zeichen), den die PWA je Tab in `sessionStorage` hält; je (Konto, client) gibt es höchstens eine Wartende, eine neuere beendet die ältere sofort (`retryAfter:2`; `changed` ist true, wenn der Token inzwischen abweicht, ebenso beim Herunterfahren, sonst ginge die Änderung verloren). Grenze: Jeder Tab kann weiterhin eine verwaiste Wartende hinterlassen; wer binnen 25 s mehr als 8 Tabs schließt oder mit blockiertem `sessionStorage` neu lädt, kann noch 429 bekommen (Client wartet dann `Retry-After`). Verworfen: Antwort als Stream mit Herzschlag (Status steht dann vor dem Ergebnis fest, 401 nach Sitzungswiderruf ginge nicht), `sendBeacon` beim Verlassen (zusätzlicher Schreibpfad, unzuverlässig auf iOS), Limit anheben (verdeckt nur). Ohne `client` (Apple-App, MCP) bleibt alles wie vorher; ein dupliziertes Tab teilt den Schlüssel, dort wartet dank Web Locks ohnehin nur ein Tab. Das Limit selbst gilt unverändert für verschiedene Tabs und Geräte.

**Capability:** `GET /v1/capabilities` -> `liveRefresh {head, wait, stream:false, pollSeconds:5, waitMaxSeconds}`; additiv. `LIVE_REFRESH_ENABLED=false` entfernt Feld und Routen (404).

## Folgen

Zusätzliche Tabelle `live_events` (Migration `CreateLiveEvents`, additiv; `migrate` vor dem Rollout). Pro offenem Wartenden hält der Server eine Verbindung, aber keine DB-Verbindung. Zoraxy-/Proxy-Hinweise: docs/BETRIEB.md.
