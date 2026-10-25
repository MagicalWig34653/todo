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

## Vertrag Etappe 1

Ziel und Umfang (25.10.2026): tatsächlichen Health-/Auth-/Planning-Stand als OpenAPI 3.1 unter `contracts/openapi.yaml` erfassen; andere Bereiche bleiben in ihren eigenen Verträgen. Nutzerauftrag beschränkt Änderungen auf Vertrag, Vertragstest und diesen Abschnitt; `ARBEITSPLAN.md` bleibt deshalb unverändert. Arbeitsplan dieses Auftrags: Code/Encodable-Formen prüfen → Vertrag und Router-Abgleich erstellen → Swift-Tests/Lint → Commit auf aktuellem Worktree-Branch, kein Push.

Implementiert: 20 Operationen auf 16 Pfaden mit DTOs, WebAuthn-Binärfeldern als Base64url, Session-Cookie/Bearer, tatsächlichen CSRF-Ausnahmen, Versionskonflikten und Fremdressourcen-404. WebAuthn-Formen aus dem vorhandenen Hauptcheckout `.build/checkouts/webauthn-swift/Sources/WebAuthn/Ceremonies` geprüft (im Worktree zunächst kein `.build`). Insbesondere verlangt der Registration-Decoder `type`, obwohl dessen Encoder dieses Feld auslässt. `ContractTests.swift` liest den YAML-Routenindex mit einem bewusst begrenzten Parser ohne zusätzliche Paketabhängigkeit; Vorwärtsabgleich aller dokumentierten Operationen und Rückwärtsabgleich für dokumentierte Pfade sowie tatsächlich von Auth/Planning registrierte Operationen. Andere Controller dürfen eigene Verträge führen.

Vertrag/Lint abgeschlossen: `npx --offline --cache /private/tmp/todo-contract-npm --prefix /Users/linolaske/.npm/_npx/4e458c17b22073d0 redocly lint contracts/openapi.yaml` nutzt lokal vorhandenes @redocly/cli 1.34.5; gültig, 0 Fehler, 7 Warnungen (Lizenz ohne URL/Identifier, lokaler Entwicklungsserver, fünf Operationen ohne fachliche 4xx-Antwort). Keine erfundenen Fehlerantworten oder Lizenzentscheidung zur Warnungsunterdrückung. Swift-Prüfung läuft noch: Standard-Clang-Cache nicht schreibbar; lokale Abhängigkeiten aus dem Hauptcheckout nach `/private/tmp/todo-contract-build` kopiert, weil GitHub-DNS in der Sandbox nicht erreichbar ist. Swiftbuild scheitert beim Anlegen temporärer Assemblerdateien; Wiederholung mit nativem SwiftPM-Buildsystem und schreibbaren Cache-/Konfigurations-/Temp-Pfaden. Keine Backend-Laufzeit- oder Migrationsänderungen; keine neuen Backend-/Apple-Funktionen. Die historischen Angaben „nur Health“ und „OpenAPI für Auth/Projekte/Aufgaben offen“ oben sind durch diesen Vertragsstand überholt.

Abschlussprüfung: `swift test --scratch-path /private/tmp/todo-contract-build --build-system native --disable-sandbox --disable-automatic-resolution --cache-path /private/tmp/todo-contract-cache --config-path /private/tmp/todo-contract-config --security-path /private/tmp/todo-contract-security --disable-keychain --disable-netrc` mit `TMPDIR=/private/tmp/todo-contract-tmp` und `CLANG_MODULE_CACHE_PATH=/private/tmp/todo-contract-clang` baut erfolgreich. Gesamtlauf: 14 Tests, 3 MariaDB-Tests übersprungen, 6 Fehler in bestehenden Auth-/Planning-Tests. Beide neuen Vertragstests bestehen, auch separat mit denselben Optionen plus `--skip-build --filter ContractTests` (2 Tests, 0 Fehler). Gegenprobe ohne Vertragstests (`--skip-build --skip ContractTests`): 12 Tests, dieselben 6 Fehler und 3 übersprungene MariaDB-Tests. Ursache im bestehenden `Tests/TodoKitTests/TestSupport.swift`: eine statische SQLite-Datei für alle `TestApp.make()`-Aufrufe ohne Zurücksetzen; nach dem ersten Konto liefern weitere Bootstrap-Registrierungen `403 invalid_token`. Auch der Passworttest erwartet zwei unabhängig frisch angelegte Apps. Die Reparatur dieser Hilfsdatei ist ausdrücklich außerhalb des freigegebenen Dateiumfangs und wurde nicht in den Vertragstest eingebaut. Gesamtsuite daher ausdrücklich nicht grün. Linux/MariaDB und echte Browser/Apple-Geräte in diesem Auftrag nicht geprüft. `git diff --check` ohne Befund.

Übergabe: nur Repository `todo`, Branch `worktree-agent-a0fcbe620a6c3f9da`, Ausgangscommit `76c7371`; Abschlusscommit „Document implemented API and verify router contract“ umfasst ausschließlich `contracts/openapi.yaml`, `Tests/TodoKitTests/ContractTests.swift` und diesen Abschnitt. Keine neue Paketabhängigkeit, keine Migration und keine Laufzeitänderung; andere Bereichsverträge unberührt. Alle gestarteten Prüfprozesse beendet, keine Server oder Hintergrundjobs gestartet. Kein Push. Nächster konkreter Schritt: in einem gesondert freigegebenen Test-Harness-Schritt SQLite pro App isolieren und Replikate explizit an dieselbe Testdatenbank binden; danach vollständige Suite erneut ausführen. Die sieben dokumentierten Lint-Warnungen bleiben offen.
