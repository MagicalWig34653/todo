# ADR 0018 – Projekt-Onboarding und Aktualität der Daten

Status: Etappe 1 (Backend/MCP) umgesetzt 31.10.2026; Plugin und Hooks siehe ADR-Abschnitt "Durchsetzung" und docs/CLAUDE-CODE-EINRICHTUNG.md.

## Ziel

Nutzer fügt den MCP-Server einmal global in Claude Code hinzu, sagt in einem Projekt "Richte das Projekt in Todolino ein", und der Agent überträgt Aufgaben ins Board. Außerdem soll "Todolino aktuell halten" zur Bedingung werden.

## Entscheidungen

- **MCP-Prompts** `setup_project`, `sync_project`, `session_start` (`prompts/list`, `prompts/get`; in Claude Code `/mcp__todolino__<name>`, Servername `todolino` ist der vom Nutzer gewählte Name). Sie enthalten nur Anweisungen; Datenzugriff läuft weiter über die Tools mit Scope- und Rechteprüfung.
- **Repository-Bindung** `project_bindings` (additive Migration, eine Zeile je Projekt): normalisierte Repo-Kennung (`host/owner/repo`, Kleinbuchstaben, ohne Zugangsdaten; oder freier Schlüssel), eindeutig je Projektbesitzer, `last_synced_at/by`, `last_repo_ref`, `last_summary`, `stale_after_days` (Standard 3). Fremde Konten sehen einander nicht.
- **Idempotente Massenanlage** `import_plan`: Tabelle `task_external_keys` (eindeutig je Projekt), eine Transaktion, höchstens 300 Einträge, Unteraufgaben eine Ebene, `dryRun`. Legt an, aktualisiert Titel/Beschreibung, ergänzt Kriterien (nach exaktem Text), setzt open nach done; löscht, öffnet und enthakt nie (das Board ist maßgeblich für Fortschritt).
- **Aktualität serverseitig**: `fresh|stale|never` je Projekt in der Steuerzentrale (`projects[].sync`), `summary.staleProjects`, Tool `get_stale_projects`. Schwelle je Projekt konfigurierbar.
- **Neuer Scope `projects:write`** (nur `create_project`). Die Zustimmungsseite erlaubt mit diesem Scope eine Verbindung ohne vorab gewähltes Projekt; neu angelegte Projekte werden dem Grant automatisch hinzugefügt (sonst könnte ein Agent sein eigenes Projekt nicht benutzen). Bestehende Verbindungen behalten ihre Scopes; wer `create_project` braucht, verbindet neu.
- **Kein Auto-Löschen, kein automatisches Überschreiben** von Briefings: `set_agent_brief` prüft die Version.

## Grenzen

Der Server kann Aktualität nur sichtbar machen (Zeitstempel), nicht erzwingen, dass ein Agent sie pflegt. Durchsetzung am Client: Hooks (Plugin), siehe docs/CLAUDE-CODE-EINRICHTUNG.md.
