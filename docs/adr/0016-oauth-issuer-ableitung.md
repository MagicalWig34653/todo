# ADR 0016 – OAuth-/MCP-Issuer aus der Konfiguration ableiten

Status: umgesetzt (30.10.2026).

## Anlass

In Produktion lieferte die Discovery überall `http://localhost:28080` (issuer, Endpunkte, `resource`, `WWW-Authenticate`), weil der Issuer nur aus `OAUTH_ISSUER` gelesen wurde und kein Deploy-Artefakt diese Variable setzte. Kein MCP-Client konnte sich verbinden.

## Entscheidung

- `AppSettings.oauthIssuer` (neu, in `Settings.swift`) ersetzt die statische `OAuthController.issuer`. Reihenfolge: `OAUTH_ISSUER` (nicht leer, Slash am Ende entfernt) vor `RP_ORIGIN`, sofern dessen Host nicht loopback ist, vor dem Dev-Standard `http://localhost:28080`. `oauthResource` = Issuer + `/mcp` ist der RFC-8707-Resource-Indikator und die Audience, an die Grants gebunden werden.
- Abwärtskompatibel: bestehende Produktions-Env-Dateien mit nur `RP_ORIGIN=https://…` funktionieren ohne Änderung; der Dev-Stack (RP_ORIGIN `http://localhost:25173`) behält `http://localhost:28080`.
- Kein Startabbruch bei Loopback-Issuer in `--env production` (lokale Produktionsläufe wie die Stack-Vorgabe `localhost:38080` bleiben möglich), aber eine Warnung im Log beim Start.
- Nie aus Host- oder Forwarded-Headern ableiten.
- Deploy: `stack.yaml` reicht `OAUTH_ISSUER` (Standard leer) durch, `setup.sh` schreibt `OAUTH_ISSUER` (vorhandener Wert bleibt, sonst = `RP_ORIGIN`), `stack.env.example` dokumentiert sie. Bereits vergebene Grants tragen die alte Resource `http://localhost:28080/mcp`; sie waren nie nutzbar und sind nach dem Update ungültig (Clients registrieren und autorisieren neu).
