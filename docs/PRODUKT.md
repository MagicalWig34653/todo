# Produktkonzept

## Ziel

Eine ruhige, intuitive Todo-App mit schrittweise zuschaltbarer Projektplanung. Menschen und Coding-Agenten arbeiten an denselben Aufgaben. Ideen, Rückfragen, Entscheidungen, Fortschritt und Ergebnisse bleiben zusammenhängend in der App.

Motivation: Der Nutzer erreicht bei Todoist schnell die Paywall und vermisst die direkte Anbindung an Claude Code für konkrete Entwicklungsprojekte. Ein vollständiger selbst betreibbarer Funktionsumfang ohne künstliche Paywall ist die vorgeschlagene Richtung; Lizenz und Geschäftsmodell sind noch offen.

## Bestätigter Kern

- Frei verschachtelbare Projekte und Unterprojekte nach Art von Todoist.
- Keine fest eingebauten Bereiche „Privat“ und „Arbeit“. Solche Gruppierungen können normale Projekte sein.
- Mischung aus Todo und Projektplanung, ohne komplexe Pflichtfelder für einfache Aufgaben.
- Teams und Freigaben für Projekte.
- Passkeys als primärer Login; Benutzername/Passwort nachrangig und serverseitig ein-/ausschaltbar.
- PWA mit Svelte und shadcn-svelte; SwiftUI für iPhone, iPad, Mac und Apple Watch.
- MariaDB und mehrere Backend-Replikate unter Docker Swarm.
- MCP mit OAuth; Aufgaben, Rückfragen, Fortschritt und Anhänge einschließlich Screenshots für UI-Demos.
- Projektordner am Mac zuordnen; die Mac-App kann selbstständig einen Claude-Agenten starten, um freigegebene Aufgaben zu bearbeiten.

## Beispielablauf

1. Am iPhone eine Idee im Projekt „Website“ erfassen, optional mit Referenzbild.
2. Idee zur Klärung oder Umsetzung freigeben.
3. Der zugeordnete Mac übernimmt den Auftrag, sobald er verfügbar ist.
4. Der Agent liest Aufgabe und freigegebenen Projektkontext.
5. Er stellt eine konkrete Rückfrage im Eintrag; der Nutzer antwortet in der App.
6. Der Agent setzt die Arbeit fort und aktualisiert den kurzen Fortschrittsstand.
7. Er hängt Screenshots, Prüfergebnisse und gegebenenfalls einen PR-Link an.
8. Der Nutzer prüft das Ergebnis, fordert Änderungen an oder nimmt es ab.

## Vorgeschlagene Funktionsgruppen

Diese Funktionen wurden im Brainstorming vorgeschlagen. Sie sind Planungsbestandteil, aber nicht alle Voraussetzung der ersten Version.

### Alltag

Inbox, schnelle Erfassung, Titel/Beschreibung, Termin, Priorität, Unteraufgaben, Labels, Erinnerungen, wiederkehrende Aufgaben, Suche und gespeicherte Filter. Sprachaufnahme und Teilen-Menü als spätere Erfassungswege. Offline-Erfassung mit nachvollziehbarem Abgleich.

Einfache Aufgaben benötigen nur einen Titel. Zusätzliche Planungs- und Agentenfunktionen werden bei Bedarf sichtbar.

### Projektplanung

Liste und Board zuerst; Kalender und Timeline später. Alle Ansichten zeigen dieselben Aufgaben. Fälligkeit und geplante Bearbeitung sind getrennte Felder.

Abhängigkeiten kennzeichnen blockierende Aufgaben. Meilensteine bündeln Ergebnisse über Unterprojekte hinweg. Ein Projektüberblick zeigt Ziel, Stand und nächste Schritte. Grobe Aufwandsschätzungen und eine Ansicht „Als Nächstes“ können die Planung ergänzen. Automatische Prozentwerte ohne belastbare Grundlage vermeiden.

### Zusammenarbeit

Zuweisung an Personen, Kommentare, Antworten, Erwähnungen, verständlicher Aktivitätsverlauf und gezielte Benachrichtigungen. „Braucht mich“ bündelt Rückfragen, Freigaben, Abnahmen und Probleme. Mehrere Antworten lassen sich gesammelt erfassen.

### Klärung und Umsetzung

Normale Aufgabe, „Mit Agent klären“ und „Umsetzen lassen“ beschreiben die gewünschte Zusammenarbeit. Neue Gedanken lösen standardmäßig keinen Agentenlauf aus. Eine spätere Projektregel kann dies ausdrücklich automatisieren.

Abnahmekriterien als Checkliste, Vorschläge für Teilaufgaben, dokumentierte Entscheidungen und eine Review-Schleife: Ergebnis prüfen, abnehmen oder Änderungen anfordern. Agenten liefern standardmäßig „Zur Abnahme“; der Mensch schließt ab.

### Anhänge und UI-Demos

Anhänge an Aufgaben und Kommentaren, auch über MCP. Referenzbilder, Zwischenstände und Ergebnisse unterscheidbar machen. Screenshots zunächst als Bildvorschau mit Begleittext; später Bildmarkierungen, Kommentare an Bildstellen, Vorher/Nachher-Vergleiche und Versionen. Bildschirmaufnahmen, PDFs und andere Dateien später ergänzen.

### Projektwissen

Ziele, Designvorgaben, relevante Dokumente, Repository-Verknüpfungen und Entscheidungen als explizit freigegebener Kontext. Wichtige Antworten lassen sich in dauerhafte Projektentscheidungen überführen. Ein neuer Agentenlauf muss ohne die alte Unterhaltung arbeitsfähig sein.

## Zustände

Arbeitsannahme für Aufgaben: `open`, `in_progress`, `in_review`, `done`; Archivierung separat. Eine Idee kann eine normale offene Aufgabe bleiben.

Agentenauftrag und Aufgabe haben getrennte Zustände. „Wartet auf Mac“, „Antwort benötigt“, „Agent arbeitet“ und ein fehlgeschlagener Lauf beschreiben die Ausführung. Sie dürfen nicht unbemerkt den fachlichen Aufgabenstatus ersetzen.

## Gerätefokus

- PWA: vollständige Aufgaben- und Projektarbeit, auch ohne native App.
- iPhone: schnelle Erfassung, Antworten, Planung, Ergebnisprüfung.
- iPad: umfangreichere Projektarbeit und Bildprüfung.
- Mac: vollständige Arbeit plus Ordnerzuordnung und Runner-Verwaltung.
- Watch: schnelle Erfassung, Abhaken und kurze Antworten; keine vollständige Projektplanungsoberfläche.

## Noch nicht entschieden

Produktname, Lizenz, Hostingmodell, genaue Rollen-/Vererbungsdetails, Umfang von Kalender/Timeline, externe Kalenderanbindung, Uploadgrenzen, Aufbewahrung und weitere Agentenanbieter. Der erste produktive Agent ist Claude Code; die interne Struktur soll weitere Anbieter zulassen.
