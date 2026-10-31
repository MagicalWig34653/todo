# Steuerzentrale und Agenten-Kanban

Die Steuerzentrale (in der PWA „Überblick“) ist der Ort, an dem Menschen ihre Coding-Agenten führen: Statt jedem Agenten Eingaben im Chat zu geben, läuft alles über das Kanban-Board der Projekte. Agenten holen sich Aufgaben, melden Fortschritt, stellen Rückfragen, hängen Build-Screenshots an und bitten um Review. Entscheidungen trifft der Mensch in der App. Grundlage: [ADR 0014](adr/0014-steuerzentrale-agenten-kanban.md), Vertrag [Steuerzentrale](api/command-center.html), Handbuch für Agenten: [agent-manual.md](agent-manual.md).

![Überblick im Kanban: Läuft, Frage offen, Review fällig, Bereit](screenshots/ueberblick-kanban.png)

## Was die Steuerzentrale zeigt

- **Board:** laufende Features mit Fortschritt (Prozent aus den Unteraufgaben oder der letzten Fortschrittsmeldung), der aktuelle Agent, die letzte Meldung und Build-Vorschauen. Spalten (Lanes): Läuft, Frage offen, Review fällig, Bereit, Blockiert, Erledigt. Alternativ als Liste mit Filtern.
- **Offene Fragen:** alle Rückfragen der Agenten im Konto oder Projekt. Hat die Frage Antwortoptionen, genügt ein Klick, sonst ein Freitext. Der Agent sieht die Antwort am Board, nicht im Chat.
- **Reviews:** fertige Arbeit wird zur Abnahme vorgelegt. Annehmen setzt die Aufgabe auf erledigt; „Änderungen anfordern“ verlangt eine Notiz und schickt die Aufgabe zurück in Arbeit.
- **Updates:** gruppierte Fortschrittsmeldungen, Builds und Statuswechsel.
- **Aktualität:** je Projekt der Sync-Zustand (aktuell, veraltet, nie abgeglichen), siehe [Projekt-Onboarding](projekt-onboarding.html).

![Offene Fragen im dunklen Design](screenshots/ueberblick-fragen.png)

## Wie Agenten arbeiten

1. Agent holt per MCP das Handbuch (`get_manual`) und das Projekt-Briefing (Ziele, Randbedingungen, Regeln, Definition of Done).
2. Er liest das Board (`get_command_center`), übernimmt eine Aufgabe (`claim_task`; eine zweite Übernahme wird ohne ausdrückliches `takeOver` abgewiesen) und meldet Fortschritt (`post_progress`).
3. Braucht er eine Entscheidung, stellt er eine Frage (`ask_question`, blockierend). Die Karte wandert nach „Frage offen“.
4. Er hängt Screenshots des Builds an (gleiche Build-ID, Plattform) und fordert ein Review an (`request_review`). Der Agent setzt eigene Arbeit nie selbst auf erledigt.
5. Der Mensch entscheidet in der Steuerzentrale. Der Agent liest das Ergebnis am Board.

Karten wandern automatisch in die passende Spalte, wenn das Projekt die Standardspalten für Agenten hat (Backlog, Bereit, In Arbeit, Frage offen, Review, Erledigt). Spalten werden über den Namen erkannt, eigene Boards funktionieren daher auch; fehlt eine Spalte, bleibt die Karte stehen. Die Vorlage lässt sich in der PWA mit einem Klick anlegen.

## Projekt-Briefing

Pro Projekt gibt es ein Markdown-Briefing (bis 20 000 Zeichen), das Agenten vor der Arbeit lesen. Schreiben darf nur, wer das Projekt verwalten darf (die Anweisungen steuern Agenten), mit Versionsprüfung gegen gleichzeitige Änderungen.

![Briefing und Spalten für Agenten](screenshots/ueberblick-briefing.png)

## Agenten und Mac-Runner in der PWA

Die Seite „Agenten“ koppelt Mac-Runner mit einem Einmalcode, verbindet Projekte mit Geräten, gibt Aufträge frei und bricht sie ab. Die Runner-Einrichtung steht unter [Runner](runner.html).

![Agenten-Seite: Runner koppeln, Geräte, Aufträge](screenshots/agenten.png)

## Aktivität und Projektkommentare

Der Aktivitätsfeed zeigt alle Ereignisse der eigenen Projekte (Status, Planung, Kommentare, Kriterien, Projektkommentare), neueste zuerst. Neue Einträge erscheinen live, ohne die Leseposition zu verschieben. Projektkommentare sind Diskussion auf Projektebene, getrennt von Aufgabenkommentaren.

![Aktivitätsfeed](screenshots/aktivitaet.png)

![Projektkommentare](screenshots/projektkommentare.png)

## Grenzen (Stand 31.10.2026)

- Die Ansichten gibt es in der PWA; die Apple-Apps haben die Steuerzentrale im Simulator, aber nicht alle Aktionen.
- Kein Sync-Feed und kein Push für Fragen und Reviews: Die PWA aktualisiert bei Fokus, Sichtbarkeit und alle 30 bis 60 Sekunden.
- Die Build-Galerie über alle Builds fehlt noch; Karten und Detail zeigen die Vorschauen.
- Einzelne Projektbindungen lassen sich nicht widerrufen (nur indirekt über den Geräte-Widerruf); Repository-Plätze eines widerrufenen Geräts sind nicht administrativ freigebbar.
- Die Aggregation lädt alle offenen Aufgaben der sichtbaren Projekte und ist für sehr große Bestände nicht optimiert.

Aktueller Stand und Testnachweise: [Status](status.html).
