# Startauftrag für Claude Code

Du sollst eine neue Todo- und Projektplanungsanwendung auf Grundlage dieses Übergabepakets einrichten und schrittweise implementieren.

## Zuerst lesen

Arbeite aus diesem Backend-/PWA-Hauptrepository. Lies AGENTS.md, README.md, docs/STATUS.md, docs/ARBEITSPLAN.md und die übrigen Konzeptdokumente. Beide Repositories und ihre Agenteneinstiege sind bereits eingerichtet. Die lokalen Pfade stehen in .workspace.local.json. Keine neuen Repositories oder unabhängigen Konzeptkopien anlegen.

Sessions sind wegwerfbar. Das Repository ist die Source of Truth. Aktualisiere Entscheidungen, Status, Arbeitsplan und Prüfnachweise nach jedem abgeschlossenen Teilschritt und vor Kontextwechseln.

## Technischer Ausgangspunkt

Arbeitsannahme ist Swift mit Vapor/Fluent im Backend, MariaDB, Svelte/SvelteKit mit shadcn-svelte als PWA und SwiftUI für die Apple-Apps. Swift wurde nach Sichtung von Timetrack empfohlen; Go war der ursprüngliche Wunsch und bleibt eine Alternative bei konkreten Hindernissen. Prüfe kompatible aktuelle Versionen und die kritischen Bibliotheken, bevor du sie festschreibst. Begründe eine Abweichung als ADR; wechsle den Stack nicht stillschweigend.

Das System muss von Beginn an für mehrere API-Replikate im Docker Swarm entworfen sein. Mac-Runner sind eigene Clients und führen lokal gestartete Coding-Agenten im zugeordneten Projektordner aus.

## Referenzprojekte – nur lesen

- `../timetrack-backend`
- `../timetrack-pwa`

Lies deren AGENTS.md und relevante Architektur-/Statusdokumente vor einer Übernahme. Untersuche insbesondere Passkeys, Recovery, OAuth/MCP, Sitzung/CSRF, MariaDB, Job-Leases, PWA und API-Verträge. Verändere diese Referenzprojekte nicht. Übernimm keine privaten Daten, Secrets, Laufzeitdatenbanken, Git-Historien oder projektspezifischen Zeittrackingregeln.

Timetrack verwendet ein Rückfallpasswort zur Recovery, keine normale Passwort-Anmeldung. Seine Freigaben sind kein allgemeines Team-/Projektmodell. Ein globaler `auth_lock` soll nicht ungeprüft übernommen werden. Reale MCP-Client-Kompatibilität und Swarm-Mehrreplikabetrieb gelten durch vorhandenen Referenzcode nicht als bewiesen.

## Erster Arbeitsabschnitt

1. Quellen und vorhandene Zielpfade prüfen; kurze Bestandsaufnahme schreiben.
2. Vorhandene Repository-Struktur und Agenteneinstiege prüfen; Arbeitsplan aktualisieren.
3. Stack-/Abhängigkeitsprüfung und grundlegende ADRs festhalten.
4. Lauffähiges Backend-/PWA-Grundgerüst und Apple-Projektgrundgerüst erstellen.
5. Den ersten vertikalen Schnitt gemäß docs/UMSETZUNGSPLAN.md implementieren: Passkey-Registrierung und Login, persönliche Projekte mit Unterprojekten, einfache Aufgaben.

Routineentscheidungen selbst treffen. Stelle nur Fragen, wenn eine fehlende Antwort eine tragfähige Umsetzung verhindert. Führe für jeden Abschnitt passende Prüfungen aus und dokumentiere Grenzen. Die Einrichtung allein ist nicht die fertige Anwendung; arbeite entlang der dokumentierten Etappen weiter und hinterlasse bei jeder Übergabe einen fortsetzbaren Stand.
