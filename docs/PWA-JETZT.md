# PWA: Seite "Jetzt" und Schnellzugriff (Karte 692891DF)

Vertrag: `contracts/session-status.yaml` ab 1.4.0 (Feld `now`, `compact`), Entscheidung: ADR 0034 und Nachträge.

## Seite "Jetzt" (`/now`, `NowView.svelte`)

Oben, vor den Projektabschnitten, steht der Block aus `GET /v1/overview/now` Feld `now` (`data-testid="now-block"`), in dieser Reihenfolge:

1. **Läuft gerade** (`now-running`, Einträge `now-running-item`): nur Einträge mit Lebenszeichen der letzten 30 Minuten. Je Eintrag Projekt, Titel (Karte öffnet das Karten-Detail), ein Satz, "seit …" (nur Karten), "Lebenszeichen vor …", Frist ("Frist 25.11., 10:30" bzw. "Überfällig seit …"), Fortschrittsbalken bei Prozentwert. Leer: "Gerade läuft nichts mit Lebenszeichen."
2. **Wartet auf dich** (`now-waiting`, `now-waiting-item`): offene Fragen und ausstehende Reviews, Antworten/Ansehen öffnet das Karten-Detail. Strikt getrennt von "Läuft gerade".
3. **Zuletzt fertig** (`now-done`, `now-done-item`): in den letzten 6 Stunden erledigt, höchstens 5 sichtbar.
4. **Ohne Lebenszeichen (n)** (`now-silent`, ein `<details>`, standardmäßig zu; `now-silent-item`): gedämpfte Darstellung, n = `counts.silent`.

Relative Zeiten richten sich nach `serverTime` (zwischen Abrufen mitgeführt), nicht nach der Geräteuhr. Fehlt `now` (alter Server), erscheint nur die bisherige Projektansicht. Die Projektabschnitte darunter blieben unverändert, blenden aber Sitzungen aus, deren Satz mit "Beendet" beginnt (Groß-/Kleinschreibung egal, nach Trim); diese zählen auch nicht in den Kennzahlen und nicht für "ruhig". Aktualisierung unverändert über den zentralen Live-Dienst. Die Abschnittsüberschriften sind `h3` unter dem Seitentitel (`h2` aus `PageHeader`).

Logik (rein, getestet in `web/tests/now-block.test.ts`): `web/src/lib/now.ts` (`isEndedText`, `visibleSessions`, `durationText`, `lifeSignText`, `sinceText`, `dueInfo`, `recentDone`, `cleanBlock`, `blockOf`, `serverClock`, `showEmptyPage`, `waitingCard`, `nowEntry`). Texte: `web/src/lib/i18n/de-now.ts`.

## Schnellzugriff vom Start

Auf "Für dich" (`ForYouView.svelte`) steht unter der Überschrift ein schmaler Link "Jetzt · n laufen · m warten auf dich" (`NowEntry.svelte`, `data-testid="now-entry"`). Er lädt nur `GET /v1/overview/now?compact=true&limit=1` (Zähler aus `now.counts`, keine Projektdaten) beim Öffnen und bei Live-Hinweisen. Alter Server: der Link bleibt ohne Zähler.

## E2E

`web/e2e/now.spec.ts` braucht ein Backend mit `now` (1.4.0). Die Zeitfälle "Ohne Lebenszeichen" werden per `page.route` aus der echten Antwort erzeugt. Screenshots nach `$NOW_SHOTS`: `jetzt-block-hell|dunkel.png` (Desktop 1280), `jetzt-block-mobil-hell|dunkel.png` (375 px).
