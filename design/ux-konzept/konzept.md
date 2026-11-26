# UX-Konzept Todolino-PWA: weniger Orte, ein Kartenfenster, Zeitleiste

Karte `607DB96E` (Zeitleiste: `8F6C48E2`). Reines Konzept auf Stand `d429788`, nichts umgebaut. Grundlage:
[Ist-Aufnahme](ist-aufnahme.md). Bilder: [Übersichtstafel](tafel.png), [Wireframes](wireframes/index.html)
(PNGs in `wireframes/png/`, neu rendern aus `web/`: `node ../design/ux-konzept/wireframes/render.mjs`).

## 0. Empfehlung

1. **Fünf Bereiche statt 15 Menüzielen:** Für dich · Aufgaben · Projekte · Zeitleiste · Suche; Einstellungen hinter dem eigenen Namen.
2. **Ein Kartenfenster** statt zwei; Listenzeilen ohne „Details/Vergrößern/Bearbeiten“.
3. **Zusammenlegen:** Für dich + Überblick + Jetzt; Heute + Anstehend + Als Nächstes + Eingang + Kalender; 28 Einstellungsseiten → 10.
4. **Zeitleiste** als eigene Hauptansicht, mit neuem Feld „Beginn“ und einem eigenen Lese-Endpunkt; zuerst nur lesen, dann ziehen.

Ehrlich vorweg: Die Klickwege sind schon kurz. Der Gewinn liegt darin, dass es je Frage **einen** Ort gibt.

## 1. Leitlinien
- Ein Ding, ein Ort. Ansichten sind **Umschalter** derselben Daten, keine eigenen Seiten.
- Sichtbarer Umschalter statt Popover, wenn häufig benutzt; Popover nur für Seltenes.
- Reiter, Zähler und Hinweise erscheinen nur, wenn es Daten gibt.
- Erklärtext höchstens eine Zeile, Rest hinter „Mehr erfahren“.
- Alte Adressen leiten um; Lesezeichen, Mail-Links und App-Deeplinks bleiben gültig (`routing.ts` kann das schon).

## 2. Informationsarchitektur

```
Für dich     /for-you      Braucht dich (Alle · Fragen · Reviews · Fällig) | Läuft | Verlauf | Brain*
Aufgaben     /tasks        Heute · Anstehend · Als Nächstes · Eingang   — Darstellung: Liste | Kalender
Projekte     /project/:id  Liste | Board | Zeitleiste | Abhängigkeiten    + Seitenpanel „Projekt“
Zeitleiste   /timeline     alle Projekte, Projekt oder Projektgruppe
Suche  ⌘K    /search       Suche, gespeicherte Filter, Labels
(Name unten) /settings     Konto · Anmeldung · Darstellung & Mitteilungen · Teams & Freigaben · Agenten-Zugriff · Hilfe
                           Verwaltung: Konten · Server · Zustellung · Regeln
Karte        ?card=…       Übersicht | Verlauf | Technik*          (* nur wenn vorhanden)
```

## 3. Navigation

**Desktop (≥ Menü-Breakpoint):** Seitenleiste von oben: „+ Aufgabe“ (Taste `Q`), 5 Bereiche (nur „Für dich“ mit Zähler), Favoriten,
Projektbaum (eigene, geteilte, je Team eine Überschrift), unten Name → Einstellungen. Kein zweiter Kopfbereich mit Glocke, Hilfe und
Konto-Menü. Die Leiste bleibt einklappbar. Inhaltskopf: Titel, Ansichtsumschalter, höchstens zwei Knöpfe.

**Handy:** Tableiste **Für dich · Aufgaben · Projekte · Zeitleiste · Suche**. Kopfzeile: Zurück/Titel, rechts „+“ und Avatar
(Einstellungen). Kein schwebender Knopf, keine Schublade, kein doppeltes „Menü“. Der Tab „Projekte“ zeigt „Zuletzt“, Favoriten und den Baum.

## 4. Alt → neu (nichts verschwindet ohne Ziel)

### Ansichten

| Alt | Neu |
|---|---|
| Für dich (Fragen, Reviews, Bestätigungen, Zugriffsanfragen, Überfälliges) | Für dich › **Braucht dich**; Desktop mit Detailspalte rechts |
| Für dich › Neuigkeiten mit Bildern | Für dich › **Verlauf** (je Karte gebündelt, Bild-Zoom bleibt) |
| Überblick › Offene Fragen, Reviews (inkl. Sammelentscheidung, Rückgängig) | Für dich › Braucht dich, Filter „Fragen“/„Reviews“; Mehrfachauswahl bleibt |
| Überblick › Board (Features, Backlog, Kanban/Liste, Sync-Stand, Wächter-Lage, Repository-Zeile) | Für dich › **Läuft** (Liste je Projekt, Lage-Zeile oben); Kanban bleibt in der Projektansicht „Board“ |
| Überblick › Updates | Für dich › Verlauf |
| Jetzt (Kacheln, läuft, ohne Lebenszeichen, ruhige Projekte) | Für dich › Läuft |
| Aktivität (mit Projektfilter) | Für dich › Verlauf, Filter „Projekt“ und „Alle Ereignisse“ |
| Brain | Für dich › Brain (nur wenn verbunden) |
| Eingang, Heute, Anstehend, Als Nächstes | Aufgaben › vier Segmente; Überfälliges steht in „Heute“ oben |
| Kalender (Woche, Monat, Ziehen, „Start und Dauer“, Ungeplante) | Aufgaben › Darstellung „Kalender“ |
| Suche + Filter und Labels | Suche (Filter und Label-Verwaltung als Abschnitte); `/filter` leitet um |
| Teams (anlegen, einladen, annehmen) | Einstellungen › Teams & Freigaben; Team-Überschrift im Projektbaum führt dorthin; Einladungen zusätzlich in „Braucht dich“ |
| Agenten (Runner koppeln, Geräte, Projekt verbinden, Aufträge) | Einstellungen › Agenten-Zugriff › Runner; laufende Aufträge in „Läuft“, Auftrag freigeben an der Karte |
| Hilfe (5 Seiten, Doku/Fehler/Änderungen) | Einstellungen › Hilfe (eine Seite mit Abschnitten); `?` öffnet weiter die Tastaturkürzel |
| Setup, Recovery, Consent, E-Mail bestätigen | unverändert |

### Projekt

| Alt | Neu |
|---|---|
| Popover „Anzeige“: Ansicht Liste/Board/Graph | Umschalter im Kopf (1 Klick); Graph heißt „Abhängigkeiten“, behält Optionen, Builds und Erledigt-Historie |
| Popover „Anzeige“: Sortierung, Gruppierung, Erledigte | bleibt als kleines Popover „Filtern“ |
| Popover „Anzeige“: Modus Klassisch/Projektmanagement, „auf Unterprojekte“ | entfällt als Schalter (Entscheidung 3): Agenten-Elemente erscheinen, sobald Daten da sind |
| Reiter Aufgaben/Überblick (Management) | Chip „3 brauchen dich“ im Kopf → Für dich, nach Projekt gefiltert; Agenten-Auftrag (Brief) ins Panel |
| „…“-Menü: Favorit, Umbenennen, Farbe, Meilensteine, Gruppen, Pipeline | Seitenpanel **„Projekt“** mit Abschnitten Allgemein · Teilen · Gruppen · Meilensteine · Pipeline |
| Teilen-Knopf, Rollen-Chip | Teilen-Knopf öffnet Panel-Abschnitt „Teilen“; Rolle steht dort und im Hinweisbanner bei Nur-Lesen |
| Kommentar-Symbol → Dialog | Knopf „Chat“ im Kopf öffnet das Panel im Abschnitt „Chat“ |
| Kontextmenü Projekt (9 Einträge), Spaltenmenü, Brotkrumen, Beschreibung | unverändert |

### Karte und Zeilen

| Alt | Neu |
|---|---|
| Aufgabenfenster „Details“ (Planung, Wiederholung, Erinnerungen, Labels, Anhänge, Kommentare) | Seitenspalte bzw. Abschnitte des Kartenfensters; speichert sofort, kein „Planung speichern“; `?task=` leitet auf `?card=` um |
| Zeile: Status, Details, Vergrößern, Bearbeiten | Häkchen + Titel (öffnet Karte); Status und Verschieben im Kontextmenü (Rechtsklick, langes Drücken, „⋯“ bei Fokus) |
| Reiter Übersicht · Aktivität · Bericht · Pipeline · Änderungen · Tests | Übersicht · Verlauf (Aktivität + Bericht) · Technik (Pipeline, Änderungen, Tests, Live), nur mit Daten |
| Board-Kartenmenü und Karten-„…“ | ein gemeinsames Menü (Link kopieren, Projekt öffnen, hoch/runter, Spalte, Status, löschen) |

### Menüs, Popover, Dialoge

| Alt (Anzahl) | Neu |
|---|---|
| Popover 9: Anzeige, Projekt „…“, Board-Karte, Spalte, Projekt-Kontext, Glocke, Konto, Hilfe, Karten-„…“ | **4**: Filtern, Projekt-Kontext, Spalte, Karte. Glocke → Braucht dich; Konto (inkl. Design, Berechtigungen, Verwaltung, Abmelden) und Hilfe → Einstellungen |
| Dialoge 18 | **11**: Aufgabenfenster, Kommentare, Pipeline, Gruppen, Farbe, Meilensteine, Teilen entfallen (Karte bzw. Panel „Projekt“). Es bleiben Schnell-Anlegen, Karte, Bild-Zoom, Kalendertermin, Spalte löschen, Projekt anlegen, Tastaturkürzel, Konto-Bestätigung, Datenlöschung, Übertragung, Sprachdaten löschen |

### Einstellungen: 28 → 10 Seiten (alte Adressen springen zum Abschnitt)

| Neue Seite | Alte Seiten |
|---|---|
| Konto | Profil, Sitzungen, Daten; Abmelden |
| Anmeldung | Passkeys, Wiederherstellung |
| Darstellung & Mitteilungen | Darstellung, Benachrichtigungen, E-Mail |
| Teams & Freigaben | Teams (bisher Hauptmenü), Berechtigungen |
| Agenten-Zugriff | Verbundene Apps, MCP, Brain-Vollmacht, Projektgruppen, Webhook, Runner, Agenten (bisher „Mehr“) |
| Hilfe | 5 Hilfeseiten |
| Verwaltung › Konten | Konten, Einladungen |
| Verwaltung › Server | Server, System, Instanz, Apple |
| Verwaltung › Zustellung | Mail, Push |
| Verwaltung › Regeln | Anmeldung, Limits, Live, Aufräumen, Speicher |

„Agenten-Zugriff“ ist verbindungszentriert: eine Zeile je Verbindung mit Projekten/Gruppen und dem Schalter „Vollmacht“;
Details (Zustimmungstext, Ausschlüsse) klappen dort auf. Sicherheitsrelevante Bestätigungen bleiben unverändert.

## 5. Klickzahlen vorher → nachher

Ohne Tippen und Scrollen; „vorher“ aus der Ist-Aufnahme, „nachher“ aus dem Konzept (noch nicht gemessen).

| Aufgabe | Desktop | Handy |
|---|---|---|
| 1 Karte anlegen (offenes Projekt) | 3 → **2** (Enter legt an und schließt, ⇧Enter für die nächste) | 3 → **2** |
| 1 … in anderes Projekt | 5 → **4** | 5 → **4** |
| 2 Frage beantworten, sichtbar | 1 → 1 | 1 → 1 |
| 2 … gezielt unter vielen | 3 → **2** (Filter „Fragen“) | 4 → **2** |
| 3 Review mit Bericht entscheiden | 2 → 2 (Detailspalte, Liste bleibt stehen) | 2 → 2 |
| 3 … gezielt unter vielen | 3 → **2** | 4 → **2** |
| 4 Projekt wechseln | 1 → 1 (mehr Projekte ohne Scrollen) | 2 → 2 („Zuletzt“, ohne Scrollen) |
| 5 Brain-Vollmacht öffnen | 3 → **2** | 3 → **2** (ohne Scrollen) |
| Zusatz: Liste ↔ Board | 2 → **1** | 2 → **1** |

| Orte und Bedienelemente | vorher | nachher |
|---|---:|---:|
| Menüziele der Seitenleiste (ohne Projekte) | 15 (10 sichtbar + 5 unter „Mehr“) | 5 (+ Einstellungen unten) |
| Einstellungsseiten (+ Hilfe) | 28 (+5) | 10 (Hilfe darin) |
| Popover-Menüs / Dialoge | 9 / 18 | 4 / 11 (+ 1 Seitenpanel) |
| Kartenreiter / Detailfenster je Aufgabe | 6 / 2 | 3 / 1 |
| Bedienelemente je Listenzeile | 5 (Häkchen, Status, Details, Vergrößern, Bearbeiten) | 2 (Häkchen, Titel; „⋯“ bei Fokus) |

## 6. Zeitleiste (eigene Hauptansicht)

Eigene Gestaltung; die Merkmale der Karte `8F6C48E2` sind der Wunschumfang.

### Aufbau und Verhalten (Desktop)
- **Links** Zeilen, gruppiert nach Meilenstein (Standard) oder Projekt; Gruppen einklappbar. Karten ohne Termin liegen unten in
  „Ohne Termin (n)“ und lassen sich auf die Achse ziehen.
- **Rechts** Balken von Beginn bis Fällig; Zoom Tag · Woche · Monat; Heute-Linie und Knopf „Heute“. Nur Fälligkeit: Punkt.
  Nur Beginn: offener Balken.
- **Fortschritt** als dunklerer Anteil im Balken, Zahl daneben; ohne Angabe kein Anteil.
- **Meilensteine** als Raute auf der Gruppenzeile; Seitenspalte mit Meilensteinen (Sprungziel) und gespeicherten Ansichten.
- **Abhängigkeiten** als Pfeile (Ende → Start). **Konflikte** rot, gestrichelt und mit Text, z. B. „4 Tage zu spät: Vorgänger endet nach
  Beginn“. Farbe nie als einziges Zeichen.
- **Detailspalte** rechts (dieselbe wie im Kartenfenster): Beginn/Fällig mit −/+ je Tag, Dauer, Fortschritt, „hängt ab von“,
  „blockiert“, letzte Aktivität, „Karte öffnen“.
- **Bearbeiten:** Balken verschieben, Ränder ziehen, vom Balkenende auf eine Karte ziehen legt eine Abhängigkeit an. Rückgängig-Hinweis
  nach jeder Änderung. Nachfolger werden **nicht** automatisch verschoben; Angebot „Nachfolger mitverschieben (2)“.
- **Tastatur:** ↑↓ Zeile, ←→ ein Tag, ⇧←→ Dauer, Enter Detail. Jede Zeile hat eine Textfassung für Screenreader.
- **Rechte:** Nur-Lesende sehen alles ohne Griffe; unsichtbare Vorgänger erscheinen wie heute gar nicht.

### Handy
- Hochformat: gruppierte Liste, je Zeile Titel, Termin und ein Mini-Balken auf gemeinsamer 4-Wochen-Achse (Kopf bleibt stehen),
  Heute-Linie, Konflikttext unter dem Titel. Wischen auf der Achse blättert um eine Woche.
- **Kein Ziehen** (Kollision mit Scrollen). Tippen öffnet ein Blatt mit −1 Tag/+1 Tag/+1 Woche für Beginn und Fällig und die Abhängigkeiten.
- Querformat ab ca. 700 px: Desktop-Diagramm ohne Seitenspalte.

### Datenmodell: vorhanden und Lücken (am Code belegt)

| Bedarf | Heute | Lücke / Vorschlag |
|---|---|---|
| Beginn und Ende | `task_planning`: `due_at`, `planned_at`, `planned_minutes` (`PlanningExtModels.swift:87-101`); Dauer 5 bis 1440 Minuten (`planning-ext.yaml` 1.1.0) | **Kein mehrtägiger Beginn.** Neues optionales Kalenderdatum `start_on`; Balken `start_on`→`due_at`, Rückfall `planned_at`. `planned_at` nicht umdeuten: Kalender und automatischer Start hängen daran (Änderung widerruft `autoStart`) |
| Daten für viele Karten | `GET /v1/planning/schedule` (`PlanningExtController.swift:34`): höchstens 62 Tage (`PlanningExtService.swift:58`), 500 Einträge, ohne Fortschritt, Meilenstein, Kanten | **Neu** `GET /v1/planning/timeline?from&to&projectID|groupID`: Zeilen mit Beginn, Fällig, Fortschritt, Meilensteinen, Kanten, Konflikten; Fenster ca. 400 Tage, seitenweise |
| Abhängigkeiten | `planning_dependencies` (`PlanningExtModels.swift:106`), anlegen/löschen mit Zyklusprüfung; `GET /dependencies` nur je Projekt, ohne `plannedAt` (`PlanningExtController.swift:12-22`) | Nur Ende → Start ohne Puffer: reicht für Version 1 |
| Konflikte | Server liefert `after_due`, `prerequisite_open`, `prerequisite_later`, `repository_overlap` (`ScheduleService.swift:210-239`), gerechnet auf `plannedAt` | auf `start_on` erweitern, „Tage zu spät“ mitliefern |
| Meilensteine | `title`, `due_at` (`PlanningExtModels.swift:115`); nur anlegen, auflisten, löschen, zuordnen (`PlanningExtController.swift:46-50`) | **Ändern fehlt** (`PATCH`: Titel, Datum). Karte in mehreren Meilensteinen: Gruppierung nach dem frühesten, Rest als Chip |
| Fortschritt | Meldungen in `task_progress_notes` (`CommandCenterModels.swift:149`), berechneter Wert im Kartenkontext | in den Timeline-Endpunkt übernehmen, gesammelt laden |
| Gespeicherte Ansichten | `discovery_saved_filters` speichert nur Filterkriterien (`DiscoveryModels.swift:31`) | Version 1: Adresse (`?zoom=&group=`) plus lokal; später Feld „Darstellung“ |
| MCP, Apple | `update_task_planning` kennt `start_on` nicht | Vertrag, MCP-Werkzeug und Handbuch im selben Schritt; Feld nur schreiben, wenn der Schlüssel im Body steht (wie `plannedMinutes`) |
| Leistung (Hinweis) | `addDependency` lädt alle Kanten (`PlanningExtService.swift:139 ff.`) | Der Timeline-Endpunkt darf nur Kanten der gewählten Karten laden |

## 7. Umbau in einzeln auslieferbaren Schritten

Aufwand als grobe Schätzung in Agententagen (ein Umsetzungsagent samt Tests, ohne Review-Wartezeit). Jeder Schritt: Test zuerst,
E2E, hell/dunkel, Desktop/Handy, Weiterleitungen alter Adressen.

| # | Schritt | Inhalt | Aufwand | Hängt ab von |
|---|---|---|---:|---|
| 1 | Lesbarkeit | Markdown in „Für dich“ richtig und gekürzt, Erklärtexte kürzen, leere Reiter ausblenden, Plus-Knopf verdeckt nichts | 1 | – |
| 2 | Ein Kartenfenster | Aufgabenfenster ins Kartenfenster, Zeilen aufräumen, 3 Reiter | 3–4 | – |
| 3 | Navigation + Aufgaben | 5 Bereiche, neue Tableiste, Segmente inkl. Kalender, Teams/Agenten/Hilfe umgezogen | 3–4 | – |
| 4 | Für dich als Zentrale | Überblick, Jetzt, Aktivität, Brain zusammenführen, Detailspalte | 4–5 | 2, 3 |
| 5 | Projektkopf + Panel | Umschalter, Panel „Projekt“, Modus-Schalter entfernen | 2–3 | 4 (Ersatz für Projekt-Überblick) |
| 6 | Einstellungen | 10 Seiten, „Agenten-Zugriff“; Sicherheitsprüfung wegen Vollmacht | 3 | 3 |
| 7 | Zeitleiste, Daten | `start_on`, Timeline-Endpunkt, Meilenstein ändern, Vertrag, MCP, Migration | 2–3 | – |
| 8 | Zeitleiste, lesen | Desktop-Diagramm, Handy-Liste, Detailspalte mit −/+ | 4–5 | 7, 3 |
| 9 | Zeitleiste, ziehen | Ziehen, Verbinden, Tastatur, Rückgängig | 3–4 | 8 |
| | **Summe** | | **25–32** | |

**Reihenfolge:** 1 → 2 → 3 → 4 → 5 → 6, danach 7 → 8 → 9. Ist die Zeitleiste dringender: 7 und 8 nach Schritt 3 vorziehen
(7 ist unabhängig). Schritt 3 hat als einziger einen sichtbaren Bruch; er kommt in einem Stück.

**Erfolg prüfen:** Klickwege mit `ist/klickwege.spec.ts` nach jedem Schritt neu messen; Lino probiert Schritt 2 und 3 am Handy.

**Risiken:** viele bestehende E2E-Specs hängen an Menüs und Test-IDs (Anpassung ist in den Schätzungen nur grob enthalten);
„Für dich“ darf nicht selbst überladen werden (Segmente laden getrennt); Datum ohne Uhrzeit braucht eine klare Zeitzonenregel.

## 8. Offene Entscheidungen für Lino

1. **Navigation:** (a, empfohlen) fünf Bereiche wie oben · (b) nur Schritte 1, 2, 6 und das Menü so lassen.
2. **Beginn in der Zeitleiste:** (a, empfohlen) neues Datum „Beginn“ · (b) „Geplanter Start“ wiederverwenden (ohne Migration, aber
   Kalender und automatischer Start verschieben sich mit).
3. **Modus Klassisch/Projektmanagement:** (a, empfohlen) abschaffen, Agenten-Elemente zeigen sich bei Daten · (b) als Projekt-Einstellung behalten.

## 9. Folgen für die Apple-App

Die Apple-App sollte dieselben fünf Bereiche, ein Kartenfenster und die Zusammenlegungen übernehmen und muss `start_on` samt
Timeline-Endpunkt und Weiterleitung alter Deeplinks kennen. Die Zeitleiste kommt dort erst nach der PWA (iPad/Mac Diagramm, iPhone Liste),
und ältere App-Versionen dürfen das neue Feld beim Speichern der Planung nicht löschen.
