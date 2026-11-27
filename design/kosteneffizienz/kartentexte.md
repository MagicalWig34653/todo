# Noch auf Todolino nachzutragen (Karte `71FD73CF`)

Die Todolino-Verbindung war in der Umsetzungssitzung (27.11.2026) nicht angemeldet. Die Texte unten sind noch **nicht** auf dem Board.

## post_progress (Server)

- Phase 1 fertig: `usage_daily`, Preistabelle, `report_usage` (MCP) und REST idempotent, Kennzahlen. Rot `0998399` (26 Tests, 357 Fehler), grün `8207241`.
- Vertrag für den Sammler: `contracts/usage.yaml`; E2E `scripts/usage-e2e.sh` gegen SQLite und MariaDB je 56 Prüfungen ok.

## post_progress (Web)

- Phase 2 fertig: Seite `/costs` mit Urteil, Kacheln, Diagrammen, Top-Sitzungen, Leerzustand. Rot `9d26eb2`, grün `bfa1ebc`/`bf1a8a6`.
- Bilder hell/dunkel, Handy/Computer: `design/kosteneffizienz/` (angesehen).

## post_progress (Abschluss)

- Gegengelesen, kein Blocker; vier Befunde behoben (rot `9c14f9b`, grün `28cc743`): höchstens 20 000 Zeilen je Konto, Schwellen-Hinweise, Entwurf bleibt bei Ladefehler.
- Tests: MariaDB-Volllauf 1066 (9 übersprungen, 0 Fehler); SQLite 1066 (26 übersprungen, 1 Webhook-Zeitmessung unter Last rot, einzeln 3× grün); vitest 857/857; Playwright alle Specs, einzige rote Stelle (neuer Test in WebKit) behoben, Seite 8 Läufe × 9 in drei Browsern grün.
- Kein Deploy. Push- und CI-Belege: `docs/STATUS.md`.
- Lehre: Sammelläufe in zsh nur über ein sh-Skript starten (ein Lauf ging wegen fehlender Worttrennung leer durch). Netzfehler im Test braucht in WebKit `setOffline`, in Firefox `page.route`.

## record_decision

- `report_usage` läuft mit `tasks:write`, kein neuer Scope; Nutzung gehört dem Konto (`8207241`).
- „24 h“ ist ein Kalendertag; erledigte Karten über `updated_at`; Opus-Anteil ohne Vorgabe nur Info; keine Standardpreise für Codex (`8207241`).
- Höchstens 20 000 Zeilen je Konto, älteste Tage fallen weg (`28cc743`).

## request_review (Lino)

Seite „Kosteneffizienz“ liegt auf `main`, nicht deployt.

- Neu: `/costs` mit Ampel, acht Kennzahlen, Diagrammen, teuersten Sitzungen; Server nimmt nur Zähler an.
- Ansehen: Bilder in `design/kosteneffizienz/` (Testzahlen).
- Beim Deploy: `App migrate --yes` vor `serve` (neue Tabellen `usage_daily`, `usage_settings`).
- Offen: Sammler (Selbstverbesserung), Codex-Preise eintragen, Phase 3 Befunde, Apple.
