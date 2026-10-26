# Status

Stand 25.10.2026 – Etappe 0 teilweise erledigt.

## Tatsächlich vorhanden (Hauptrepository, unversioniert, noch keine Commits)
- `Package.swift`, `Sources/App`, `Sources/TodoKit`, `Tests/TodoKitTests`: Vapor-Grundgerüst mit `/health/live` und `/health/ready`.
- `compose.yaml` mit MariaDB 12.3 und Adobe S3Mock 5.2.3; Profil `app` für das Backend. `.env.example` mit Platzhaltern. Ports bewusst 23306 (DB), 29090 (S3), 28080 (Backend), weil Timetrack 13306 belegt.
- `Dockerfile` (Linux, Swift 6.2, statisch gelinkt).
- ADR 0001 (Stack), 0002 (Dateispeicher), 0003 (Referenzen); Entscheidungen 12–14 in ENTSCHEIDUNGEN.md.

- `contracts/openapi.yaml` (nur Health). `web/`: SvelteKit 3 (adapter-static, SPA-Fallback), Tailwind, shadcn-svelte (Button), Manifest; Dev-Proxy `/health` nach Backend.

- Apple-Repository (`../Xcode/todo`, eigener Status dort): `TodoCore` (Swift Package, `APIClient.ready()`), `project.yml` (XcodeGen) mit Targets iOS, macOS, watchOS und Minimal-App; Platzhalter-Bundle-IDs `example.todo.*`.

## Geprüft
- Apple: Targets iOS (Simulator), macOS und watchOS (Simulator) bauen mit `CODE_SIGNING_ALLOWED=NO`; `TodoCore`-Test grün über `xcodebuild test`. `swift test` im Package scheitert am Codesigning von `.xctest` in dieser Umgebung (nicht weiter untersucht). Laufzeit gegen das Backend auf Gerät/Simulator nicht geprüft.
- Runner-Machbarkeit: siehe ADR 0004 (Start, Dateizugriff, Fortsetzung belegt).
- PWA: `npm run check` und `npm run build` grün; Vite-Dev-Server erreicht über Proxy das Backend im Linux-Container (`/health/ready` 200). Browser-/E2E-Test steht aus.
- `swift build` und `swift test` (1 Test, SQLite) grün.
- Backend gegen laufende MariaDB gestartet: `/health/live` und `/health/ready` antworten 200.
- S3Mock: PUT und GET eines Objekts im Bucket funktionieren.
- `docker compose build backend` baut das Linux-Image. Der Container wurde noch nicht gestartet.

## Noch nicht geprüft oder offen
- Kein Apple-Projekt, kein Runner-Machbarkeitstest, keine Migrationen, kein Passkey.
- Kein Mehrreplikatest. Keine Geräteprüfung.
- Prod-Speicher (echtes S3) nicht gewählt.

## Nächster Schritt
Siehe ARBEITSPLAN.md: PWA-Grundgerüst, `contracts/openapi.yaml`, Apple-Grundgerüst, Runner-Machbarkeit; danach Etappe 1.

## Hinweise zur PWA-Werkzeugkette
- `shadcn-svelte init` ist ohne TTY nicht nutzbar (fragt Preset) und `svelte-kit` 3 erzeugt kein `tsconfig` für die CLI (`$app/tsconfig`). Workaround: `components.json` von Hand, `add` mit temporär vereinfachter `tsconfig.json`; `src/lib/utils.ts` (cn) von Hand. Neue Komponenten ebenso hinzufügen und Importe auf `.../index.js` setzen.
- pnpm nicht installiert; es wird npm verwendet.

## Checkpoint Etappe 1 (Backend, 25.10.2026)
Implementiert in `Sources/TodoKit`: Modelle/Migration (`users`, `passkey_credentials`, `auth_challenges`, `sessions`, `invitations`, `projects`, `tasks`), Passkey-Registrierung (Bootstrap-Token bzw. Einladung) und Login (WebAuthn, Challenges in der DB), Sessions (Bearer oder Cookie, nur Hash gespeichert, CSRF: JSON-Pflicht und Origin-Prüfung bei Cookie), Capability-Endpunkt, serverseitiger Passwort-Schalter (`PASSWORD_LOGIN_ENABLED`, Standard aus; Bcrypt), Einladungen, Projekte/Unterprojekte (Zyklenschutz) und Aufgaben (Versionskonflikt 409), zentrale Zugriffsprüfung `ProjectAccess` (Fremdes = 404). Migrationen laufen nur über `App migrate --yes` bzw. Compose-Dienst `migrate`.
Tests: 12 Tests grün auf SQLite; mit `scripts/test-mariadb.sh` (TODO_TEST_MARIADB=1) laufen alle 12 inklusive Challenge über zweites Replikat, 8 parallele Updates mit gleicher Version (genau ein Gewinner) und Bootstrap-Race (genau ein Admin) gegen echte MariaDB 12.3. Die Passkey-Tests nutzen einen virtuellen ES256-Authenticator (`Tests/TodoKitTests/VirtualAuthenticator.swift`), nicht echte Browser/Geräte.
`swift test` scheitert im Ordner unter ~/Documents am Codesigning (FinderInfo/fileprovider-xattrs); Workaround: `--scratch-path <Ordner außerhalb von Documents>`.
Offen: Rate-Limits, Passkey-Verwaltung (weitere Passkeys, Widerruf), Recovery, Session-Liste, Idempotenzschlüssel für Anlage, OpenAPI für Auth/Projekte/Aufgaben, PWA-Login/-Listen, Apple-Client-Funktionen, echte Browser-/Geräteprüfung.

## Betrieb

Checkpoint 26.10.2026, Ziel: Betriebsgrundlage mit Swarm, Dateisecrets und überprüfbarem MariaDB-Backup/Restore. Nutzerumfang beschränkt Änderungen auf deploy/, scripts/, BETRIEB, Settings/Configure, Settings-Tests und diesen Abschnitt; ARBEITSPLAN bleibt deshalb unverändert. Der zugehörige Arbeitsplan und nächste Schritt stehen hier.

Implementiert: `deploy/swarm/stack.yaml` (drei Backends, getrennte Migration mit Restart aus, MariaDB auf markiertem Daten-Node, flüchtiges S3Mock, externe Secrets, Healthchecks und Rolling-Update/Rollback), Deploy-Skript mit Swarm-Config als Deploy-Sperre und erfolgreicher Migration als Start-/Rollout-Voraussetzung. `_FILE`-Lesen für bisherige Backend-Einstellungen, Datei hat Vorrang, unlesbare Datei wirft Fehler; Tests für Defaults/Altwerte, Priorität, Zeilenenden, leeres Bootstrap-Secret und Fehlerfälle. Backup/Restore-Skripte mit mariadb-dump, Prüfsummen und exakten Tabellenzeilenzahlen; isolierte Wiederherstellungsprobe und Einzelknoten-Swarm-Smoke mit Cleanup. Betriebsanleitung und Grenzen in BETRIEB.md. Kein neues DB-Schema und keine API-Vertragsänderung; Swift-Konfigurationsfunktionen werfen nun Fehler. Keine Apple-Änderung.

Prüfstand: YAML mit `docker stack config` erfolgreich gerendert; Shell-Syntax und ShellCheck erfolgreich. Build, Swarm-Smoke und Restore-Smoke tatsächlich aufgerufen, aber Docker-Buildx-Dateizugriff bzw. Colima-Socket durch die Sandbox verweigert. Deshalb keine Containerstarts, Migration, HTTP-Proben oder echten Restores belegt und keine Docker-Ressourcen angelegt oder fremde Ressourcen verändert. Der geforderte Swift-Testaufruf scheiterte am gesperrten Cache; Cache-Umleitung scheiterte an SwiftPM-Sandbox, danach mit `--disable-sandbox` an GitHub-DNS. Offline-Wiederholung mit Kopien vorhandener Abhängigkeiten läuft als nächster Prüfversuch.

Branch: `worktree-agent-a8e215013c33b3c21`, Ausgangscommit `76c7371`; Änderungen ausschließlich im Hauptrepository/Worktree. Arbeitsplan: (1) Implementierung und statische Prüfung abgeschlossen; (2) Swift-Prüfung abschließen; (3) Checkpoint finalisieren und Commit versuchen; (4) bei verfügbarem Docker-Zugriff beide Smoke-Skripte wiederholen. Offene Abnahme: Linux-/MariaDB-Laufzeit, Migrationskoordination, drei Replikate und Cleanup, echter Restore; außerdem produktives S3/TLS/HA und die weitergehenden Fachprüfungen aus ARCHITEKTUR. Keine Deployments/Pushes beabsichtigt. Laufende Prozesse: nur der lokale Swift-Prüfversuch, keine gestarteten Docker-Jobs.
