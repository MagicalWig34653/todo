# Plan: mehrere Repository-Bindungen je Projekt (Board-Aufgabe `BE954C5C-D70B-4F25-8612-F48B53521899`)

Stand 6.11.2026. Nutzerentscheidung 2.11.2026: mehrere Bindungen je Projekt, jede mit eigenem Sync-Verlauf (heute ersetzt ein neues Binden das alte und setzt den Verlauf zurück). Der Plan stammt aus einer read-only Analyse (Planer-Agent); Annahmen sind als solche markiert.

## Entscheidungen des Orchestrators (Annahmen, jederzeit änderbar)

- Ein Projekt gilt als veraltet, sobald eine Bindung nicht frisch ist (veraltetste Bindung bestimmt); `staleProjects` zählt weiter Projekte.
- Obergrenze 10 Bindungen je Projekt (`too_many_bindings`).
- Standardbindung = älteste Bindung (`created_at`, dann `id`); kein Default-Flag.

## Datenmodell und Migration

- `project_bindings` hat `id` = Projekt-ID als Primärschlüssel (Engpass; auf SQLite nicht per ALTER änderbar). Neue Tabelle `project_repository_bindings`: `id` (UUID), `project_id` (FK projects, cascade), `owner_id`, `repo_key`, `stale_after_days`, alle `last_*`-Felder, `version`, Zeitstempel; unique(`owner_id`, `repo_key`) und unique(`project_id`, `repo_key`).
- Migration `AddProjectRepositoryBindings`: additiv und wiederholbar, kopiert alte Zeilen (neue `id` = alte Projekt-ID, Prüfung vor Insert, chunkweise, Fluent statt Roh-SQL), Alttabelle bleibt unverändert, Revert löscht nur die neue Tabelle.
- Neues Modell `ProjectRepositoryBinding`; `ProjectBinding` bleibt nur als Legacy für die Migration.

## Verhalten

- 0 oder 1 Bindung: Verhalten und Antwortform wie heute.
- `bind_repository {projectID, repository?, staleAfterDays?}`: mit `repository` wird eine weitere Bindung angelegt (existiert sie schon, ändert sich nur die Schwelle); Verlauf wird nie mehr zurückgesetzt. Ohne `repository` und genau 1 Bindung: Schwelle ändern; bei mehr als 1: `repository_required`. `repository_already_bound`, wenn der Schlüssel bei diesem Eigentümer schon an ein anderes Projekt gebunden ist.
- `record_sync` ohne `repository` bei mehr als 1 Bindung: `repository_required` (409, mit Liste der Schlüssel). `get_sync_status` ohne `repository`: flache Felder der veraltetsten Bindung (never vor stale vor fresh, dann größtes `daysSince`) plus `bindings: [...]`; mit `repository` genau diese, sonst `not_bound`.
- Neue MCP-Tools: `list_repository_bindings {projectID}` (Scope `projects:read`), `unbind_repository {projectID, repository}` (Scope `tasks:write`, kein neuer Scope, kein Re-Consent; Risikoklasse B mit Aktivitätseintrag).
- REST (`contracts/project-sync.yaml` auf 1.1.0): `GET /v1/projects/{id}/sync` weiter kompatibel plus `bindings`, `?repository=`; `PUT` legt hinzu; neu `GET /v1/projects/{id}/bindings` und `DELETE /v1/projects/{id}/bindings?repository=`.
- Stale/Command Center: `projects[].sync` bleibt flach (veraltetste Bindung) plus `bindings`; `get_stale_projects` zusätzlich `staleBindings`. Abfragen chunkweise nach `project_id`; die Abfragezahl im Command Center bleibt konstant.
- Hinweis: `SyncRecorder` und der Teilbaum-Vergleich gehören zum Geräte-Sync (`Sources/TodoKit/Sync/`) und haben nichts mit `project_bindings` zu tun.

## Rechte und Mandanten

Lesen: Leserecht plus Grant. bind/unbind/record_sync: Edit-Recht unter `lockSharingGraph` und `lockRow(project)`; Eindeutigkeit `(owner_id, repo_key)` in der Transaktion, zusätzlich DB-Unique als 409 abfangen. `repository` immer über `RepositoryKey.normalize`; keine Credentials in Antworten. Bekannte Lücke (nicht Teil der Aufgabe): `owner_id` der Bindung wird bei Eigentümerwechsel nicht nachgezogen; als Randfall testen.

## Worker-Schritte (sequenziell, je eigener Worktree)

1. Modell, Migration, Service: `ProjectSyncModels.swift`, `ProjectSyncService.swift`, `ProjectStateService.swift` (`agentRelated` auf `project_id`), `Configure`. Tests: Migrationstest (Altzeilen, Wiederholung, Revert), Service-Regressionen. Prüfen: `swift test --filter "ProjectSyncTests|ProjectStateTests|CommandCenterTests"`.
2. REST und MCP: `ProjectSyncController.swift`, `MCPSyncTools.swift`, Fehlercodes, `contracts/project-sync.yaml` (und Toolliste in `contracts/oauth-mcp.yaml` prüfen). Danach voller `swift test`.
3. Handbuch 1.16.0 auf 1.17.0 (`docs/agent-manual.md` und `AgentManualContent.swift` synchron, feste Versionen in `ChatThreadTests` und `CommandCenterTests`), `docs/MCP-PARITAET.md`, ADR, Plugin 1.7.0 (Skills/Hooks rufen `record_sync`/`get_sync_status` mit `repository`), `claude-plugin/tests/test-hooks.sh`.
4. PWA: `web/src/lib/api.ts`, `SyncDetail`/`RepositoryLine`: Liste der Bindungen, Lösen.

## Risiken

Ältere Plugin-Installationen ohne `repository` laufen bei Mehrfachbindung in `repository_required` (gewollt). Die Alttabelle bleibt als Altlast bis zu einer späteren Migration. Apple-App: laut Analyse keine Nutzung der Sync-Routen, Kompatibilität über flache Felder; ungeprüft.
