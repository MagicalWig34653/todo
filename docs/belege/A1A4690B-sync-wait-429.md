# Beleg Karte A1A4690B: 429 auf /v1/sync/wait bei schnellem Seitenwechsel

Stand 27.11.2026, Lauf gegen das echte native Backend (`.build/debug/App serve`, frische SQLite, Port 28310) mit PWA über Vite (Port 25310). Kein Stub, kein Mock.

## Ursache
Eine Seitenladung öffnet einen Long-Poll `GET /v1/sync/wait` (bis 25 s). Das Neuladen bricht ihn im Browser ab, der Server (Vapor) bekommt davon nichts mit und hält die Anfrage als Wartende bis zum Timeout. Das Limit ist 8 Wartende je Konto (`LiveSettings.maxWaitersPerAccount`), die neunte Seitenladung binnen 25 s bekommt 429.

## Rot (vor dem Fix), Commits 6347e5d und der E2E-Commit danach
`npx playwright test e2e/live-wait-reload.spec.ts --project=chromium`: 12 Seitenladungen hintereinander, jede wartet erst, bis ihr `/v1/sync/wait` abgeschickt ist.
```
Expected: []   Received: [429, 429, 429, 429]      (Ladung 9 bis 12)
1 failed
```
Swift (`LiveRefreshDisconnectTests`, echter HTTP-Server): nach dem Abbruch bleibt die Wartende registriert, "expected 0 registered waiters, have 1".

## Grün (nach dem Fix)
```
✓ 1 [chromium] › e2e/live-wait-reload.spec.ts:9:1 › twelve quick page loads in a row never get 429 on /v1/sync/wait (6.7s)
1 passed (8.7s)
```
Rohausgabe: `web/e2e/` Lauf, siehe unten für die Gesamtläufe.

## Fix
Server: optionaler Parameter `client` (`Sources/TodoKit/Live/LiveController.swift`, `LiveHub.swift`), je (Konto, client) höchstens eine Wartende, die neuere beendet die ältere. PWA: `web/src/lib/liveRefresh.ts`, `liveClientId` (Schlüssel je Tab in `sessionStorage`). Vertrag `contracts/live-refresh.yaml` 1.1.0, ADR 0022.
