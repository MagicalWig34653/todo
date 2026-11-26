# UX-Umbau Schritt 1: Lesbarkeit (Karte `8B820AA8`)

Umsetzung von Schritt 1 aus [`konzept.md` §7](../konzept.md). Schritte 2 bis 9 sind nicht enthalten.

## Was sich geändert hat

| Problem (Ist-Aufnahme) | Jetzt |
|---|---|
| S5: Fragen/Reviews auf „Für dich“ als rohes Markdown (`**`, `##`, Listen in einem Absatz), alles fett, eine Karte füllt den halben Handybildschirm | Überschrift = erster Satz bzw. Überschrift des Textes (fett, höchstens 2 Zeilen), Rest als graue Vorschau ohne Markdown-Zeichen, Listenpunkte mit „·“, höchstens 3 Zeilen. Neuigkeiten ebenso (höchstens 3 Zeilen). Volltext im Kartenfenster. |
| Kartenfenster zeigte die Frage ebenfalls als Rohtext | Frage im Kartenfenster und in „Überblick“ über die sichere Markdown-Teilmenge (fett, Listen, Code). |
| M5: lange Erklärtexte (Brain-Vollmacht ein ganzer Handybildschirm, Graph, Kalender, Agenten) | Jeder Seitenkopf zeigt einen Satz, Rest hinter „Mehr erfahren“ (`Explainer.svelte`, `lib/explainer.ts`). Brain-Vollmacht beginnt mit einem neuen Kurzsatz; der volle Text (inkl. „Nicht erlaubt“) bleibt aufklappbar. |
| M6: Kartenfenster mit 6 Reitern, 3 davon meist leer | Reiter erscheinen nur mit Daten: Übersicht und Aktivität immer, Bericht und Pipeline mit Inhalt, Änderungen/Tests (noch keine Quelle) nie. Ein alter Link mit `&tab=` zeigt seinen Reiter weiter. |
| L2: schwebender Plus-Knopf verdeckt Karten, Knöpfe und Texte | Plus-Knopf sitzt auf dem Handy in der Kopfzeile neben dem Konto; kein schwebender Knopf mehr. Damit die Kopfzeile bei 320 px und 200 % Schrift nicht überläuft, liegt „Hilfe“ auf dem Handy nur noch im Kontomenü (wie Konzept §3). |

## Bilder

`vorher/` (Stand `c0ad345`) und `nachher/`, je `<ansicht>-<desktop|handy>-<hell|dunkel>.jpg` (1280 × 800 und 390 × 844), Ansichten:
`fuer-dich`, `karte`, `vollmacht`, `projekt-graph`, `kalender`, `projekt-liste`. Erzeugt mit [`bilder.spec.ts`](bilder.spec.ts)
(Anleitung im Kopf der Datei; natives Backend, frische SQLite, Demodaten aus `web/e2e/support/nowSeed.ts`, Chromium headless).

## Klickwege

Neu gemessen mit [`../ist/klickwege.spec.ts`](../ist/klickwege.spec.ts) (`UX_OUT=../design/ux-konzept/schritt-1`), Ergebnis:
[`klickwege.json`](klickwege.json) (26.11.2026, natives Backend, frische SQLite, Chromium headless).

| Weg | Desktop vorher → jetzt | Handy vorher → jetzt |
|---|---:|---:|
| 1 Karte anlegen (Projekt offen) | 3 → 3 | 3 → 3 (Plus jetzt in der Kopfzeile) |
| 2 Frage beantworten auf „Für dich“ | 1 → 1 | 1 → 1 |
| 4 Projekt wechseln | 1 → 1 | 2 → 2 |
| 5 Brain-Vollmacht öffnen | 3 → 3 | 3 → 3 |
| 5b Projektgruppen eines Projekts | 2 → 2 | 2 → 2 |
| Erste Review-Karte auf „Für dich“ (y in px) | 865 → 887 | 710 → 692 |

- Klickzahlen unverändert, wie erwartet: Schritt 1 ändert Lesbarkeit, nicht Wege (das kommt mit Schritt 3 und 4).
- Handy: Karten mit langem Markdown sind kürzer (vierte Karte 1014 → 938 px). Desktop: die erste Review-Karte liegt 22 px tiefer,
  weil eine Frage mit Liste („1. kurz 2. mit Beispiel“) jetzt Überschrift plus Vorschauzeile hat statt einer gemischten Zeile.
- 2b und 3 (über „Überblick“) scheitern im Messskript wie schon in der Ist-Messung (Locator findet nach dem Reiterwechsel keinen
  Knopf); nicht durch diesen Schritt verursacht, Weg laut Code unverändert 3 bzw. 4 Klicks.
