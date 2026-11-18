Echte PWA-Bilder (Chromium, Beispieldaten "ShowerNow"), je `-hell` und `-dunkel`: `01` Review-Liste mit drei Bild-Varianten, `03` Karten-Detail, `06` nach der Wahl mit Rückgängig-Leiste (Radarkarte).
Reine Textvarianten ohne Bildplatz (Wetterdaten-Anbieter): `02` Desktop, `05` Handy; `07` Handy direkt nach der Wahl einer Textvariante (Rückgängig-Hinweis unten).
Handy (`04`, `05`, `07`) ist Pixel-7-Emulation; erzeugt mit `DEMO_SHOTS=1 npx playwright test e2e/review-variants-demo.spec.ts --project=chromium` gegen ein frisches Backend.
