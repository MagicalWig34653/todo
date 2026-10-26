# Todo

Intuitive Todo- und Projektplanung mit frei verschachtelten Projekten, Teams und Freigaben. Passkey zuerst, als PWA und SwiftUI-App, mit MCP/OAuth-Anbindung und lokalen Mac-Runnern, die Claude Code im Projektordner starten. Rückfragen, Fortschritt und Screenshots hängen direkt an der Aufgabe.

Arbeitsname: **Todo**. Status: in aktiver Entwicklung, noch nicht für den Produktivbetrieb freigegeben.

## Produktüberblick

- **Projekte und Aufgaben:** beliebig tiefe Projekthierarchie, Unteraufgaben, Labels, Fälligkeit und geplante Bearbeitung getrennt, Priorität, Board-Ansicht, Abhängigkeiten, Meilensteine, Suche.
- **Zusammenarbeit:** Teams, Projektfreigaben mit vererbten Rechten (lesen, kommentieren, bearbeiten, verwalten), Kommentare, Aufgabenverlauf, Abnahmekriterien, Anhänge.
- **Identität:** Passkeys (WebAuthn), mehrere benannte Passkeys, Sessions, Wiederherstellung per Einmalcode, Rate-Limits. Passwort-Login nur optional.
- **Agenten:** MCP-Endpunkt `/mcp` mit OAuth (PKCE, Resource Indicators), Agentenaufträge mit Checkpoints; lokale Mac-Runner starten Claude Code. Aufträge werden in der App gespeichert, nicht in einer Chat-Sitzung.

## Architektur

```text
PWA / SwiftUI / MCP-Clients / Mac-Runner
                  | HTTPS
          API-Replikate (Swift, Vapor)
     gemeinsame Fachlogik und Rechteprüfung
                  |
        MariaDB + S3-kompatibler Dateispeicher
```

- Backend: Swift 6.2, Vapor, Fluent; modularer Monolith (`Sources/TodoKit`). REST, MCP und Apps nutzen dieselben Fachregeln und dieselbe Rechteprüfung (`ProjectAccess`).
- Datenbank: MariaDB 12.3 im Betrieb, SQLite für schnelle Tests.
- PWA: SvelteKit 3, Tailwind, shadcn-svelte, statische Auslieferung (`web/`).
- Dateien: S3-kompatibel (Entwicklung: Adobe S3Mock).
- Apple-Apps und Mac-Runner liegen in einem separaten Repository; API-Verträge liegen hier unter `contracts/`.

Details: [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md).

## Schnellstart (Entwicklung)

Voraussetzungen: Swift 6.2+, Docker, Node 22+.

Ports der Entwicklungsumgebung:

| Dienst | Port |
| --- | --- |
| MariaDB | 23306 |
| S3Mock | 29090 |
| Backend (Docker) | 28080 |
| PWA (Vite-Dev-Server) | 25173 |

```sh
cp .env.example .env                      # nur Dev-Platzhalter, keine echten Zugangsdaten
docker compose up -d --wait db s3         # MariaDB (23306) und S3Mock (29090)
docker compose --profile app up -d --wait backend   # Backend im Container (28080)
# alternativ lokal: swift run App serve --port 28081

cd web && npm install
npm run dev -- --port 25173               # PWA; proxyt API-Aufrufe an das Backend
```

Die Datenbank muss vor dem Betrieb migriert werden (Compose-Profil `app` enthält einen Migrationsdienst). Das Bootstrap-Token für das erste Admin-Konto stammt aus der Umgebung (`.env.example`).

## Tests

```sh
swift test                                # Backend, SQLite (MariaDB-Tests werden übersprungen)
scripts/test-mariadb.sh                   # Backend gegen echte MariaDB (docker compose up -d db)
cd web
npm run check                             # svelte-check
npm run build                             # statischer Build
npm test                                  # Vitest
npm run test:e2e                          # Playwright, braucht laufendes Backend-Image + S3Mock
```

Liegt der Checkout in einem File-Provider-Ordner (z. B. `~/Documents`), scheitert `swift test` am Codesigning; Workaround: `--scratch-path` auf einen Ordner außerhalb. Siehe [docs/STATUS.md](docs/STATUS.md).

## CI und Veröffentlichung

- `.github/workflows/ci.yml`: Swift-Build und -Tests (SQLite), PWA-Check, -Build und Vitest.
- `.github/workflows/docker-publish.yml`: baut das Backend-Image und veröffentlicht es nach `ghcr.io/<owner>/<repo>-backend` (Branch `main`, Tags `v*`).
- `.github/workflows/pages.yml`: veröffentlicht die statische Projektseite aus `docs-site/` auf GitHub Pages.

## Repository-Struktur

```text
Sources/App          Einstiegspunkt des Backends
Sources/TodoKit      Fachlogik: Auth, Identity, Sharing, Planning, Collaboration, Attachments, OAuth, MCP, Agents
Tests/               Backend-Tests
web/                 SvelteKit-PWA (src, tests, e2e)
contracts/           OpenAPI-Verträge je Bereich
docs/                Projektgedächtnis: Status, Arbeitsplan, Konzepte, ADRs
docs-site/           Statische Projektseite (GitHub Pages)
deploy/swarm         Swarm-Deployment
scripts/             Test-, Backup- und Deploy-Skripte
compose.yaml         Entwicklungsstack
Dockerfile           Backend-Image
.github/workflows/   CI, Docker-Publish, Pages
```

## Status

Vorhanden: Identität mit Passkeys und Recovery, Projekte/Aufgaben, Teams und Freigaben, Planung und Board, Kommentare/Verlauf/Abnahmekriterien, Anhänge, OAuth/MCP, Agentenaufträge, PWA-Oberflächen dafür. Nicht geprüft oder offen: echte Geräte und Browser außerhalb Chromium, Produktivspeicher (S3), Mehrreplikatbetrieb unter Last, Apple-Clients gegen das aktuelle Backend. Der verbindliche, aktuelle Stand steht in [docs/STATUS.md](docs/STATUS.md), die Planung in [docs/ARBEITSPLAN.md](docs/ARBEITSPLAN.md).

## Dokumentation

- [Produktkonzept](docs/PRODUKT.md)
- [Architektur](docs/ARCHITEKTUR.md)
- [Identität und Berechtigungen](docs/IDENTITAET-UND-RECHTE.md)
- [Agenten und MCP](docs/AGENTEN-UND-MCP.md)
- [Betrieb](docs/BETRIEB.md)
- [Umsetzungsplan](docs/UMSETZUNGSPLAN.md) und [Arbeitsplan](docs/ARBEITSPLAN.md)
- [Entscheidungen](docs/ENTSCHEIDUNGEN.md)
- ADRs: [0001 Stack](docs/adr/0001-stack.md), [0002 Dateispeicher](docs/adr/0002-dateispeicher.md), [0003 Referenzen](docs/adr/0003-referenzen.md), [0004 Runner-Start](docs/adr/0004-runner-claude-start.md), [0005 Projektrechte](docs/adr/0005-projektrechte.md), [0006 Anhänge](docs/adr/0006-anhaenge.md), [0007 OAuth/MCP](docs/adr/0007-oauth-mcp.md), [0008 Agentenaufträge](docs/adr/0008-agentenauftraege.md), [0010 Recovery](docs/adr/0010-recovery.md)

## Mitarbeit mit Coding-Agenten

Das Repository ist die Source of Truth; Sessions sind wegwerfbar. Einstieg: [AGENTS.md](AGENTS.md) und [CLAUDE.md](CLAUDE.md).
