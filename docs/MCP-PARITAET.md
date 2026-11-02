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

## Umgesetzt: Stapel 1 (CRUD-Parität)

Stand 2.11.2026, Code in `Sources/TodoKit/MCP/MCPProjectTools.swift`, Tests `MCPProjectToolsTests`. Alle Tools prüfen Scope, Grant-Projektliste und die aktuelle Rolle; nicht erreichbar = `not_found`. Handbuch noch nicht nachgezogen (macht die Hauptsession): der Test `testManualDocumentsEveryRegisteredToolAndEveryFieldIsDescribed` schlägt bis dahin für die vier neuen Tools fehl.

| Tool | Scope | Klasse | Parameter | Fehlercodes |
| --- | --- | --- | --- | --- |
| `create_task` (erweitert) | tasks:write | A | `projectID`, `title`, optional `description`, `columnID` (Done-Spalte legt erledigt an), `dueDate` (ISO 8601 oder `YYYY-MM-DD`, UTC), `priority` 0..3 | `invalid_title`, `invalid_priority`, `invalid_due_date`, `not_found` |
| `update_task` (umgestellt) | tasks:write | A | wie bisher | `version_conflict`, `invalid_status`, `invalid_title`, `not_found` |
| `move_project` | projects:write | B | `projectID`, `version`, `parentID` (UUID oder null = oberste Ebene) | `version_conflict`, `project_cycle`, `invalid_version`, `invalid_parentID`, `not_found`, `forbidden` |
| `set_project_position` | projects:write | A | `projectID`, `afterProjectID` (Geschwister oder null = zuerst); persönliche Reihenfolge | `invalid_after_project`, `invalid_afterProjectID`, `not_found` |
| `update_criterion` | tasks:write | A | `criterionID`, `text`, optional `version` | `invalid_text`, `version_conflict`, `invalid_version`, `not_found` |
| `delete_criterion` | tasks:write | C | `criterionID`, optional `version` | `confirmation_required`, `version_conflict`, `not_found` |
| `delete_column` (abgesichert) | tasks:write | C | `id`, optional `version`, `moveTo` (Spalten-ID oder `none`) | `confirmation_required`, `invalid_move_to`, `version_conflict`, `not_found` |

- `create_task`/`update_task` laufen über `PlanningOperations.createTask` bzw. `PlanningService.update` (dieselben Dienste wie `POST/PATCH /v1/tasks`): Aktivität (`task.created`, `task.updated`, `task.status_changed`, `task.moved`), Sync-Einträge, Spalten-Abgleich, Wiederholungsfolge beim Erledigen, Bereinigen von Abhängigkeiten, Meilensteinen und Unteraufgaben-Verknüpfungen beim Projektwechsel. Antwortformat unverändert (`TaskDTO`). `dueDate`/`priority` werden nach dem Anlegen über `PlanningService.put` gesetzt (eine Transaktion). Das Zielprojekt eines Wechsels muss im Grant liegen. Aktivität nennt wie REST die Person als Akteurin.
- `move_project` nutzt `PlanningOperations.updateProject` (Zyklenschutz, `manage` an Quelle und Ziel). Antwort `{id, name, version, parentID}`.
- `set_project_position` nutzt `ProjectStateService.position` (wie `PUT /v1/projects/{id}/position`, ohne Elternwechsel; dafür `move_project`). Antwort `{id, version, position}`.
- `delete_column` und `delete_criterion` legen nur eine Bestätigungsanfrage an (ADR 0026, Aktionen `delete_column`/`delete_criterion` in `ConfirmableActions`; Auswirkung `targetType` column bzw. criterion). Beim Bestätigen laufen `ColumnService.delete` (Aufgaben ziehen um) bzw. das Löschen mit Aktivität `criterion.deleted`. Beispiel: `delete_column {id, moveTo: "none"}` gibt `confirmation_required` mit `actionRequestID` zurück; Ergebnis über `get_action_request`.
- Namensabweichung zum Plan: `request_project_deletion`/`request_task_deletion` bleiben bei den bestehenden `delete_project`/`delete_task`.

## Umgesetzt: Stapel 2

Planung nutzt `tasks:read` zum Lesen, `tasks:write` zum Schreiben (keine neuen Scopes). Zusätzlich gelten explizite Grant-Projektliste und aktuelle Rolle Lesen/Bearbeiten. Nicht erreichbare Objekte liefern `not_found`. Bestehende `get_task`/`list_tasks` unverändert. Gemeinsamer Fachpfad: `PlanningService` (`PlanningToolService.swift` extrahiert REST-Listen, Meilensteine und Entfernen von Abhängigkeiten); keine Modelländerungen im MCP-Tool.

| Tool | Scope | Klasse | Parameter und Ergebnis |
| --- | --- | --- | --- |
| `get_task_planning` | tasks:read | A | `taskID`; REST PlanningTaskDTO mit task, dueAt, plannedAt, priority, position, recurrence, reminders |
| `update_task_planning` | tasks:write | A | `taskID, version?, dueDate?, dueTime?, dueAt?, plannedAt?, priority?, recurrence?, reminders?`; PlanningTaskDTO |
| `list_planned_tasks` | tasks:read | A | `view: today|upcoming|up_next, projectID?, limit?`; REST-Sortierung/Filter, UTC-Tagesgrenze |
| `set_dependencies` | tasks:write | B | `taskID, blockedBy: UUID[]` (max. 100, keine Duplikate); ersetzt atomar, leere Liste entfernt alle, Zyklenschutz |
| `list_dependencies` | tasks:read | A | `taskID, limit?`; TaskDTO-Liste, nur sichtbare Blocker im Grant |
| `remove_dependency` | tasks:write | B | `taskID, otherTaskID`; entfernt genau eine Abhängigkeit, idempotent |
| `list_milestones` | tasks:read | A | `projectID, limit?`; REST PlanningMilestoneDTO-Liste mit begrenzten, erlaubten Mitgliedsaufgaben |
| `create_milestone` | tasks:write | A | `projectID, title, dueDate?`; PlanningMilestone |
| `assign_milestone`, `unassign_milestone` | tasks:write | A | `taskID, milestoneID`; beide Projekte im Grant, Meilenstein muss im Projekt oder Vorfahren liegen |
| `delete_milestone` | tasks:write | C | `milestoneID`; `confirmation_required` mit actionRequestID, kein direktes Löschen; Aufgaben bleiben |

Listen: Vorgabe 50, Grenze 200 (`list_milestones` auch für Aufgaben je Meilenstein). Beide Seiten einer schreibenden Verknüpfung müssen im Grant sein; `set_dependencies` lehnt auch das implizite Entfernen eines vorhandenen Blockers außerhalb des Grants ab. Klasse B schreibt Aktivität über denselben Dienst wie REST (neu `task.dependency_added/removed`), Live-Middleware bleibt aktiv.

Planung ist ein Patch: fehlende Felder bleiben erhalten; null löscht dueDate/dueAt/plannedAt/recurrence, `reminders: []` leert Erinnerungen. `dueDate: YYYY-MM-DD`, `dueTime: HH:mm` in UTC; ohne Uhrzeit Mitternacht, Uhrzeit allein nutzt vorhandenen Tag. Alternativ REST-Felder `dueAt`, `plannedAt` als ISO 8601 (dueAt nicht mit dueDate/dueTime mischen). Wiederholung wie REST: `{frequency: daily|weekly|monthly, interval: 1..1000, timeZone: IANA, until?: ISO8601}`; braucht Fälligkeit oder Planung. Höchstens 100 ISO-Erinnerungen, Priorität 0..3. Mit `version` prüft und erhöht der bestehende Sync-Fachpfad die Task-Version; ohne Version gelten die bisherigen REST-Semantiken (kein Versionssprung). Abhängigkeiten und Meilensteine besitzen im REST keine Version und akzeptieren deshalb keine erfundene Optimistic-Concurrency-Option.

Beispiele: `update_task_planning {"taskID":"…","version":1,"dueDate":"2026-11-03","dueTime":"12:30","priority":3}`; `set_dependencies {"taskID":"…","blockedBy":["…"]}`; `delete_milestone {"milestoneID":"…"}` erstellt nur eine Bestätigungsanfrage. Fehler: `insufficient_scope`, `not_found`, `version_conflict`, `invalid_arguments`, `invalid_id`, `invalid_date`, `invalid_version`, `invalid_priority`, `invalid_recurrence`, `recurrence_requires_date`, `invalid_reminders`, `invalid_dependencies`, `dependency_cycle`, `invalid_view`, `invalid_limit`, `invalid_title`, sonst REST-Rechte-/Validierungsfehler. Keine Namenskollisionen, keine Migration.
## Umgesetzt: Stapel 3

Elf Tools, alle in `MCPDiscoveryTools.swift`. Fachpfad: `DiscoveryService`, gemeinsam mit REST; keine direkten Modellmutationen im MCP. `query` bei Filtern ist Suchtext oder REST-Kriterien `{q?, projectID?, labelID?, status?}`. Labels/Filter sind private Kontometadaten und dürfen kontoweit gelesen/gepflegt werden; Aufgabeninhalte kommen ausschließlich aus aktuell lesbaren Grant-Projekten. Bestehende Verbindungen bekommen die neuen Scopes nicht automatisch.

| Tool | Scope | Klasse | Parameter / Ergebnis |
| --- | --- | --- | --- |
| `search_tasks` | tasks:read | A | `query, projectID?, status?, limit?` → DiscoveryPage nur mit Aufgaben |
| `list_labels` | labels:read | A | keine → höchstens 100 eigene Labels |
| `create_label` | labels:write | A | `name, color?` → Label mit Version |
| `update_label` | labels:write | A | `labelID, version, name?, color?` → Label |
| `set_task_labels` | labels:write | A | `taskID, labelIDs[]` (höchstens 100) → `{ok:true}`; ersetzt nur eigene Zuordnungen |
| `delete_label` | labels:write | C | `labelID, version?` → Bestätigungsanfrage |
| `list_filters` | filters:read | A | keine → höchstens 100 eigene Filter |
| `create_filter` | filters:write | A | `name, query` → Filter mit REST-`criteria` und Version |
| `update_filter` | filters:write | A | `filterID, version, name?, query?` → Filter |
| `run_filter` | filters:read + tasks:read | A | `filterID, limit?` → DiscoveryPage nur mit Aufgaben |
| `delete_filter` | filters:write | C | `filterID, version?` → Bestätigungsanfrage |

Beispiele: `search_tasks {"query":"Anmeldung","limit":20}`, `create_label {"name":"Wichtig","color":"#ff0000"}`, `create_filter {"name":"Offen","query":{"status":"open"}}`, `set_task_labels {"taskID":"<UUID>","labelIDs":[]}`. Namen getrimmt 1–200 Zeichen, Farbe `#RRGGBB`, Suchtext höchstens 500 Zeichen, Limit 1–100 (Standard 50). Suchergebnisse werden vor dem Limit auf Grant-Projekte begrenzt; Label-Verknüpfungen erweitern die Reichweite nicht. Gespeicherte Filter mit explizitem Projekt außerhalb des Grants liefern `not_found`.

Fehler: `insufficient_scope`, `not_found` (auch fremde Labels/Filter und entzogene Leserechte), `version_conflict`, `invalid_arguments`, `invalid_name`, `invalid_color`, `invalid_query`, `invalid_limit`, `invalid_version`; sonst REST-Validierungsfehler als Tool-Fehler. C-Tools liefern `confirmation_required` mit `actionRequestID`, führen noch nichts aus und prüfen Eigentum/Version erneut bei Bestätigung. Optionales Label-`color` ist additiv in REST und Sync, Migration `AddDiscoveryLabelColor` vor Serve ausführen. Die PWA zeigt für neue Aktionsarten den vorhandenen generischen Bestätigungstext und die serverseitige Zusammenfassung. Kein Toolname kollidiert; Handbuch-/Plugin-Update macht die Hauptsession.

## Umgesetzt: Stapel 5 (Teilen und Teams)

Stand 2.11.2026, Code `Sources/TodoKit/MCP/MCPSharingTools.swift`, Tests `MCPSharingToolsTests`. Gemeinsamer Fachpfad `SharingOperations` (auch von `SharingController` genutzt): Rechteprüfung, Principal-Validierung, Sperre des Rechte-Graphen und Sync-Einträge der Sichtbarkeit wie bei REST. Alle Tools prüfen Scope, Projektliste der Verbindung und die aktuelle Rolle; nicht erreichbar = `not_found`, fehlende Rolle = `Forbidden`.

Neue Scopes (bestehende Verbindungen bekommen sie nicht automatisch, Zustimmungsseite und `scope.*` in de.ts ergänzt): `sharing:read`, `sharing:write`, `teams:read`, `teams:write`.

| Tool | Scope | Klasse | Parameter / Wirkung |
| --- | --- | --- | --- |
| `list_project_grants` | sharing:read | A | `projectID`; Freigaben mit Namen, nur mit Rolle manage |
| `get_project_visibility` | sharing:read | A | `projectID`, optional `userID` (dann manage nötig); wirksame Rolle, Eigentümer, Vererbung |
| `set_project_grant` | sharing:write | B / C | `projectID`, `principalType` person\|team, `principalID`, `role` read\|comment\|edit\|manage; direkt nur für eigene Teams und Bekannte (Eigentümer, vorhandene Freigabe-Empfänger, Mitglieder eigener Teams) mit Rolle bis edit und wenn alle Unterprojekte im Grant liegen, sonst Bestätigungsanfrage |
| `revoke_project_grant` | sharing:write | C | `projectID`, `grantID`, optional `version` (Projekt); immer Bestätigungsanfrage |
| `list_teams` | teams:read | A | eigene Teams mit `isAdmin`, `founderID` |
| `list_team_members` | teams:read | A | `teamID`; Mitglieder mit Name, `isAdmin`, `accepted` |
| `create_team` | teams:write | A | `name`; Gründer und Admin, gewährt keinen Zugriff |
| `invite_team_member` | teams:write | B / C | `teamID`, `userID`, `isAdmin`; Einladung direkt (Person muss annehmen), `isAdmin:true` als Bestätigungsanfrage |

- Eigentümerwechsel bleibt `transfer_project_owner` (Stapel 1, Klasse C, Scope projects:write); kein zweites Tool.
- Die Verbindung selbst wächst nie: `grant.projects` und Scopes bleiben unverändert. Weil eine Freigabe an Unterprojekte vererbt wird, führt ein Unterprojekt außerhalb des Grants zur Bestätigungsanfrage. Bestätigung führt den REST-Pfad mit den aktuellen Rechten des Kontos aus (`describe` prüft erneut), Ergebniscodes `grant_set`, `grant_revoked`, `invited`.
- Beispiele: `set_project_grant {"projectID":"…","principalType":"team","principalID":"…","role":"edit"}`, `revoke_project_grant {"projectID":"…","grantID":"…"}`, `invite_team_member {"teamID":"…","userID":"…"}`.
- Fehlercodes: `insufficient_scope`, `not_found`, `Forbidden`, `invalid_role`, `invalid_principal`, `invalid_name`, `invalid_version`, `invalid_projectID`, `account_disabled`, `team_founder_required`, `confirmation_required`, `version_conflict` (bei Bestätigung).
- Offen: Handbuch (`docs/agent-manual.md`, `AgentManualContent.swift`) und Version werden von der Hauptsession einmal nachgezogen; der Test `testManualDocumentsEveryRegisteredToolAndEveryFieldIsDescribed` schlägt bis dahin für die acht Tools fehl.

## Umgesetzt: Stapel 4

Zwölf Tools in `MCPActivityTools.swift`, keine neuen Scopes, keine Migration. Fachpfad wie REST: `CommentService` (neu `edit`/`delete`, nun auch von den REST-Routen genutzt), `ProjectCommentService` (optionaler `actor`), `ActivityFeedService` (neu `allowedProjects`), `AttachmentService`, `WorkflowService.registerBuild`. Jedes Tool prüft Scope, Grant-Projektliste (bei Objekten über Aufgabe oder Anhang) und aktuelle Rolle; nicht erreichbar = `not_found`. Aktivität nennt die Verbindung (`integration`) als Akteurin.

| Tool | Scope | Klasse | Parameter / Ergebnis |
| --- | --- | --- | --- |
| `update_comment` | comments:write | A | `taskID, commentID, version, body`; nur eigene Agentennachrichten (Texte von Personen: `not_agent_comment`); CommentDTO |
| `delete_comment` | comments:write | C | `taskID, commentID, version?`; Bestätigungsanfrage (Autor oder manage) |
| `list_project_comments` | projects:read | A | `projectID, limit?` (1..200, Standard 100, die neuesten); ProjectCommentDTO-Liste |
| `add_project_comment` | comments:write | A | `projectID, body, idempotencyKey?`; Rolle comment nötig |
| `update_project_comment` | comments:write | A | `projectID, commentID, version, body`; nur eigene Kommentare |
| `delete_project_comment` | comments:write | C | `projectID, commentID, version?`; Bestätigungsanfrage |
| `list_activity` | tasks:read | A | `projectID?, limit?` (1..100, Standard 50), `before?` (nextCursor); Aufgaben- und Projektereignisse, nur Grant-Projekte, die das Konto lesen darf |
| `read_attachment` | attachments:read | A | `id, preview?`; `{attachment, build?, preview?: {mediaType, dataBase64}, previewOmitted?}`; Vorschau nur Bilder bis 1 MiB (`not_an_image`, `too_large`) |
| `register_build` | attachments:write | A | `attachmentID, buildID, label?, platform?`; macht einen fertigen Anhang zum Build-Screenshot, idempotent, `build.added` einmal |
| `begin_task_upload` | attachments:write | A | `taskID, filename, role (reference\|progress\|result), mediaType, size, checksum`; wie `begin_attachment`, aber mit wählbarer Rolle, ohne Build-Eintrag |
| `complete_task_upload` | attachments:write | A | `attachmentID`; nur eigene Uploads auf erlaubter Aufgabe |
| `delete_attachment` | attachments:write | C | `attachmentID`; Bestätigungsanfrage; Bestätigen blendet die Datei und ihren Build-Eintrag aus (Status `deleted`, Aktivität `attachment.deleted`), `cleanup-uploads` entfernt die Bytes |

Beispiele: `update_comment {"taskID":"…","commentID":"…","version":1,"body":"neu"}`; `list_activity {"limit":20}`; `read_attachment {"id":"…","preview":true}`; `delete_attachment {"attachmentID":"…"}` gibt `confirmation_required` mit `actionRequestID` zurück.

Fehler: `insufficient_scope`, `not_found`, `version_conflict`, `invalid_arguments`, `invalid_version`, `invalid_limit`, `invalid_id`, `invalid_text`, `invalid_cursor`, `invalid_idempotency_key`, `idempotency_conflict`, `not_comment_author`, `not_agent_comment`, `invalid_attachment`, `invalid_size`, `invalid_build_id`, `confirmation_required`. Entscheidung: Agenten dürfen mit `update_comment` keine Texte von Personen ändern, obwohl dasselbe Konto sie geschrieben hat (REST erlaubt dem Konto das). Handbuch und Version macht die Hauptsession.

## Umgesetzt: Stapel 6 (Board und persönlicher Zustand)

Sieben Tools in `MCPBoardTools.swift`, Tests `MCPBoardToolsTests` (11). Keine neuen Scopes, keine Migration. Fachpfad wie REST: `ColumnService`, `ProjectStateService`, `PlanningService.reorderBoard` (aus `PUT /v1/board/reorder` extrahiert, REST nutzt es jetzt auch). Scope, Grant-Projektliste und aktuelle Rolle werden geprüft; nicht erreichbar = `not_found`. Schon vorhanden aus Stapel 1: `set_project_position` und `delete_column` (Klasse C, Bestätigungsanfrage, per Test erneut belegt); `rename_column` bleibt.

| Tool | Scope | Klasse | Parameter / Ergebnis |
| --- | --- | --- | --- |
| `update_column` | tasks:write | A | `id, version, name?, color? ("" entfernt), isDone?, index?` (mind. ein Feld); ColumnDTO |
| `apply_column_template` | tasks:write | B | `projectID, source` (`status`, `agent_workflow` oder Projekt-ID im Grant); nur für Projekte ohne Spalten (`columns_exist`), Aufgaben werden nach Status eingeordnet; Spaltenliste |
| `reorder_tasks` | tasks:write | A | `projectID, status, taskIDs[]` (alle Aufgaben des Status genau einmal, höchstens 1000); `{ok, count}` |
| `list_favorites` | projects:read | A | keine; `[{projectID, position}]`, nur Projekte im Grant |
| `set_project_favorite` | projects:write | A | `projectID, favorite, index?` (index nur mit favorite=true); Favoritenliste |
| `get_project_prefs` | projects:read | A | `projectID`; view, sort, grouping, showCompleted, mode, modeSource, isFavorite, revision |
| `update_project_prefs` | projects:write | A | `projectID, revision, view?, sort?, grouping?, showCompleted?, mode?`; gleicher strenger Decoder wie REST |

Persönliche Einstellungen (Favoriten, Anzeige) sind kontoweit privat und erweitern keine Reichweite; Favoriten außerhalb des Grants erscheinen in der Verbindung nicht. Optimistic Concurrency: Spalten über `version` (`version_conflict`), Anzeige-Einstellungen über `revision` (`revision_conflict`), Reihenfolge über `board_changed`.

Beispiele: `update_column {"id":"…","version":1,"name":"Review","color":"#ff0000"}`, `apply_column_template {"projectID":"…","source":"agent_workflow"}`, `reorder_tasks {"projectID":"…","status":"open","taskIDs":["…","…"]}`, `set_project_favorite {"projectID":"…","favorite":true,"index":0}`, `update_project_prefs {"projectID":"…","revision":0,"view":"board"}`.

Fehler: `insufficient_scope`, `not_found`, `version_conflict`, `revision_conflict`, `board_changed`, `columns_exist`, `invalid_arguments`, `invalid_version`, `invalid_index`, `invalid_color`, `invalid_isDone`, `invalid_source`, `invalid_status`, `invalid_taskIDs`, `invalid_favorite`, `invalid_view|sort|grouping|mode|showCompleted`, `revision_required`, `empty_project_prefs`, `invalid_project_prefs`. Handbuch und Version macht die Hauptsession; der Test `testManualDocumentsEveryRegisteredToolAndEveryFieldIsDescribed` schlägt bis dahin für die sieben Tools fehl.
