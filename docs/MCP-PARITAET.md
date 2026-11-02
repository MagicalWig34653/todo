# MCP-Parität mit der PWA

Stand 2.11.2026, Lückenanalyse (Codex gpt-6.1-sol, statisch). Ziel: Der MCP kann so gut wie alles, was die PWA kann. Es gelten immer zusätzlich die aktuelle Rolle des Kontos und die Projektliste der Verbindung. Große oder unumkehrbare Aktionen (Klasse C) laufen über Bestätigungsanfragen in der PWA (siehe ADR „Bestätigungsanfragen“).

## Risikoklassen

| Klasse | Bedeutung | Ablauf |
| --- | --- | --- |
| A | harmlos, umkehrbar | direkt |
| B | größere Wirkung, umkehrbar | direkt, serverseitiger Aktivitätseintrag, kurze Wirkungserklärung |
| C | groß oder unumkehrbar (Löschen, Eigentümerwechsel, Freigaben entziehen, Verbindungen, Admin) | Bestätigungsanfrage, Ausführung erst nach Bestätigung in der PWA |

## Stand

48 MCP-Tools decken Aufgabenarbeit, Agentenkommunikation und Projektkontext ab. Es fehlen vor allem: Planung (Fälligkeit, Priorität, Wiederholung, Erinnerungen, Abhängigkeiten, Meilensteine), Suche, Labels und Filter, Freigaben und Teams, Projekt verschieben und löschen, Aufgabe löschen, Kommentare ändern, Projektkommentare, Aktivität, Spalten-Details, persönliche Einstellungen, Agentenjobs starten/stoppen.

## Befunde für die Umsetzung

- **Fachparität zuerst:** `create_task`/`update_task` im MCP (MCPController.swift) mutieren direkt, REST nutzt die gemeinsamen Planungsdienste. Dadurch fehlen im MCP Aktivität, Wiederholungsfolge und das Bereinigen von Abhängigkeiten, Meilensteinen und Unteraufgaben beim Projektwechsel. Erst angleichen, dann neue Tools.
- **Klasse C fehlt technisch:** `delete_column` verlangt nur textlich eine Rückfrage. Nötig ist ein serverseitiger Antrag, gebunden an Operation, Objekt, Version, Nutzer und Ablauf.
- **Ausnahme zu entscheiden:** `create_project` ergänzt das neue Projekt in den Grant der Verbindung. Das ist eine begrenzte Ausnahme vom Verbot, eigene Reichweite zu erweitern (Entscheidung am Board).
- **Vertragsdrift:** `contracts/oauth-mcp.yaml` listet nur einen Teil der Tools und lässt `projects:write`/`attachments:write` bei den Scopes aus; `docs/agent-manual.md` ist vollständig. Verträge nachziehen.

## Bewusst nicht über MCP

- Passkeys, Anmeldung, Recovery: menschliche Identitätswege.
- Verbindungen und Grants erweitern, neue Runner-Bindungen: nur PWA/OAuth-Consent.
- Server-Einstellungen mit Geheimnissen und Zielkonfiguration.
- Konto sperren und anonymisieren: bleibt in der PWA (ein C-Antrag wäre möglich, bringt hier wenig).
- Runner-API (`/runner/*`) bleibt getrennt (Gerätetoken, Lease).

## Bau-Stapel

| Nr. | Inhalt (Toolnamen sind Vorschläge) | Klasse | Aufwand |
| --- | --- | --- | --- |
| 1 | CRUD und Bestätigungsbasis: `move_project`, `request_project_deletion`, `request_task_deletion`, `get_confirmation`; `create_task`/`update_task` an den Fachkern angleichen | A/B/C | groß |
| 2 | Planung: `get_task_planning`, `update_task_planning`, `list_planned_tasks`, `set_dependencies`, `list_milestones`, `create_milestone`, `assign_milestone`, `update_criterion` | A/B | groß |
| 3 | Suche, Labels, Filter: `search_tasks`, `list_labels`, `create_label`, `update_label`, `set_task_labels`, `list_filters`, `create_filter`, `update_filter`, `run_filter` | A (Löschen C) | mittel |
| 4 | Kommentare, Dateien: `update_comment`, `list_project_comments`, `add_project_comment`, `list_activity`, `read_attachment`, `register_build` | A (Löschen C) | mittel |
| 5 | Zusammenarbeit: `list_project_grants`, `get_project_visibility`, `set_project_grant`, `list_teams`, `list_team_members`, `create_team`, `invite_team_member`, `request_grant_revocation`, `request_owner_transfer` | A/B/C | groß |
| 6 | Board, persönlicher Zustand: `update_column`, `apply_column_template`, `reorder_tasks`, `set_project_position`, `set_project_favorite`, Einstellungen je Projekt; `delete_column` absichern | A/B/C | mittel |
| 7 | Workflow, Runner: `list_reviews`, `list_progress_notes`, `list_agent_jobs`, `list_runner_devices`, `start_agent_job`, `stop_agent_job` (nur bestehende Bindungen) | A/B | mittel |
| 8 | Einstellungen, Admin lesend: `get_preferences`, `update_preferences`, Benachrichtigungen, `get_connection`, `list_admin_users`, `get_server_health`, `list_settings_audit` (redigiert, eigene Scopes) | A/B | mittel |

Neue Scopes (Vorschlag): `preferences:*`, `labels:*`, `filters:*`, `sharing:*`, `teams:*`, `agents:write`, `notifications:*`, `connections:read`, `account:*`, `admin:read`. Jeder neue Scope erscheint auf der Zustimmungsseite verständlich.

## Plugin, Prompts, Handbuch, Hooks

- Skill `todolino`: Intent-zu-Tool-Matrix; fehlende Berechtigung führt zur Zustimmung in der PWA.
- Skills `setup`/`sync`: Planungsfelder, stabile Importschlüssel, Vorschau größerer Änderungen.
- Prompts (`MCPPrompts.swift`): z. B. `plan_project`, `triage_tasks`, `review_changes`.
- Handbuch: Rollen-/Scope-/Grant-Matrix, A/B/C, ausgeschlossene Operationen; Ablauf „Antrag, Bestätigung in der PWA, Ergebnis lesen“; Chatantwort, `ask_question` oder ein Parameter `confirmed:true` ersetzen die Bestätigung nicht; Konflikte (neu lesen, Wirkung prüfen, dann wiederholen).
- Hooks: erfolgreiche neue Tools und offene Bestätigungen berücksichtigen, ohne selbst zu autorisieren; reine Lese-Aufträge von der Board-Schreibpflicht ausnehmen.
- Eingebettetes Handbuch und Verträge synchron halten.
