# Projekt-Onboarding und Claude-Code-Plugin

Ziel: Todolino einmal global in Claude Code hinzufügen, danach in einem Projekt sagen „Richte das Projekt in Todolino ein“ und das Board aktuell halten. Die ausführliche Anleitung mit allen Schritten, Grenzen und dem Verhalten bei Account-Wechsel steht unter [Claude Code einrichten](claude-code-einrichtung.html). Entscheidungen: [ADR 0018](adr/0018-projekt-onboarding-und-aktualitaet.md).

## Kurzfassung: Plugin (empfohlen)

```text
/plugin marketplace add MagicalWig34653/todo
/plugin install todolino@todolino
```

Beim Aktivieren fragt Claude Code nach der Server-Adresse (Standard `https://todo.linolaske.de/mcp`; für eine eigene Instanz deren MCP-URL eintragen). Danach in Claude Code `/mcp`, den Server `todolino` wählen und im Browser anmelden (OAuth, Passkey). Für das Anlegen neuer Projekte braucht die Verbindung den Scope `projects:write`.

Im Projektverzeichnis genügt: „Richte das Projekt in Todolino ein“. Das Skill `todolino:setup` liest README, AGENTS.md/CLAUDE.md, docs/, Plandateien und Git-Log, legt das Projekt an (oder findet es über die Git-Remote), importiert Features, Aufgaben, Unteraufgaben und Kriterien idempotent und schreibt `.todolino.json` sowie einen kurzen Abschnitt in CLAUDE.md.

## Ohne Plugin: globaler MCP-Server

```sh
claude mcp add --transport http --scope user todolino https://todo.linolaske.de/mcp
```

Dann in Claude Code `/mcp` und anmelden. Die Prompts des Servers erscheinen als Slash-Befehle (`/mcp__todolino__setup_project`, `sync_project`, `session_start`). Ohne Plugin gibt es keine Hooks; die Pflicht beruht dann auf einem Textbaustein in der globalen CLAUDE.md (Vorlage in der Anleitung).

## Was das Backend dafür bereitstellt

- **MCP-Prompts** `setup_project`, `sync_project`, `session_start` (nur Anweisungen; der Datenzugriff läuft über Werkzeuge mit Scope- und Rechteprüfung).
- **Repository-Bindung:** normalisierte Repo-Kennung (`host/owner/repo`, ohne Zugangsdaten) je Projekt; `find_project_by_repository`, `bind_repository`, REST `GET /v1/projects/by-repository`.
- **Idempotente Massenanlage** `import_plan` (höchstens 300 Einträge, eine Ebene Unteraufgaben, `dryRun`). Er legt an, aktualisiert Titel und Beschreibung, ergänzt Kriterien und setzt offene auf erledigt; er löscht, öffnet und enthakt nie, denn das Board ist für den Fortschritt maßgeblich.
- **Aktualität:** `record_sync` speichert Zeitpunkt, Repository-Stand und Zusammenfassung; die Steuerzentrale zeigt je Projekt `fresh`, `stale` oder `never` (Schwelle je Projekt, Standard 3 Tage), dazu `get_stale_projects` und der Zähler `summary.staleProjects`.

## Hooks und ihre Grenzen

Das Plugin bringt drei Hooks mit: SessionStart (Kontext „an Todolino gebunden“), PostToolUse nach `git commit` (Erinnerung) und Stop (hält die Sitzung höchstens einmal auf, wenn Dateien geändert wurden, aber nie `record_sync` aufgerufen wurde). Die Hooks nutzen kein Netzwerk, arbeiten fail-open und lassen sich mit `TODOLINO_HOOKS_OFF=1` abschalten.

Ehrlich: Erzwingen lässt sich nur, dass `record_sync` aufgerufen wurde, nicht, dass der Inhalt stimmt. Bei beendeten Sitzungen, ohne Plugin oder in Repositories ohne `.todolino.json` bleibt es bei der Erinnerung. Der Server macht Veraltetes sichtbar, kann aber niemanden zum Abgleich zwingen.

## Stand und noch nicht geprüft

Geprüft: `claude plugin validate`, Installation in einem temporären Config-Verzeichnis (3 Skills, 3 Hooks, MCP-Server meldet „Needs authentication“), 22 Hook-Prüfungen, Ende-zu-Ende-Skript im SQLite-Modus (OAuth mit PKCE, MCP-Aufrufe, doppelter Import, fresh/stale) 22/22.

Offen: Test in einer echten Claude-Code-Sitzung (Hooks im laufenden Lauf, interaktiver OAuth-Flow der CLI), das Verhalten bei Account-Wechsel (in der Anleitung als Annahme markiert) und der Ende-zu-Ende-Lauf gegen einen Compose-Stack mit MariaDB. Siehe [Status](status.html).
