# ADR 0020 – Planung und Labels im Sync

Status: umgesetzt (31.10.2026), nur SQLite geprüft. Ergänzt ADR 0009 (Sync) und 0019 (Aufbewahrung). Vertrag `contracts/sync.yaml` 1.4.0.

## Kontext

Der Apple-Client konnte Fälligkeit, Bearbeitungsdatum, Priorität, Wiederholung, Erinnerungen und Labels nur über REST bearbeiten; der Feed kannte beides nicht, sodass die Outbox (nur Sync-Mutationen) sie nicht abbilden konnte.

## Entscheidung (rein additiv)

**Planung als Teil des Task-Upserts.** Jedes Task-Upsert trägt zusätzlich `planning {dueAt, plannedAt, priority, recurrence, reminders}` (Standardwerte, wenn nichts geplant ist). Keine eigene Entität: die Planung gehört 1:1 zur Aufgabe und hat deren Sichtbarkeit; Tombstones/Revokes der Aufgabe gelten damit auch für sie. `position` (Planungs-Board) wird nicht synchronisiert (Sync nutzt Spalten, ADR 0011).
- Mutation `task.planning`: Pflicht `version`; vollständiger Ersatz wie `PUT /v1/planning/tasks/{id}` (fehlende Felder löschen), gleiche Validierung (Priorität 0..3, Wiederholung braucht Datum, max. 100 Erinnerungen), Rolle `edit` (read: 403, Fremdes: 404), Zeilensperren wie `PlanningService.update` (`lockSharingGraph`, `lockRow` auf `tasks`). Die Aufgabenversion wird erhöht (stale `task.update`/`task.planning` ergeben 409). Wiederholungs-Folgeaufgaben für bereits erledigte Aufgaben entstehen wie bei REST.
- REST `PUT /v1/planning/tasks/{id}` bleibt unverändert (keine Versionsprüfung, Version unverändert), schreibt aber jetzt ein Task-Upsert ins Protokoll, damit andere Geräte die Änderung sehen.

**Labels als Entität `label`.** Das bestehende Modell (`DiscoveryLabel`, ADR Discovery) ist **konto-privat**: Besitzer = Ersteller, kein Team-/Freigabe-Bezug; Verknüpfung (`DiscoveryTaskLabel`) braucht nur Leserecht auf die Aufgabe (nicht edit) und ist ebenfalls privat. Daher:
- Feed: `entityType: "label"`, `label {id, name, version, taskIDs}`; `taskIDs` ist die vollständige, aktuell lesbare Mitgliedschaft. Anlegen/Umbenennen/Löschen und jede Verknüpfungsänderung erzeugen ein Label-Upsert (Model-Middleware, damit auch REST). Löschen: Tombstone nur an den Besitzer (eingefrorene Audience `[owner]`). Andere Konten sehen nie fremde Labels.
- Aufgabe gelöscht (auch per Projektlöschung): betroffene Labels werden neu geliefert (Kaskade feuert keine Events). Sichtbarkeitsverlust einer Aufgabe liefert **kein** Label-Upsert; der Client entfernt die Verknüpfung beim Aufgaben-Tombstone selbst. Serverseitig werden `taskIDs` immer gegen die aktuellen Leserechte gefiltert.
- Mutationen: `label.create` (Client wählt ID, `id_exists`/`id_deleted` wie bei anderen), `label.rename` (`version` Pflicht), `label.delete` (`version` optional), `task.label_add`/`task.label_remove` (`id` = Aufgabe, `labelID`; idempotent, kein Version-Feld). Fremdes Label oder unlesbare Aufgabe: 404. Antwort enthält `label` (Stand nach der Änderung).
- Migration `BackfillLabelSync` (zuletzt registriert) schreibt Upserts für bestehende Labels, damit `c0` vollständig bleibt.

**Idempotenz/Replay/Retention** laufen unverändert über `sync_mutations`, `sync_changes` und ADR 0019 (generisch nach `entity_id`). Alte Clients ignorieren unbekannte Felder, `entityType`-Werte und Mutationstypen.

## Grenzen

MariaDB nicht geprüft (Docker-VM voll); neues SQL beschränkt sich auf Fluent-Abfragen. Abhängigkeiten und Meilensteine sind nicht im Feed. Kein Label-Upsert bei reinem Sichtbarkeitsverlust (siehe oben).
