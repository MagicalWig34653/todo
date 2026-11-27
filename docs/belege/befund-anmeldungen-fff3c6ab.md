# Befund: Warum die Anmeldungen ablaufen (Karte FFF3C6AB, 27.11.2026)

Quellen: lokale MCP-Protokolle von Claude Code (`~/Library/Caches/claude-cli-nodejs/*/mcp-logs-*todolino*/*.jsonl`, 441 Dateien), nur
Zeitpunkte und Meldungen; keine Tokens gelesen oder ausgegeben, kein Schlüsselbund. Server-Logs und Live-Datenbank lagen **nicht** vor.
Zeiten in UTC (CET = +1 h). Codestellen: Stand vor dem Fix (`5cddc14`).

## Zahlen

1717 erfolgreiche Refreshes, **3 `invalid_grant`**, 18 „refresh failed, returning current tokens“; Refresh-Dauer Median 0,22 s,
Maximum 8,06 s.

| Fall | Zeitpunkt | Beobachtung |
|---|---|---|
| a | 03.11. 07:34:13 | Plugin, 1026 s nach dem letzten sichtbaren Speichern (vor ADR 0036) |
| b | 26.11. 06:45:07 | `todolino-brain`: „Token persist failed: storage write failed“, altes Token 58 s später (Fall von ADR 0036) |
| c | 26.11. 21:35:10 | **der gemeldete Fall** (Plugin, 22:35 CET) |

Fall c im Einzelnen:

1. 21:17:01 letzter sichtbarer Erfolg mit Speichern (eine Worktree-Sitzung).
2. 21:27:54 bis 21:28:25: drei weitere Projektsitzungen melden „Refresh lock held by another process“ und „Could not acquire refresh lock
   after 5 retries; skipping refresh“. Der Halter hielt die Sperre mindestens 31 s und steht in keinem Todolino-Protokoll.
3. 21:35:10 `invalid_grant`, danach „No valid tokens in storage, clearing stored tokens“ und „Invalidated credentials (scope: tokens)“,
   der nächste Aufruf bekommt 401. **Der Client löscht bei `invalid_grant` die gemeinsame Anmeldung; damit sind alle Projekte abgemeldet.**
4. Danach nur Anmeldeversuche; erstes „Saving tokens“ wieder am 27.11. 14:30:45 (15:30:45 CET).

Zweiter Beleg (diese Sitzung): Start am 27.11. gegen 14:43 CET mit „plugin:todolino:todolino requires authentication … This session is
non-interactive, so Claude cannot run the OAuth flow here“. Auch nach der Neuanmeldung um 15:30 bekam die laufende Sitzung keine
Werkzeuge.

## Ursache

**Belegt:** Der Server lehnte einen Refresh mit `invalid_grant` ab, 1089 s nach dem letzten sichtbaren Speichern; der Client verwarf darauf
die Anmeldung aller Sitzungen. Das Token war nicht abgelaufen (18 Minuten alt, Laufzeit 30 Tage).

**Belegt am Code (reproduziert als roter Test, Commit `d2878d5`):** Geht das Ergebnis einer Rotation verloren und kommt das alte Token
später als 300 s, widerrief `OAuthRotation.judgeRepeat` die ganze Verbindung (`window_over`), obwohl niemand das Ergebnis je benutzt hatte.
Dasselbe ab der 6. Wiederholung (`repeat_limit`), also schon bei sechs Sitzungen mit demselben gespeicherten Stand.

**Wahrscheinlich, nicht bewiesen:** In Fall c rotierte um 21:27 ein Prozess ohne Protokoll (der Halter der Sperre; unter 300 s Restlaufzeit
erneuert Claude Code vorab), das Ergebnis erreichte den Speicher nicht, und der Wiederholungsversuch nach mehr als 300 s traf `window_over`.
**Nicht ausgeschlossen:** `successor_used` (ein Prozess mit eigenem Speicherstand) oder ein älteres Server-Image (vor ADR 0036) zu diesem
Zeitpunkt; laut STATUS lief an dem Tag sha-da95daf bzw. später sha-0d2bb78, beide mit ADR 0036, der Stand um 22:35 CET ist nicht belegt.
Entscheidend ist die Zeile `oauth.replay_revoked` im Server-Log um 26.11. 21:35:10 UTC (Feld `reason`): Bei `window_over` oder
`repeat_limit` deckt der Fix den Fall ab, bei `successor_used` nicht.

## Prüfung je Weg

| Weg | Codestelle | Ergebnis |
|---|---|---|
| Ablauf Access-Token | `OAuth/OAuthController.swift` `token()` (900 s) | gewollt, wird per Refresh erneuert |
| Ablauf Refresh-Token | ebd. (30 Tage je Rotation) | nicht die Ursache in Fall c; endete aber ruhende Verbindungen |
| Rotation und Wiederverwendung | `OAuth/OAuthRotation.swift` (`reuseWindow` 300 s, `maxRepeats` 5) | **Fehler:** verlorene Antwort wurde nach 300 s bzw. ab Sitzung 6 wie Diebstahl behandelt |
| Parallele Sitzungen | `token()` mit Zeilensperre auf dem Grant | Server serialisiert korrekt; Problem entsteht nur über den gemeinsamen Client-Speicher |
| Widerruf von Hand, Übernahme, Kontosperre | `OAuthController.revoke`, `OAuthTakeover.swift`, `Maintenance/AccountLock.swift` | nur durch Personen ausgelöst; kein automatischer Weg |
| Aufräumen | `Maintenance/CleanupExpired.swift` | löscht nur Abgelaufenes und Clients ohne Grant |
| MCP je Anfrage | `MCP/MCPController.swift` `handle()` | prüft Access-Token und Grant; Widerruf wirkt sofort |
| Client | Claude Code | löscht bei `invalid_grant` die gespeicherten Tokens; laufende Sitzungen übernehmen eine Neuanmeldung nicht immer |
| PWA und Apps | `Auth/AuthSupport.swift` `startSession`/`requireUser`, `Settings.sessionLifetime` | **Fehler:** festes Ende 30 Tage nach der Anmeldung, nie verlängert. PWA (`web/src/lib/auth.svelte.ts`) und App (Repo `Xcode/todo`, Stand `7f478be`) prüfen selbst keinen Ablauf, sie reagieren nur auf 401; die Server-Änderung wirkt ohne Client-Änderung |

Die Änderung steht in `docs/adr/0040-anmeldungen-laufen-nicht-ab.md`. Wirksam wird sie erst mit einem Server-Deploy.
