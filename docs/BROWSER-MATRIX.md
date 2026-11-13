# Browser-Matrix der E2E-Specs

Stand 13.11.2026, Branch `agent/playwright-165` (Basis `main@f34e0dc`, Backend-Binary aus `main` Stand 45a8891). Echtes Backend (`.build/debug/App`, SQLite), PWA über Vite, `@playwright/test` jetzt fest auf 1.65.0 in `web/package.json` und Lockdatei (Chromium 158, Firefox `firefox-1572`, WebKit `webkit-2388`), headless, macOS arm64. Vollständiger Neulauf aller 4 Projekte mit der Lockdatei-Version, 167 Tests je Projekt.

## Ergebnis (grün / rot / übersprungen)

| Projekt | grün | rot | übersprungen | Bemerkung |
| --- | --- | --- | --- | --- |
| chromium | 156 | 0 | 11 | übersprungen: `mail` (3), `server-settings` (8), brauchen `MAIL_SINK_FILE` und eine SMTP-Senke |
| firefox | 48 | 0 | 119 | alle Specs mit `signedInPage` laufen; der Rest braucht Chromium (CDP-Passkey); Firefox startet jetzt |
| webkit | 48 | 0 | 119 | wie Firefox |
| mobile-safari (iPhone 14, WebKit) | 48 | 0 | 119 | wie Firefox, mit Touch/schmalem Viewport |

Nicht gelaufen: `mobile-chrome`.

## Je Spec

| Spec | chromium | firefox | webkit | mobile-safari |
| --- | --- | --- | --- | --- |
| account-lock | 6 grün | 6 übersprungen | 6 übersprungen | 6 übersprungen |
| action-requests | 2 grün | 2 übersprungen | 2 übersprungen | 2 übersprungen |
| attachment-upload | 9 grün | 9 grün | 9 grün | 9 grün |
| board-single-fetch | 1 grün | 1 übersprungen | 1 übersprungen | 1 übersprungen |
| card-detail | 15 grün | 15 übersprungen | 15 übersprungen | 15 übersprungen |
| card-tabs | 11 grün | 11 grün | 11 grün | 11 grün |
| connections | 5 grün | 5 übersprungen | 5 übersprungen | 5 übersprungen |
| for-you | 3 grün | 3 grün | 3 grün | 3 grün |
| freetext-review | 5 grün | 5 grün | 5 grün | 5 grün |
| icons | 3 grün | 3 grün | 3 grün | 3 grün |
| invite-link | 1 grün | 1 übersprungen | 1 übersprungen | 1 übersprungen |
| live-refresh | 1 grün | 1 übersprungen | 1 übersprungen | 1 übersprungen |
| mail | 3 übersprungen | 3 übersprungen | 3 übersprungen | 3 übersprungen |
| menus-and-modes | 11 grün | 11 übersprungen | 11 übersprungen | 11 übersprungen |
| oauth-consent | 8 grün | 8 grün | 8 grün | 8 grün |
| passkey-flow | 21 grün | 21 übersprungen | 21 übersprungen | 21 übersprungen |
| permissions | 8 grün | 8 übersprungen | 8 übersprungen | 8 übersprungen |
| project-repository | 4 grün | 4 übersprungen | 4 übersprungen | 4 übersprungen |
| question-overflow | 7 grün | 7 übersprungen | 7 übersprungen | 7 übersprungen |
| repo-line-stability | 2 grün | 2 grün | 2 grün | 2 grün |
| review-undo | 2 grün | 2 übersprungen | 2 übersprungen | 2 übersprungen |
| server-settings | 8 übersprungen | 8 übersprungen | 8 übersprungen | 8 übersprungen |
| settings-hub | 11 grün | 11 übersprungen | 11 übersprungen | 11 übersprungen |
| sidebar-rename | 3 grün | 3 übersprungen | 3 übersprungen | 3 übersprungen |
| system-status | 1 grün | 1 grün | 1 grün | 1 grün |
| task-graph | 6 grün | 6 grün | 6 grün | 6 grün |
| ui-lists | 4 grün | 4 übersprungen | 4 übersprungen | 4 übersprungen |
| ui-nav | 6 grün | 6 übersprungen | 6 übersprungen | 6 übersprungen |

Der Passkey-Ablauf selbst (virtueller Authenticator) wird nur in Chromium geprüft; in Firefox/WebKit wird die Sitzung aus einem Hilfs-Chromium übernommen (`e2e/support/session.ts`). 119 von 167 Tests laufen dort bewusst nicht: die Specs sind weiterhin Chromium-only.

## Firefox (gelöst)

Playwright 1.64.1 lieferte Firefox `firefox-1555` (157.0, Nightly-Bundle). Auf diesem Mac endete jeder Start, auch direkt aus dem Terminal ohne Playwright und mit frischem Profil, mit `Could not find profile folder.` (Exit 1). Rechte, Quarantäne, Architektur und ein installierter Firefox 159 waren es nicht; die Ursache liegt im Build `1555` selbst. Mit `@playwright/test` 1.65.0 (`firefox-1572`) startet Firefox; alle 48 laufenden Tests sind grün, die Zahlen entsprechen WebKit und mobile-safari. Die Anhebung ist umgesetzt (Version exakt gepinnt, keine weiteren Änderungen an der Lockdatei als `@playwright/test`, `playwright`, `playwright-core`). Die CI-Pipeline (`.github/workflows/ci.yml`) führt kein Playwright aus und kodiert keine Version.

Browser für lokale Läufe: `PLAYWRIGHT_BROWSERS_PATH=<Ordner> npx playwright install chromium firefox webkit` (Firefox-Revision hängt an der Playwright-Version).

## Befunde und Einordnung

- Erste Chromium-Läufe waren rot (5), alle Test-/Umgebungsursachen, kein Produktfehler:
  - Specs sind je Datei zustandsbehaftet (Bootstrap-Code ist einmalig): jede Spec-Datei braucht eine frische Datenbank.
  - Port: die Specs erwarten `http://localhost:25173` (`ORIGIN`), dazu `OAUTH_ISSUER` gleich `RP_ORIGIN` (bei Loopback-`RP_ORIGIN` leitet das Backend sonst einen anderen Issuer ab).
  - Der Vite-Dev-Proxy kannte `/mcp` und `/.well-known/` nicht (`action-requests`, `card-detail`, `connections`, `settings-hub` riefen MCP bzw. die Resource-Metadaten über die Vite-Origin auf). Behoben in `web/vite.config.ts` (nur Dev-Server).
  - `project-repository` lief einmal in ein Zeitlimit (30 s) beim Lauf auf falschem Port, danach 4/4 grün; nicht reproduziert.
- WebKit/Firefox: `invite-link.spec.ts` hatte als einzige Spec keine Chromium-Prüfung (`newCDPSession` wirft); Test-Fehler, Skip-Guard ergänzt.
- Keine Produktfehler gefunden; keine Layout-/Verhaltensabweichung in Firefox/WebKit bei den 35 laufenden Tests.

## Reproduktion

Je Projekt und je Spec-Datei: frische SQLite (`DB_NAME` absolut, `DATABASE_DRIVER=sqlite`, `App migrate --yes`), Backend `App serve --hostname 127.0.0.1 --port 28090` mit `RP_ORIGIN=OAUTH_ISSUER=http://localhost:25173`, `RP_ID=localhost`, `BOOTSTRAP_TOKEN=dev-bootstrap-only`; dann `BACKEND_URL=http://127.0.0.1:28090 npx playwright test e2e/<spec>.spec.ts --project=<projekt>`. Ein Projekt nach dem anderen.
