# Ist-Aufnahme Todolino-PWA (Stand `d429788`, 26.11.2026)

Karte `607DB96E`. Grundlage: Code unter `web/src` und eigene Screenshots gegen ein lokales natives Backend mit frischer SQLite und
Demodaten (`web/e2e/support/nowSeed.ts` plus Spalten, geplante Karten, Abhängigkeiten, Meilenstein, Projektgruppe). Keine Live-Instanz,
keine echten Daten. Aufnahme wiederholbar: [`ist/aufnahme.spec.ts`](ist/aufnahme.spec.ts), Klickwege: [`ist/klickwege.spec.ts`](ist/klickwege.spec.ts).
Bildnamen: `ist/<ansicht>-<desktop|handy>-<hell|dunkel>.jpg` (1280 × 800 und 390 × 844).

## 1. Seitenkarte

### SvelteKit-Routen (`web/src/routes`): 5 Seiten
`/` und `/[...path]` (die App), `/setup`, `/recover`, `/consent`, `/confirm-email`.

### Ansichten der App (`web/src/lib/routing.ts`): 17

```
Todolino
├─ Für dich          /for-you        (Start)                      bild: fuer-dich
├─ Suche             /search         (+ /labels/:id, /filter/:id) bild: suche
├─ Überblick         /overview       Reiter: Board · Offene Fragen · Reviews · Updates; Umschalter Kanban/Liste
├─ Jetzt             /now            4 Zähler-Kacheln, „Läuft gerade“   bild: jetzt
├─ Eingang           /inbox
├─ Heute             /today
├─ Anstehend         /upcoming
├─ Kalender          /calendar       Woche · Monat
├─ Filter und Labels /filter
├─ Teams             /teams
├─ Mehr (aufklappen)
│   ├─ Als Nächstes  /up-next
│   ├─ Agenten       /agents
│   ├─ Brain         /brain
│   ├─ Aktivität     /activity
│   └─ Einstellungen /settings       28 Unterseiten (15 persönlich, 13 Verwaltung)
├─ Hilfe             /help           5 Unterseiten
└─ Projekt           /project/:id    Anzeige: Liste · Board · Graph; im Modus „Projektmanagement“ Reiter Aufgaben/Überblick
                                     Adressen: list, board, overview, comments, graph, pipeline
Kartenfenster        ?card=…&tab=…   6 Reiter: Übersicht · Aktivität · Bericht · Pipeline · Änderungen · Tests
Aufgabenfenster      ?task=…         zweites, anderes Detailfenster derselben Aufgabe
```

Einstellungen (`web/src/lib/settingsNav.ts`): Profil · Passkeys, Wiederherstellung, Sitzungen · Darstellung · Benachrichtigungen, E-Mail ·
Berechtigungen · Verbundene Apps, Projektgruppen, Brain-Vollmacht, Webhook, Runner, MCP · Daten · Verwaltung: Konten, Einladungen, Server,
Mail, Push, Speicher, Anmeldung, Limits, Live, Aufräumen, Instanz, Apple, System.

### Zählung der Navigations- und Overlay-Elemente

| Element | Anzahl | Beleg |
|---|---:|---|
| Einträge der Seitenleiste vor den Projekten | 11 + „Mehr“ mit 5 | `Sidebar.svelte:251-272`, `menu-seitenleiste-mehr-desktop-hell` |
| Abschnitte darunter | bis zu 4 (Favoriten, Meine Projekte, Mit mir geteilt, Teams) | `Sidebar.svelte:275-347` |
| Handy-Tableiste | 5 (Für dich, Heute, Anstehend, Suche, Menü) + Plus-Knopf + Menü oben links | `Workspace.svelte:398-417` |
| Dialoge (`<Dialog>`) | 18 Verwendungen in 12 Dateien | ProjectPage 6, Workspace 2, je 1: Calendar, ForYou, ProjectBoard, QuickAdd, Sidebar, CardDetailDialog, AdminAccounts, DataPage, ProjectTransfer, VoicePrivacy |
| Popover-Menüs (`<Popover>`) | 9 Verwendungen in 7 Dateien | ProjectPage 2 (Anzeige, „…“), ProjectBoard 2 (Karte, Spalte), ProjectItem, Sidebar (Glocke), UserMenu, HelpMenu, CardHeader |
| Einträge je Menü | Projekt in der Seitenleiste 9, Projekt „…“ 6, Konto 5 + 3 Design-Knöpfe, Board-Karte 3 + alle Spalten + 4 Status, Spalte 5 + Farben | `ProjectItem.svelte:177-186`, `ProjectPage.svelte:330-342`, `UserMenu.svelte`, `ProjectBoard.svelte:340-459` |
| Reiterleisten | 3 (Kartenfenster 6, Überblick 4, Projekt 2) | `CardTabs`, `CommandCenter.svelte:240`, `ProjectPage.svelte:399` |
| Aufklappbereiche (`<details>`) | 5 | SharingPanel, CardPipeline, TaskLive, NowBlock, NowProject |

## 2. Klickwege der 5 häufigsten Aufgaben

Gezählt werden Klicks/Tipps; Tippen von Text und Scrollen nicht. Start ist „Für dich“, wenn nichts anderes steht.
Automatisch durchgeklickt (`ist/klickwege.json`), mit „(Code)“ markierte Wege aus dem Code abgeleitet.

| # | Aufgabe | Desktop | Handy | Weg |
|---|---|---:|---:|---|
| 1a | Karte anlegen, Projekt ist offen | 3 | 3 | „Aufgabe hinzufügen“ bzw. Plus → Titel, „Aufgabe hinzufügen“ → „Fertig“ (Dialog bleibt offen) |
| 1b | Karte in ein anderes Projekt (Code) | 5 | 5 | öffnen → Projektfeld → Projekt → hinzufügen → „Fertig“ (alternativ `#Projekt` tippen: 3) |
| 2a | Frage beantworten, Option, oben sichtbar | 1 | 1 | Option direkt auf „Für dich“ |
| 2b | … über „Überblick“ (Code) | 3 | 4 | (Menü) → Überblick → Reiter „Offene Fragen“ → Antwort |
| 3a | Review annehmen ohne Details | 1 + Scrollen | 1 + Scrollen | „Annehmen“ auf „Für dich“; erste Review-Karte bei 865 px (Desktop, Fenster 800 px) bzw. 710 px (Handy, 844 px) |
| 3b | Review mit Bericht/Bildern prüfen (Code) | 2 | 2 | Karte öffnen → entscheiden |
| 3c | … über „Überblick“ (Code) | 3 | 4 | (Menü) → Überblick → Reiter „Reviews“ → „Annehmen“ |
| 4 | Projekt wechseln | 1 | 2 + Scrollen | Seitenleiste bzw. „Menü“ → Projekt; vor den Projekten stehen 12 Zeilen |
| 5a | Brain-Vollmacht öffnen | 3 + Scrollen | 3 + Scrollen | Konto-Menü → „Einstellungen“ → „Brain-Vollmacht“ (unterhalb der ersten Bildschirmhöhe); über die Seitenleiste ebenfalls 3 (Mehr → Einstellungen → Eintrag) |
| 5b | Projektgruppen eines Projekts ändern | 2 + Auswahl | 2 + Auswahl | Projekt → „…“ → „Projektgruppen“ (Verwalten der Gruppen selbst liegt unter Einstellungen) |

**Befund:** Die Klickzahlen sind bereits niedrig. Das Problem ist nicht die Länge der Wege, sondern die **Zahl der Orte**, an denen
man suchen kann, ihre Überschneidung und die vielen kleinen Bedienelemente je Zeile. Das Konzept muss daran gemessen werden.

## 3. Probleme, nach Schwere

### Schwer (stört täglich)

| # | Problem | Bild / Beleg |
|---|---|---|
| S1 | **Drei Seiten für „was passiert / was braucht mich“**: Für dich, Überblick, Jetzt. Dieselben Fragen und Reviews erscheinen mehrfach mit gleicher Zahl 9 an zwei Menüpunkten; Überblick zeigt ohne Modus „Projektmanagement“ ein leeres Board neben Reitern mit 4 und 5 Einträgen. | `fuer-dich-*`, `ueberblick-*`, `jetzt-*` |
| S2 | **Fünf Seiten für „meine Aufgaben nach Zeit“**: Eingang, Heute, Anstehend, Als Nächstes, Kalender. „Heute“ ist leer, während „Als Nächstes“ eine überfällige Karte zeigt. | `heute-*`, `anstehend-handy-hell`, `als-naechstes-handy-hell`, `kalender-*` |
| S3 | **Zwei verschiedene Detailfenster je Aufgabe.** Eine Listenzeile hat vier Bedienelemente (Status, „Details“, Vergrößern, „Bearbeiten“); „Details“ führt zu einem Formularfenster mit eigenem Speichern-Knopf, das Symbol zum Kartenfenster mit 6 Reitern. | `projekt-liste-desktop-hell`, `aufgabe-*`, `karte-frage-*` |
| S4 | **Seitenleiste überladen:** 12 Zeilen vor dem ersten Projekt, plus Glocke, Einklappen, Konto-Menü, Hilfe-Menü. Bei 800 px Höhe ist nur ein Teil der Projekte sichtbar; auf dem Handy liegt alles hinter „Menü“, das oben links ein zweites Mal vorkommt. | `menu-schublade-handy-hell`, `projekt-liste-desktop-hell` |
| S5 | **Frage- und Review-Texte erscheinen als rohes Markdown** (`**fett**`, `##`, Listen in einem Absatz) und in Fettschrift; eine Karte füllt den halben Handybildschirm. Die Neuigkeiten darunter sind eine sehr lange, ungefilterte Liste. | `fuer-dich-handy-hell`, `fuer-dich-ganz-handy-hell` |

### Mittel

| # | Problem | Bild / Beleg |
|---|---|---|
| M1 | Projektkopf verteilt Ansichtswahl und Einstellungen auf „Anzeige“-Popover (Modus, Ansicht, Sortierung, Gruppierung, Erledigte), Kommentar-Symbol, „…“-Menü, „Teilen“ und Rollen-Chip. Die häufige Wahl Liste/Board/Graph kostet immer 2 Klicks. | `menu-ansicht-*`, `menu-projekt-*` |
| M2 | Modus „Klassisch / Projektmanagement“ verändert, welche Reiter es gibt; `/project/:id/overview` zeigt klassisch stillschweigend das Board. | `projekt-uebersicht-*` gleich `projekt-board-*` |
| M3 | Suche und „Filter und Labels“ verwalten beide Filter und Labels. | `suche-*`, `filter-handy-hell` |
| M4 | 28 Einstellungsseiten; Agentenzugriff ist auf 5 Einträge verteilt (Verbundene Apps, Projektgruppen, Brain-Vollmacht, MCP, Runner) plus Seite „Agenten“ unter „Mehr“. | `einstellungen-*`, `agenten-*` |
| M5 | Erklärtext statt Bedienung: Brain-Vollmacht beginnt auf dem Handy mit einem ganzen Bildschirm Fließtext; Graph, Kalender und Agenten ebenfalls mit langen Vorspannen. | `vollmacht-handy-*`, `projekt-graph-handy-hell` |
| M6 | Kartenfenster zeigt 6 Reiter, drei davon (Pipeline, Änderungen, Tests) oft ohne Daten (`cardTabs.ts: DATA_TABS`); auf dem Handy ist „Änderungen“ abgeschnitten. | `karte-frage-handy-hell` |

### Leicht

| # | Problem | Bild / Beleg |
|---|---|---|
| L1 | Board zeigt „Ohne Spalte“ als erste, breiteste Spalte; auf dem Handy ist die zweite nur angeschnitten. | `projekt-board-handy-*` |
| L2 | Schwebender Plus-Knopf verdeckt Inhalte (Karten, Knöpfe, Texte). | `fuer-dich-handy-hell`, `jetzt-handy-dunkel` |
| L3 | „Teams“ ist Hauptnavigation, wird aber selten gebraucht; Teams stehen zusätzlich als Abschnitt in der Seitenleiste. | `teams-*` |

## 4. Was gut ist und bleiben soll
- Antworten und „Annehmen“ direkt auf der Startseite (1 Klick).
- Schnell-Anlegen mit Textkürzeln (`#Projekt`, `@Label`, Datum, `p1`).
- Kartenfenster als eigene Adresse mit Vor/Zurück durch die Liste.
- Ruhige Gestaltung, funktionierender Dunkelmodus (stichprobenartig auf allen 15 Hauptansichten angesehen).

## Grenzen
Chromium, Desktop-Emulation der Handybreite (kein echtes Gerät, keine installierte PWA). Verwaltungsseiten, Dialoge zum Teilen, zu
Meilensteinen, Pipeline, Daten/Konto sowie Setup/Recovery/Consent nicht einzeln fotografiert (aus dem Code gezählt). Deutsche Oberfläche;
Datumsfelder zeigen das Format des Test-Browsers (en-US). „Häufigste Aufgaben“ ist eine Annahme aus dem Auftrag, keine Nutzungsmessung.
