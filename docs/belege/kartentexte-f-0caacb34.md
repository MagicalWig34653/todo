# Kartentexte f-0caacb34 (Todolino-MCP war nicht angemeldet, bitte nachtragen)

## A1A4690B: post_progress
- Ursache: Neuladen/volle Navigation bricht den Long-Poll im Browser ab, der Server hielt die Anfrage bis 25 s als Wartende; Limit 8 je Konto, ab der 9. Ladung 429.
- Fix `6f9da77`: Parameter `client` je Tab (sessionStorage); neuere Wartende ersetzt die ältere sofort. Vertrag live-refresh 1.1.0, ADR 0022.
- Rot `6347e5d` (Swift), `3d0adc2` (E2E: 4x 429). Grün: swift test, vitest 860/860, check 0, E2E 6 Specs gegen natives Backend.
- Beleg: `docs/belege/A1A4690B-sync-wait-429.md`. Kein Deploy.
- Lehre: Startskript für den E2E-Stack muss alte Prozesse über den eigenen Port beenden, sonst läuft ein Backend auf gelöschter SQLite weiter (ein Fehllauf).

## 9608B355: post_progress
- kit 3.1.0 -> 3.4.1, adapter-static 4.0.0 -> 4.0.1 (web), yaml 2.8.1 -> 2.9.1 (docs-site). Alerts #1, #2, #4 bis #7.
- npm audit vorher 3 verwundbare Pakete, nachher 0; check 0, vitest 860/860, build ok, docs-site dist bytegleich.
- Beleg: `docs/belege/9608B355-dependabot-sveltekit.md`.
