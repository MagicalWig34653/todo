# Kartentexte f-0caacb34 (Todolino-MCP war nicht angemeldet, bitte nachtragen)

## A1A4690B: post_progress
- Ursache: Neuladen/volle Navigation bricht den Long-Poll im Browser ab, der Server hielt die Anfrage bis 25 s als Wartende; Limit 8 je Konto, ab der 9. Ladung 429.
- Fix `6f9da77`: Parameter `client` je Tab (sessionStorage); neuere Wartende ersetzt die ältere sofort. Vertrag live-refresh 1.1.0, ADR 0022.
- Rot `6347e5d` (Swift), `3d0adc2` (E2E: 4x 429). Grün: swift test, vitest 860/860, check 0, E2E 6 Specs gegen natives Backend.
- Beleg: `docs/belege/A1A4690B-sync-wait-429.md`. Kein Deploy.
- CI-Nacharbeit: Test-Client ohne URLSession (Linux) `69d5e42`, Test deterministisch `bca9775`; E2E-Flake `mandate-relogin` Firefox behoben `cd0efc3`.
- Lehre: Swift-Tests mit echtem HTTP immer ohne URLSession schreiben (Linux-CI) und auf Registrierung statt auf Zählerstand warten. Zwei CI-Runden hat das gekostet. Den E2E-Stack über den eigenen Port beenden, sonst läuft ein Backend auf gelöschter SQLite weiter.

- Gegenlesen: 1 wichtiger Befund (`changed:false` trotz neuem Token) behoben `c0df373`.
- GitHub auf `c0df373` grün: CI 45939914442, Docker publish 45939914526, Pages 45939914448, E2E 45941121925 (97 Läufe OK, darin `live-wait-reload` gegen das veröffentlichte Image).
- record_decision (nachzutragen): optionaler Parameter `client` statt Stream-Heartbeat, `sendBeacon` oder höherem Limit; Commit `6f9da77`, ADR 0022.

## 9608B355: post_progress
- kit 3.1.0 -> 3.4.1, adapter-static 4.0.0 -> 4.0.1 (web), yaml 2.8.1 -> 2.9.1 (docs-site). Alerts #1, #2, #4 bis #7.
- npm audit vorher 3 verwundbare Pakete, nachher 0; check 0, vitest 860/860, build ok, docs-site dist bytegleich.
- Beleg: `docs/belege/9608B355-dependabot-sveltekit.md`.
- Commit `a115ec8`; Alerts #1 bis #7 auf GitHub `fixed`; GitHub auf `c0df373` grün: CI 45939914442, Docker publish 45939914526, Pages 45939914448, E2E 45941121925 (97 Läufe OK, darin `live-wait-reload` gegen das veröffentlichte Image).
- Lehre: `card-detail` auf fremdem Port braucht `E2E_BASE_URL`; der erste Lauf gegen frisch gestartetes Vite kann scheitern (auf `main` genauso).
