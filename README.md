# Todo – Konzept und Übergabe an Claude Code

Stand: 25.10.2026. Arbeitsname: **Todo**.

Dies ist das Hauptarbeitsrepo für Backend und PWA sowie das kanonische Projektgedächtnis. Das separate Apple-Repo enthält SwiftUI-Apps und Mac-Runner. Beide Git-Repositories sind initialisiert; Es existiert ein Grundgerüst (Health-Endpunkte, PWA-Shell); Funktionen folgen entlang docs/UMSETZUNGSPLAN.md.

## Einstieg

Claude Code hier öffnen und STARTPROMPT.md lesen. AGENTS.md enthält die verbindlichen Arbeitsregeln. Den lokalen Apple-Pfad findest du in der ignorierten .workspace.local.json. Diese Datei bei einem neuen Checkout passend anlegen.

## Lokaler Start (Entwicklung)

```sh
docker compose up -d db s3          # MariaDB (23306) und Adobe S3Mock (29090)
swift run App serve --port 28081    # Backend lokal; oder: docker compose up -d --wait backend (28080)
cd web && npm install && npm run dev  # PWA, proxyt /health an das Backend
swift test                          # Backendtests (SQLite)
```

Voraussetzungen: Swift 6.2+, Docker, Node. Zugangsdaten sind Dev-Platzhalter (`.env.example`).

## Dokumente

- [Produktkonzept](docs/PRODUKT.md): Ziel, Anforderungen und Funktionsideen.
- [Architektur](docs/ARCHITEKTUR.md): Komponenten, Datenmodell, Synchronisierung und Betrieb.
- [Identität und Berechtigungen](docs/IDENTITAET-UND-RECHTE.md): Passkeys, Teams, Projektfreigaben und OAuth.
- [Agenten und MCP](docs/AGENTEN-UND-MCP.md): Runner, Auftragsablauf, Rückfragen und Anhänge.
- [Umsetzungsplan](docs/UMSETZUNGSPLAN.md): vertikale Schritte und Abnahmekriterien.
- [Entscheidungen](docs/ENTSCHEIDUNGEN.md): Nutzervorgaben, Arbeitsannahmen und offene Punkte.
- [ADRs](docs/adr/): Stack, Dateispeicher, Referenzen, Runner-Start.
- [Status](docs/STATUS.md): tatsächlicher Stand und nächste Schritte.
- [Vorlage AGENTS.md](templates/AGENTS.md): Arbeitsregeln für beide Repositories.
- [Vorlage CLAUDE.md](templates/CLAUDE.md): Einstieg für Claude Code.

Die Timetrack-Repositories sind Referenzquellen. Ihre Existenz beweist keine Funktion dieser neuen Anwendung. Noch vorgeschlagene Funktionen sind ausdrücklich von bestätigten Vorgaben getrennt.

**Verbindlich:** Sessions sind wegwerfbar. Das Hauptrepository ist die Source of Truth. Dokumentation wird während der Arbeit nach jedem abgeschlossenen Teilschritt aktualisiert; ein neuer Agent muss ohne alte Chats fortsetzen können.
