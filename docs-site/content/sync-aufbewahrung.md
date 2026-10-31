# Sync-Aufbewahrung und Cleanup

Das Sync-Protokoll (`sync_changes`, Tombstones, gespeicherte Mutationsergebnisse) wuchs ursprünglich unbegrenzt, und `App cleanup-expired` lief nur von Hand. Seit ADR 0019 begrenzt das Backend die Aufbewahrung, löscht Konten mit Tombstones und räumt periodisch auf. Entscheidung: [ADR 0019](adr/0019-sync-aufbewahrung-und-cleanup-scheduler.md), Betriebsdetails: [Betrieb](betrieb.html), Vertrag: [Sync](api/sync.html) (Version 1.3.0).

## Aufbewahrung und 410 cursor_expired

- Frist `SYNC_RETENTION_DAYS` (Standard 90, `0` behält alles). Gelöscht werden Tombstones samt eingefrorener Leserschaft, durch spätere Änderungen ersetzte Upserts und gespeicherte Mutationsergebnisse, die älter als die Frist sind.
- Der jeweils neueste Stand lebender Objekte bleibt, damit der vollständige Abgleich ab `c0` immer den kompletten sichtbaren Stand liefert.
- Ein Aufbewahrungsboden in `sync_counter` hält die höchste gelöschte Sequenznummer. Ein Client mit Cursor unterhalb des Bodens bekommt **410 `cursor_expired`**, damit ihm keine Löschung stillschweigend entgeht. Er verwirft den Cache des Kontos und lädt ab `c0` neu. Offline-Änderungen des Clients bleiben dabei erhalten.
- Folge: Geräte, die länger als die Frist offline sind, müssen einmal komplett neu synchronisieren. Die zufällige UUID einer gelöschten Entität ist nach der Frist nicht mehr gesperrt; das wird hingenommen.

## Kontolöschung

`App delete-account <user-id> --yes` löscht das Konto in einer Transaktion: besessene Projekte und Aufgaben über die Modelle (mit Tombstones für andere Konten), Personen-Freigaben, dann das Konto. Gelingt etwas nicht, wird alles zurückgerollt. Es gibt noch keinen Selbstbedienungsweg in der App. Vorher sichern.

## Cleanup-Scheduler

Jedes Backend-Replikat startet bei `serve` einen Hintergrund-Task. Eine Zeile in `maintenance_leases` sorgt dafür, dass pro Intervall nur ein Replikat arbeitet (atomares `UPDATE`, Datenbankzeit, 30 Minuten Lease, Wiederholung 5 Minuten nach Fehler). Er löscht abgelaufene Sitzungen, Challenges, Einladungen, Recovery-Grants, Rate-Limit-Zeilen, OAuth-Tokens, Kopplungscodes und alte Sync-Protokolleinträge.

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `CLEANUP_INTERVAL_MINUTES` | `360` | Minuten zwischen Läufen; `0` schaltet den Scheduler ab (dann `App cleanup-expired` per Cron planen). Gültig 0 bis 10080. |
| `SYNC_RETENTION_DAYS` | `90` | Aufbewahrung in Tagen; `0` behält alles. Gültig 0 bis 3650. |

Prüfen: `GET /health/ready` zeigt informativ `maintenance` mit `enabled`, `lastRunAt` und `lastStatus`; ein Fehler ändert die Bereitschaft nie.

## Stand

Geprüft sind die acht neuen Tests auf SQLite (Retention mit 100 Tage alten Zeilen, 410, Kontolöschung, Scheduler mit vier Replikaten, Lease-Übernahme, Fehlerlauf). Nicht geprüft: der MariaDB-Lauf der neuen Tests, der Scheduler im echten Swarm-Rollout und Last mit großen Tabellen. Der Apple-Client behandelt 410 (129 Tests grün, nicht live gegen das Backend); die PWA nutzt den Sync-Feed nicht. Siehe [Status](status.html).
