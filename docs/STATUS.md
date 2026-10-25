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

## Agentenaufträge

Checkpoint 25.10.2026, Hauptrepository, Branch `worktree-agent-a9862124df8dc00d0`, Commit-Titel `Implement agent jobs and fenced runner API` (Commit über Git-Historie dieses Abschnitts auffindbar). Ziel: serverseitige Agentenaufträge und Runner-API gemäß AGENTEN-UND-MCP, Architektur und ADR 0004. Zustandsvertrag und Arbeitsplan dieses Strangs: `docs/adr/0008-agentenauftraege.md`.

Implementiert unter `Sources/TodoKit/Agents`: RunnerDevice und Einmalkopplung (Code zehn Minuten gültig, Code/Token nur als Hash), ProjectRunnerBinding mit lokaler Repository-UUID und Label ohne Pfad, AgentJob getrennt vom Aufgabenstatus, AgentRun mit 90-Sekunden-Lease und Generation, Checkpoint ohne Chats, strukturierte Fragen/unveränderliche Antworten, überschreibbarer Fortschritt und dauerhafte Ereignisse. Gemeinsamer `AgentService`; Agentenstart ausdrücklich als eigene Fähigkeit in einer Erweiterung von `ProjectAccess`, bis zur Teamrechte-Integration ausschließlich Eigentümer.

REST-Vertrag `contracts/agents.yaml`: menschliche Freigabe zur Klärung/Umsetzung mit Aufgabenrevision und Auftrags-UUID als Idempotenzschlüssel; gerätegebundene Übernahme, Heartbeat, Fortschritt, Checkpoint, Frage/Antwort, gezielte Fortsetzung, Ergebnis zur Abnahme, menschliches Review, Stop, Gerätewiderruf und Abgleich nach Neustart. Optionale `previousJobID` erhält den Zusammenhang explizit freigegebener Folgeaufträge. Aufgabenstatus und -version werden dabei nicht verändert. Veraltete Generation ergibt 409, verlorene Lease/abgeschlossener Lauf 410. Claims sperren die Gerätezeile und prüfen über alle Bindings derselben Repository-UUID auf nicht abgeschlossene Läufe. Lease-Ablauf allein gibt keinen Platz frei; keine automatische Wiederholung. Menschlicher Stop ficht die Schreibhoheit sofort an, gibt den Platz aber erst nach bestätigtem lokalen Stillstand frei. Bestätigte Fragenpause mit Checkpoint kann nach Neustart gezielt übernommen werden.

Migration/Integration: additive `CreateAgentSchema` (neun Tabellen, Fremdschlüssel, Eindeutigkeitsregeln und Abfrageindizes), separat vor Serve auszuführen. `Configure.swift` und `Routes.swift` enthalten jeweils genau eine zusätzliche Registrierungszeile. Restriktive Fremdschlüssel verhindern das Weglöschen aktiver Laufreservierungen und dauerhafter Ereignisse durch Aufgaben-/Projektlöschung. Die bestehenden Löschrouten bilden solche Konflikte noch nicht auf einen speziellen fachlichen Fehler ab. Andere Produkt-Repositories und Referenzprojekte wurden nicht geändert.

Prüfungen:
- Backend und Tests bauen auf macOS. Zehn neue Agententests auf isolierter SQLite-Datenbank bestehen: vollständiger Fragen-/Review-Ablauf, Konto-/Gerätegrenzen, Hashes/Einmalcode/Ablauf/Widerruf, Repository-Aliase, Revisionskonflikte, idempotente Freigabe/Antwort, Lease-Verlust, alle veralteten Schreibaktionen, Stop, Wiederanlauf mit Checkpoint und Fragenpause sowie expliziter Folgeauftrag.
- Vollständiger aktueller Lauf: 24 Tests, fünf MariaDB-Tests übersprungen, sechs Fehler in bestehenden Auth-/Planning-Tests. Separat geprüfter unveränderter Ausgangscommit `76c7371`: zwölf Tests, drei übersprungen, dieselben sechs Fehler. Die gemeinsame SQLite-Datei in `Tests/TodoKitTests/TestSupport.swift` überlebt zwischen Tests; nach dem ersten Bootstrap erhalten weitere Registrierungen `invalid_token`. Keine Änderung dieser fremden Testhilfe; die frühere pauschale SQLite-Erfolgsaussage ist damit für den jetzigen Gesamtlauf ausdrücklich eingeschränkt.
- Gezielter separater Lauf `--skip-build --filter TodoKitTests.AgentTests`: zehn Tests, null Fehler, Exit 0.
- `scripts/test-mariadb.sh --scratch-path /private/tmp/todo-agent-build` aufgerufen: Docker-Socket `/Users/linolaske/.colima/default/docker.sock` nicht zugänglich, Abbruch vor Teststart. Zwei neue MariaDB-Tests sind angelegt (acht parallele Claims über zwei Replikat-Apps; konkurrierende verschiedene Aufträge auf Alias-Bindings), aber nicht ausgeführt. Keine Aussage über erfolgreiche MariaDB-/Linux-Abnahme.
- YAML-Vertrag geparst, 23 Operationen, 153 Referenzen aufgelöst, eindeutige Operations-IDs; vollständiger OpenAPI-Validator nicht verfügbar. `git diff --check` ohne Befund.

Reproduzierbarer lokaler Testaufruf in dieser Sandbox (vorhandene Paket-Checkouts wurden lesend aus dem Hauptcheckout in das Scratch-Verzeichnis kopiert; keine Referenzprojekte verändert):

```sh
env TMPDIR=/private/tmp/todo-agent-temp \
  CLANG_MODULE_CACHE_PATH=/private/tmp/todo-agent-clang \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/todo-agent-modules \
  swift test --build-system native --disable-sandbox --skip-update \
  --cache-path /private/tmp/todo-agent-cache \
  --scratch-path /private/tmp/todo-agent-build --jobs 6
```

Der Standard-Build scheiterte zuerst am geschützten Compiler-Cache und an temporären Clang-Dateien; die obigen Cache-/TMPDIR-Einstellungen und der native Build umgehen diese Umgebungsprobleme. Testprotokolle liegen ausschließlich unter `/private/tmp/todo-agent-*.log`, keine Laufzeitdaten im Repository.

Offen/nächster konkreter Schritt: mit zugänglichem Docker zuerst das MariaDB-Skript und den Linux-Build ausführen, anschließend echter Mac-Prozess-/Netzverlusttest gemäß ADR 0004. Weiterhin offen: Teamrechte-Integration der Startfähigkeit, administrative Freigabe eines widerrufenen Geräts nach geprüftem lokalen Stillstand (bis dahin bleibt sein Repository blockiert), fachliche Übersetzung von Löschkonflikten, Pagination/Aufbewahrung und unabhängige Prüfnachweise für Ergebnisse. Keine gestarteten Server, laufenden Testjobs, Pushes oder Deployments bei Übergabe. Ein erster abschließender Git-Schreibversuch scheiterte vorübergehend an der Sandbox beim Anlegen von `.git/worktrees/agent-a9862124df8dc00d0/index.lock`; der separate erneute Staging-Aufruf war erfolgreich. Der Versionsstand wird mit dem genannten Commit-Titel gesichert. Fremde Statusabschnitte bleiben unverändert.
