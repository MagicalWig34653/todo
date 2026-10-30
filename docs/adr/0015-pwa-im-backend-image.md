# ADR 0015 – PWA im Backend-Image (same-origin)

Status: umgesetzt (30.10.2026).

## Anlass

Das GHCR-Image enthielt nur die Swift-API; unter `https://todo.linolaske.de/` kam deshalb `{"error":true,"reason":"Not Found"}`. Die SvelteKit-PWA (`web/`, adapter-static) wurde nirgends ausgeliefert. Passkeys binden an `RP_ID`/`RP_ORIGIN`; die PWA muss daher unter derselben Origin wie die API laufen.

## Entscheidung

- **Ein Image, eine Origin.** Das Dockerfile hat eine Node-Stage (`node:22.21.1-bookworm-slim`, `npm ci`, `npm run build` in `web/`); `web/build` wird nach `/srv/web` ins Runtime-Image kopiert, `WEB_ROOT=/srv/web`.
- **Auslieferung im Backend** (`Sources/TodoKit/Web/WebRootMiddleware.swift`), kein separater Webserver. Einstellung `WEB_ROOT` (Standard `/srv/web`); fehlt das Verzeichnis oder `index.html`, verhält sich das Backend unverändert als reine API.
- **Echte Routen haben Vorrang.** Die Middleware ruft zuerst den Router; nur ein „nicht gefunden“ fällt auf Dateien zurück. Reservierte Präfixe (`v1`, `mcp`, `oauth`, `.well-known`, `health`, `apple-app-site-association`, `docs`, `openapi`) werden nie von der Platte bedient und bekommen nie den SPA-Fallback: unbekannte API-Pfade bleiben JSON-404, AASA/`.well-known` können nicht überschattet werden (auch nicht bei leerem `AASA_APP_IDS`).
- **SPA-Fallback** (`index.html`) nur für `GET`/`HEAD` mit `Accept: text/html`, nicht unter `/_app/`. Tiefe Links (`/inbox`) funktionieren damit nach Reload.
- **Cache-Header:** `/_app/immutable/**` `public, max-age=31536000, immutable`; alles andere (index.html, service-worker.js, manifest, robots) `no-cache`. `X-Content-Type-Options: nosniff`; Content-Types für html/js/css/json/webmanifest/svg/png/woff2 explizit.
- **Pfadsicherheit:** Segmente werden prozent-dekodiert; `..`, `/`, `\`, NUL → 400; Dateien mit führendem Punkt → 404; aufgelöster Symlink-Pfad muss im Web-Root liegen.
- **API-Basis der PWA:** relativ (`/v1`, `/oauth/…`), also ohne Konfiguration same-origin. Der Service Worker lässt `/v1`, `/health`, `/oauth`, `/mcp`, `/.well-known` und AASA unangetastet.

## Folgen

Ein Rollout liefert UI und API gemeinsam (Rolling Update ohne Versionsabweichung). Der Docker-Build dauert durch die Node-Stage länger (Cache über `type=gha`). Ein CDN/Reverse-Proxy vor dem Backend darf `/_app/immutable/` lang cachen, alles andere nicht.
