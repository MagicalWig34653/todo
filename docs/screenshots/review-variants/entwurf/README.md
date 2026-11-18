# Entwurf: Review mit Variantenwahl (Karte 1D9C8B0C), nur Entwurf, kein Produktcode
Dateien: `entwurf.html` (statisch, `?s=1..5&theme=dark`), `rendern.mjs` (PNGs), `bilder-erzeugen.mjs` + `bilder/` (Beispielgrafiken, erfundene Daten), `inter-latin-wght-normal.woff2` (Schrift der App).
- `01-ueberblick-2-varianten-hell|dunkel.png`: Review-Liste, 2 Varianten (Bild, Label, 1 Zeile, "Wählen"), daneben "Änderungen anfordern".
- `02-kartendetail-3-varianten-fokus-hell.png`: Karten-Detail, 3 Varianten, Tastaturfokus auf "Wählen" bei B.
- `03-mobil-varianten-untereinander-hell.png`: 390 px breit, Varianten untereinander, 48 px hohe Tippflächen (gesamte Seite).
- `04-nach-wahl-rueckgaengig-verlauf-hell.png`: Leiste "Variante B gewählt: Radarkarte" mit "Rückgängig" und Restzeit, Verlaufseintrag.
- `05-sammelfreigabe-hinweis-hell.png`: Sammelleiste mit Hinweis "2 Reviews mit Varianten brauchen eine Wahl", Variantenzeilen ausgegraut.
Annahmen: Ein Tipp auf "Wählen" nimmt an; "Freigeben" entfällt bei Variantenreviews. Varianten sind Buttons in einer Liste (keine Radiogruppe, weil kein Wählen-dann-Bestätigen). Zugänglicher Name "Wählen: Variante B, Radarkarte". Badge "Wahl nötig". Sammelkopf: "Alle auswählbaren auswählen". Seitenleiste nur schematisch, Farben aus `web/src/routes/layout.css`.
Offene Fragen: Bild vergrößern (Tipp auf Bild)? Pfeiltasten zwischen Varianten zusätzlich zu Tab? Wird bei Bildfehlern/ohne Bild ein Platzhalter gezeigt? Soll das Rückgängig-Fenster auch als Toast außerhalb des Karten-Details erscheinen (Text wie hier)? Brauchen Entscheidungen des Brain-Pfads eine eigene Kennzeichnung?
Neu rendern: `WEB_DIR=<web mit node_modules> node rendern.mjs` (Playwright, Chromium headless).
