# ADR 0017 – Produktname Todolino

Status: umgesetzt (30.10.2026, Hauptrepository; Apple-Repository folgt separat).

## Entscheidung

Der sichtbare Produktname lautet **Todolino** (statt „Todo“), in Anlehnung an Todoist, aber als eigene Version.

## Umfang

- Geändert (nur Anzeigetexte): PWA (Titel, Manifest, i18n, Favicon-Titel), WebAuthn-Relying-Party-Name (`RP_NAME`, Standard in `Settings.swift`, `compose.yaml`), OAuth-Zustimmungsseite, MCP-`serverInfo.name`, Agentenhandbuch (neu eingebettet), Vertragstitel, README, docs-site, Deploy-/Design-READMEs, Vorlagen.
- Bewusst unverändert: Repository-/Ordnernamen, Bundle-IDs, Swift-Module (`TodoKit` …), Image `ghcr.io/magicalwig34653/todo-backend`, Stack-/Secret-/Volume-/Env-Namen (`todo_*`, `TODO_*`), DB-Namen, `localStorage`-Schlüssel (`todo.*`), Domain `todo.linolaske.de`, API-Pfade, MCP-Ressource `todo://manual`, Kanban-Spalte „Todo“.
- `RP_ID` bleibt unverändert; der Relying-Party-Name ist nur Anzeige, bestehende Passkeys bleiben gültig.
