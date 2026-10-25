# Umsetzungsplan

Die Reihenfolge ist ein Vorschlag für überprüfbare vertikale Schritte. Weder sämtliche Ideen noch alle Plattformen müssen im ersten Schritt fertig sein. Datenmodell und Verträge sollen spätere Schritte ermöglichen.

## 0 – Grundlage und technische Machbarkeit

- Beide Ziel-Repositories anlegen, Dokumentation und Agenteneinstiege installieren.
- Aktuelle kompatible Toolchains und Abhängigkeiten prüfen; Lockfiles pflegen.
- ADRs für Stack, Identität, Projektrechte, Repository-Verträge und Dateispeicher.
- Backend/PWA-Entwicklungsstart mit MariaDB; Apple-Projekt mit gemeinsamem API-Kern.
- Linux-Build früh prüfen.
- Kleine Machbarkeitsprüfung für Claude-Start am Mac, Dateizugriff und Fortsetzung.

Abnahme: dokumentierter Start aus frischem Checkout, Health-Endpunkte, PWA erreicht Backend, Apple-Grundgerüste bauen mit dokumentierten Voraussetzungen. Keine Scheinfunktionen als fertig markieren.

## 1 – Persönlicher vertikaler Schnitt

- Bootstrap/Einladung, Passkey-Registrierung, Login, Logout, Sitzung und Recovery-Grundlage.
- Optionaler normaler Passwort-Login mit serverseitigem Schalter und nachrangiger Oberfläche.
- Projekte/Unterprojekte, einfache Aufgaben und Liste.
- Minimaler SwiftUI-Client nutzt denselben API-Vertrag.

Abnahme: Aufgabe am Web-Client erstellen und im nativen Client sehen; Konten sind voneinander getrennt; ausgeschalteter Passwortweg wird auch per direktem API-Aufruf abgelehnt. Passkey-Challenge ist zwischen Replikaten nutzbar.

## 2 – Zusammenarbeit und Projektplanung

- Teams, Einladungen, Projektfreigaben und definierte Vererbung.
- Zuweisungen, Kommentare, Aufgabenverlauf und Abnahmekriterien.
- Board, separate Fälligkeit/Planung und Ansicht „Braucht mich“.

Abnahme: gezielt freigegebenes Unterprojekt ohne Sicht auf private Geschwister nutzen; Rechteentzug wirkt auf API, Suche und Dateien; Versionskonflikte werden verständlich behandelt.

## 3 – MCP und Anhänge

- OAuth-Consent mit Aktionen und Projektbegrenzung, widerrufbare Grants.
- MCP zum Lesen/Bearbeiten, Fragen/Antworten und Fortschritt.
- Screenshot-Upload, Vorschau und Download mit identischen Projektgrenzen.
- Einen echten Claude-Code-Client anbinden.

Abnahme: Agent liest eine freigegebene Aufgabe, stellt eine Rückfrage, liest die Antwort und hängt einen Screenshot an. Zugriff auf nicht freigegebene Projekte scheitert. Widerruf funktioniert. Protokolltests allein ersetzen die reale Clientprüfung nicht.

## 4 – Selbstständiger Mac-Runner

- Geräte koppeln, Projektordner freigeben, Auftrag übernehmen, Claude starten.
- Dauerhafte Zustände, Heartbeats, Fragenpause/Fortsetzung, Stoppen und Wiederanlauf.
- Warteschlange pro Repository; Ergebnis zur Abnahme liefern.

Abnahme: iPhone-Aufgabe führt bei verfügbarem Mac zu einem einzelnen Lauf; ausgeschalteter Mac führt zu verständlichem Warten. Netzverlust, App-Neustart und konkurrierende Runner erzeugen keine unkontrollierte Doppelarbeit. UI-Demo kommt als Screenshot zurück.

## 5 – Alltag und Geräte vervollständigen

Offline-Erfassung/Sync, Erinnerungen, wiederkehrende Aufgaben, Labels/Filter, mobile Teilen-Funktion, iPad-/Mac-Optimierung und Watch-Kernfunktionen. Push gezielt für Rückfragen und Abnahmen.

Abnahme: offline erfasste Aufgabe wird nach Wiederverbindung genau einmal übernommen; echte Geräte prüfen, einschließlich Passkeys und Watch-Verbindung.

## 6 – Erweiterte Planung und Artefakte

Abhängigkeiten, Meilensteine, Kalender/Timeline, Aufwand, Projektwissen, Bildmarkierungen, Vergleich/Versionierung, weitere Dateiformate und gegebenenfalls parallele Worktrees. Reihenfolge anhand tatsächlicher Nutzung festlegen.

## Durchgehend

Autorisierungsmatrix, MariaDB-Konkurrenz, Upload-/OAuth-Grenzen und Wiederanlauf gezielt testen. Echte Swarm-Mehrreplikaprüfung, Backups und Restore vor produktiver Nutzung. UI-/E2E-Prüfungen auf kritische Abläufe konzentrieren. Keine Tests schreiben, die nur interne Implementierungsdetails wiederholen.

Jeder Abschnitt dokumentiert geänderte Verträge, Migrationen, ausgeführte Prüfungen, offene Grenzen und den nächsten konkreten Schritt.
