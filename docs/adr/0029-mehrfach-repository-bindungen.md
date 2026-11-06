# ADR 0029: Mehrere Repository-Bindungen je Projekt

Status: umgesetzt in Backend und MCP (6.11.2026); PWA-Anzeige folgt (Schritt 4 des Plans).

## Kontext

Ein Projekt hatte höchstens eine Repository-Bindung (`project_bindings`, Primärschlüssel = Projekt-ID, ADR 0018). Ein neues Binden ersetzte die alte Bindung und setzte den Sync-Verlauf zurück. Nutzerentscheidung 2.11.2026: mehrere Bindungen je Projekt, jede mit eigenem Verlauf. Plan und Annahmen: `docs/PLAN-MEHRFACH-REPOSITORY-BINDUNGEN.md`.

## Entscheidungen

1. Neue Tabelle `project_repository_bindings` (eigene UUID, unique `(owner_id, repo_key)` und `(project_id, repo_key)`); die Migration kopiert Altzeilen additiv, die Alttabelle bleibt bestehen. Gründe: Primärschlüssel lässt sich auf SQLite nicht per ALTER ändern; Revert bleibt ungefährlich.
2. Bis 10 Bindungen je Projekt (`too_many_bindings`). Standardbindung = älteste. Ein Projekt gilt als veraltet, sobald eine Bindung nicht frisch ist; die flachen Felder beschreiben die veraltetste Bindung, `bindings` listet alle, `get_stale_projects` nennt `staleBindings`.
3. Mit mehr als einer Bindung braucht `record_sync` das Feld `repository` (`repository_required`); bei 0 oder 1 Bindung bleibt das Verhalten wie zuvor.
4. Neue Werkzeuge `list_repository_bindings` (`projects:read`) und `unbind_repository` (`tasks:write`), REST `GET`/`DELETE /v1/projects/{id}/bindings`. Keine neuen Scopes, kein Re-Consent. Lösen schreibt keinen Aktivitätseintrag (es gibt keine Projekt-Aktivität); `effect` in der Antwort beschreibt die Wirkung.
5. Das Plugin (1.7.0) gibt `repository` aus `.todolino.json` an `get_sync_status` und `record_sync` weiter.

## Folgen

- Handbuch 1.17.0, Vertrag `project-sync.yaml` 1.1.0. Ältere Plugin-Installationen laufen bei Mehrfachbindung in `repository_required`.
- Offen: die Alttabelle `project_bindings` bleibt als Altlast bis zu einer späteren Migration; `owner_id` der Bindung wird bei Eigentümerwechsel nicht nachgezogen (bekannte Lücke, unverändert); Apple-App ungeprüft (nutzt laut Analyse die Sync-Routen nicht).
