# ADR 0019 – Sync-Aufbewahrung, Kontolöschung und periodischer Cleanup

Status: umgesetzt (31.10.2026). Ergänzt ADR 0009 (Sync) und den Cleanup aus ADR 0007.

## Kontext

`sync_changes`, `sync_tombstone_audience` und `sync_mutations` wuchsen unbegrenzt. Die Löschung eines Kontos kaskadierte per Fremdschlüssel ohne Tombstones (andere Konten behielten Objekte im Client-Cache). `App cleanup-expired` lief nur manuell.

## Entscheidung

**Aufbewahrung (`SyncRetention`).** Frist `SYNC_RETENTION_DAYS` (Standard 90, `0` = nie löschen). Gelöscht wird nur, was älter als die Frist ist:
- `delete`/`revoke`-Einträge mit ihrer eingefrorenen Leserschaft (`sync_tombstone_audience`);
- Upserts, die durch einen späteren Upsert derselben Entität ersetzt sind oder deren Entität gelöscht wurde;
- gespeicherte Mutationsergebnisse (`sync_mutations`; sie dienen nur dem Idempotenz-Replay).
Der jeweils neueste Upsert lebender Entitäten bleibt, damit `c0` weiterhin den vollständigen sichtbaren Stand liefert.

**Boden und 410.** Eine Zählerzeile in `sync_counter` (feste ID `…0004`, Migration `AddSyncRetentionSchema`) hält den Aufbewahrungsboden: die höchste `seq` eines gelöschten Tombstones. Der Boden wird in derselben Transaktion wie das Löschen angehoben. `GET /v1/sync/changes` liest den Boden nach dem Lesen der Zeilen; `0 < cursor < Boden` ergibt **410 `cursor_expired`**. Dadurch erhält ein Leser, dem ein Tombstone entgangen sein könnte, immer den Fehler (kein stilles Verpassen von Löschungen, auch bei Konkurrenz mit dem Cleanup). `c0` und Cursor ab dem Boden bleiben gültig. Client-Anleitung: lokalen Cache des Kontos verwerfen und ab `c0` neu laden (Stand wird vollständig geliefert). Das ist derselbe Weg wie bei 409 `cursor_ahead`.

Ein Geräte-/Cursor-Register existiert nicht (Cursor sind clientseitig), deshalb gibt es keine Bedingung „älter als der kleinste Geräte-Cursor“; stattdessen zwingt der Boden zu Resync. Folge: `id_deleted` sperrt eine gelöschte ID nur innerhalb der Frist; danach könnte ein (ohnehin resyncender) Client dieselbe zufällige UUID neu anlegen. Hingenommen.

**Kontolöschung (`AccountDeletion`, `App delete-account <user-id> --yes`).** Es gibt weiterhin keine Selbstbedienungs-Route. Der Dienst arbeitet in einer Transaktion unter `lockSharingGraph`: zuerst werden vom Konto besessene Projekte und Aufgaben über die Modelle gelöscht (Tombstones mit der zu diesem Zeitpunkt eingefrorenen Leserschaft, wie bei normalem Löschen), danach die Personen-Freigaben des Kontos, dann das Konto selbst (Kaskade für Sitzungen, Mitgliedschaften usw.), schließlich wird die Sichtbarkeitsdifferenz des gesamten Graphen aufgezeichnet (Entzug über verlorene Teammitgliedschaft etc.). Audience-Zeilen für das gelöschte Konto selbst werden entfernt. Schlägt irgendetwas fehl (z. B. Fremdschlüssel `restrict` bei Agentendaten), wird alles zurückgerollt. Bereits vorhandene Wege (Team-Entfernung, Freigabe löschen, Eigentümerwechsel, Verschieben) erzeugten schon revoke-Signale (ADR 0009) und sind in `SyncTests` abgedeckt; die Lücke war nur die Kontolöschung.

**Scheduler (`CleanupScheduler`).** Jedes API-Replikat startet bei `serve` (nicht bei `migrate`/anderen Befehlen) einen Hintergrund-Task, der alle `min(Intervall, 5 min)` (±10 % Jitter, Start nach 20–60 s) `runIfDue` ausführt. Intervall `CLEANUP_INTERVAL_MINUTES` (Standard 360, `0` = aus). Koordination über die Tabelle `maintenance_leases` (Migration `CreateMaintenanceLeases`): ein einziges `UPDATE … WHERE expires_at < now AND last_run_at <= now - intervall` übernimmt atomar die Lease (Dauer 30 min, ein abgestürzter Halter wird nach Ablauf übernommen); danach liest der Replika den Halter und arbeitet nur, wenn er es selbst ist. Zeiten stammen von der Datenbankuhr. Bewusst kein `GET_LOCK` (an eine gepoolte Verbindung gebunden, geht mit ihr verloren). Der Lauf entspricht `cleanup-expired` inklusive Sync-Aufbewahrung; Ergebnis/Fehler landen in `last_status`/`last_message` und im Log, ein Fehler stürzt nichts ab und bewirkt einen Wiederholversuch nach 5 min. `/health/ready` enthält zusätzlich `maintenance {enabled,lastRunAt,lastStatus}`; der Block wird best effort gelesen und beeinflusst den Status nie.

## Betrieb/Rollout

Neue Migration vor dem Rollout ausführen (`migrate --yes`; legt Indizes `sync_changes(entity_id,seq)`, `sync_changes(created_at)`, `sync_mutations(created_at)`, die Tabelle `maintenance_leases` und die Bodenzeile an). Alte Replikate ignorieren all das und sind kompatibel. Nach dem ersten Lauf auf einer großen Instanz können die ältesten Tombstones in einem Zug gelöscht werden (Batches à 500).

## Grenzen

- Die Lease wird nicht per Heartbeat verlängert; läuft ein Lauf länger als 30 min, könnte ein zweites Replikat starten. Alle Schritte sind idempotent, daher nur doppelte Arbeit.
- `created_at` stammt von der Replikauhr; geringe Uhrabweichung ändert nur den Zeitpunkt der Löschung.
- Zählung der Läufe: Berichte zählen ausgewählte Zeilen.
- Nicht Teil des Feeds und nicht aufgeräumt: Kommentare, Labels usw.
