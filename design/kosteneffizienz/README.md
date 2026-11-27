# Seite „Kosteneffizienz“ (Karte `71FD73CF`, Phase 1 und 2)

- Konzept: Orchestrator `docs/konzept-kosteneffizienz.md`. Vertrag: `contracts/usage.yaml`. Entscheidungen: `docs/adr/0038-kosteneffizienz.md`.
- Seite: PWA `/costs`, Menüpunkt „Kosteneffizienz“.
- Bilder aus `web/e2e/costs.spec.ts` (`E2E_SCREENSHOTS=1`, echtes Backend, erfundene Testzahlen), am 27.11. angesehen:

| | Computer (1280 breit) | Handy (390 breit) |
|---|---|---|
| gefüllt, hell | `filled-desktop-light.png` | `filled-phone-light.png` |
| gefüllt, dunkel | `filled-desktop-dark.png` | `filled-phone-dark.png` |
| leer, hell | `empty-desktop-light.png` | `empty-phone-light.png` |
| leer, dunkel | `empty-desktop-dark.png` | `empty-phone-dark.png` |

- Zu sehen: Ampel mit Satz, acht bewertete Kacheln, Kosten pro Tag gestapelt, Modellmix, Projekte, teuerste Sitzungen mit Markierung „teuer und ohne Ergebnis“, Hinweis auf Modelle ohne Preis, eingeklappte Preise und Schwellen; leer: „Noch keine Daten, Sammler einrichten“.
- In den ganzseitigen Computerbildern endet die Seitenleiste nach 800 px (Aufnahmeart, Leiste ist an das Fenster gebunden).
