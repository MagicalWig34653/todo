# PWA: Seite "Jetzt" und Schnellzugriff (Karten 692891DF, B0CF5F73)

Vertrag: `contracts/session-status.yaml` ab 1.4.0 (Feld `now`, `compact`), `projects[].builds[].id` ab 1.5.0, Entscheidung: ADR 0034 und Nachträge.

## Seite "Jetzt" (`/now`)

Gestaltung "Leitstand" (Redesign 25.11.2026): erst die Zahlen, dann das Wichtige, Einzelheiten zugeklappt.

Aufbau: `web/src/lib/components/NowView.svelte` (Laden, Live-Hinweise, gespeicherte Wahl) und `web/src/lib/components/now/` (`NowBlock`, `NowTiles`, `NowActiveItem`, `NowWaitingList`, `NowProject`, `ProjectMark`).

Kopf: Titel, Live-Zeichen, Stand. Darunter der Block aus `GET /v1/overview/now` Feld `now` (`data-testid="now-block"`):

0. **Vier Kacheln** (`now-tiles`, `now-tile` mit `data-tile`): "Wartet auf dich", "Läuft gerade", "Zuletzt fertig", "Ohne Lebenszeichen", Zahlen aus `now.counts`. Klick oder Enter setzt Fokus und Ansicht auf den Abschnitt ("Ohne Lebenszeichen" klappt auf). Bei 0 keine Schaltfläche. Der Punkt bei "Läuft gerade" pulsiert nur ohne "Bewegung reduzieren". Schmal 2×2, ab 28 rem Inhaltsbreite vier nebeneinander.
1. **Läuft gerade** (`now-running`, `now-running-item`): Karten-Raster, ab 36 rem Inhaltsbreite zwei Spalten. Projekt mit `#` in Projektfarbe, Titel (Karte öffnet das Karten-Detail), Notiz auf 3 Zeilen, Balken mit Prozentzahl, Bearbeiter, "seit …", "Lebenszeichen vor …", Frist-Chip (überfällig: Warnsymbol, Wort und Farbe). Sitzungen sind dieselbe Karte mit "Sitzung". Leer: "Gerade läuft nichts mit Lebenszeichen."
2. **Wartet auf dich** (`now-waiting`, `now-waiting-item`): eine Liste mit Symbol für Frage bzw. Review, Vorschau auf 2 Zeilen ohne Markdown-Zeichen, Projekt, Kartentitel, Alter, Antworten/Ansehen. Zuerst 5, Umschalter `now-waiting-toggle` (`aria-expanded`). Zählt der Server mehr, als er liefert (höchstens 100), steht das darunter (`now-waiting-more`).
3. **Zuletzt fertig** (`now-done`, `now-done-item`): letzte 6 Stunden, höchstens 5; sind es mehr, "5 von n gezeigt". Die Kachel nimmt `counts.recentlyDone` und zieht nur Einträge ab, die seit der Antwort aus dem Fenster gefallen sind.
4. **Ohne Lebenszeichen (n)** (`now-silent`, `<details>`, zu; `now-silent-item`): gedämpfte, kompakte Zeilen.

**Projekte** darunter: eine Zeile je Projekt (`now-project`) mit Farbe, Name, Kennzahlen, letzter Aktivität. Mit Block standardmäßig **zu**, die gespeicherte Wahl (`todo.nowExpanded`) gilt weiter. Ruhige Projekte getrennt. Fehlt `now` (alter Server), sind die Projekte die einzige Ansicht und aktive sind offen. Aufgeklappt: Läuft, Sessions, Wartet auf dich (gleiche Liste wie oben), Builds, Ereignisse (zuerst 5, `now-events-toggle`).

**Builds** sind je `buildID` und Plattform eine Zeile (neueste zuerst; Status vom neuesten Eintrag, der einen hat; Zahl der Dateien); die Kennzahl "n Builds" zählt diese Zeilen. Der Server liefert je Projekt höchstens 5 Dateien; bei 5 weist die Seite darauf hin.

Sitzungen, deren Satz mit "Beendet" beginnt (Groß-/Kleinschreibung egal, nach Trim), erscheinen nirgends und zählen nicht. Relative Zeiten im Block richten sich nach `serverTime` (zwischen Abrufen mitgeführt). Aktualisierung über den zentralen Live-Dienst. Überschriften: `h2` Seite, `h3` Abschnitte, `h4` Karten und Projektabschnitte. Jede keyed `each` über Serverdaten nutzt eindeutige Schlüssel (`web/src/lib/keys.ts`, Absturz aus Karte B0CF5F73).

Logik (rein): `web/src/lib/now.ts` (u. a. `nowTiles`, `groupBuilds`, `notListed`, `blockOf`, `isExpanded`) und `web/src/lib/previewText.ts`; Tests `web/tests/now.test.ts`, `now-block.test.ts`, `now-redesign.test.ts`. Texte: `web/src/lib/i18n/de-now.ts`.

## Schnellzugriff vom Start

Auf "Für dich" (`ForYouView.svelte`) steht unter der Überschrift ein schmaler Link "Jetzt · n laufen · m warten auf dich" (`NowEntry.svelte`, `data-testid="now-entry"`). Er lädt nur `GET /v1/overview/now?compact=true&limit=1` (Zähler aus `now.counts`, keine Projektdaten) beim Öffnen und bei Live-Hinweisen. Alter Server: der Link bleibt ohne Zähler.

## E2E

- `web/e2e/now.spec.ts` (Chromium): Verhalten gegen ein Backend mit `now` (1.4.0); "Ohne Lebenszeichen" per `page.route` aus der echten Antwort. Bilder nach `$NOW_SHOTS` (Standard `docs/screenshots/jetzt/`).
- `web/e2e/now-redesign.spec.ts` (Chromium, Firefox, WebKit; in `scripts/e2e-ci.sh`): Kacheln, Raster, Wartet-Liste, Projekte, Builds, alter Server, 320/375 px. Daten aus `web/e2e/support/nowSeed.ts`. Service Worker sind dort blockiert, weil WebKit sonst `page.route` nicht anwendet. Bilder nur mit `NOW_REDESIGN_SHOTS=docs/screenshots/now-redesign NOW_REDESIGN_PREFIX=nachher`.
- `web/e2e/overview-pages.spec.ts`: lädt `/now` mit wiederholten `buildID`s und prüft die gruppierten Build-Zeilen.
