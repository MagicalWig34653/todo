# ADR 0013 – Anhänge standardmäßig in der Datenbank, S3 optional

Status: umgesetzt (30.10.2026, Nutzerentscheidung: S3 darf nicht verpflichtend sein). Löst Teile von [ADR 0002](0002-dateispeicher.md) (S3 als Pflichtspeicher) und [ADR 0006](0006-anhaenge.md) (Abschnitt „Speicher und Konfiguration“) ab; Upload-Ablauf, Rechte und Prüfungen aus ADR 0006 bleiben unverändert.

## Entscheidung

Anhangsbytes liegen standardmäßig in der Datenbank (`ATTACHMENT_STORAGE=database`, Standard). Ein S3-kompatibler Dienst ist optional (`ATTACHMENT_STORAGE=s3` mit `S3_ENDPOINT`, `S3_BUCKET`, optional Schlüssel). Kein Dienst, keine Compose-Abhängigkeit, kein Swarm-Secret und keine Setup-Frage ist für den Normalbetrieb von S3 abhängig.

Referenz (nur gelesen, nichts kopiert): das Timetrack-Backend speichert Dateien in einer Tabelle `file_blobs` mit einer `LONGBLOB`-Zeile je Datei, getrennt von den Metadaten, und begrenzt Uploads auf 64 MiB; die MariaDB-Dokumentation dort verlangt ein passendes `max_allowed_packet`. Hier wird dieselbe Trennung übernommen, aber in Blöcken gespeichert, damit `max_allowed_packet` nicht vom Dateilimit abhängt.

## Umsetzung

- Protokoll `AttachmentStore` (`put`/`get`/`delete`, `Sources/TodoKit/Attachments/AttachmentStore.swift`) mit `DatabaseStore` und `S3Store`. Der Aufrufer reicht die laufende Transaktion durch; der Datenbankspeicher schreibt Blöcke im selben Commit wie das Flag „hochgeladen“, S3 ignoriert sie.
- Tabelle `attachment_blobs` (`id`, `attachment_id` mit Fremdschlüssel und `ON DELETE CASCADE`, `chunk_index`, `bytes LONGBLOB`, eindeutig je `(attachment_id, chunk_index)`). Metadaten bleiben in `attachments`; Listen- und Rechteabfragen berühren keine Blob-Seiten.
- Blockgröße 1 MiB (`AttachmentLimits.chunkBytes`). Jede Zeile bleibt weit unter `max_allowed_packet` (MariaDB-Standard 16 MiB); verlangt wird mindestens 2 MiB. Das Dateilimit beeinflusst `max_allowed_packet` nicht.
- Spalte `attachments.storage` (`database`|`s3`) je Zeile. Ein Wechsel von `ATTACHMENT_STORAGE` wirkt nur auf neue Uploads; vorhandene Anhänge werden aus dem Speicher gelesen, der in ihrer Zeile steht. Bestandszeilen aus der Zeit vor der Migration erhalten den Standard `s3`, weil S3 damals der einzige Speicher war. Fehlt S3 dafür, antwortet der Download mit 503 `attachment_storage_unconfigured`.
- Limit `ATTACHMENT_MAX_BYTES`, Standard 10 MiB (10485760), erlaubt 1024 bis 134217728. Es begrenzt `begin`, die Größenprüfung und den Body des Upload-PUT. Der Body wird im Speicher gesammelt (Vapor `collect`), daher die harte Obergrenze; Reverse-Proxy-Limit entsprechend setzen.
- SHA-256, Größe und Magic Bytes werden wie bisher bei Upload, Abschluss und jedem Abruf geprüft. Der Abruf liest alle Blöcke, prüft das Ganze und antwortet dann; Bytes-Ranges (`Range: bytes=…`, ein Bereich, 206/416, `Accept-Ranges: bytes`) werden aus den geprüften Bytes geschnitten. Echtes Streaming ohne vollständige Prüfung gibt es bewusst nicht (bei Dateien bis 10 MiB vertretbar; bei größeren Limits wächst der Speicherbedarf je Abruf).
- Mehrere Replikate: Zustand liegt vollständig in der Datenbank. Upload, Abschluss, Abbruch, Cleanup und Migration sperren die `attachments`-Zeile (`FOR UPDATE`) in fester Reihenfolge. `DELETE` auf `attachment_blobs` läuft nur, wenn Zeilen existieren; ein `DELETE` über einen leeren Schlüsselbereich nimmt InnoDB-Gap-Locks und führte beim parallelen Upload verschiedener Anhänge zu Deadlocks (im Test beobachtet und behoben).
- Löschen: Abbruch, `cleanup-uploads` (abgelaufene Uploads, Anhänge gelöschter Aufgaben) und Fremdschlüssel-Kaskade entfernen die Blöcke; es gibt keine verwaisten Blobs ohne Metadatenzeile.
- Migration `AddAttachmentBlobStorage` (additiv: neue Spalte mit Default, neue Tabelle; `LONGBLOB` auf MariaDB, SQLite behandelt es als BLOB).
- Admin-Befehl `App attachments migrate-storage --from s3|database --to database|s3 [--dry-run] [--delete-source]`. Kopiert nur vollständige Anhänge sichtbarer Aufgaben, prüft jede Datei (Größe, Medientyp, SHA-256) und schaltet die Zeile erst nach erfolgreichem Schreiben um. Idempotent und wiederholbar: bereits umgestellte Zeilen werden nicht erneut gewählt, ein halb geschriebenes Ziel wird überschrieben. Die Quelle bleibt ohne `--delete-source` erhalten. Fehlerhafte Dateien werden gelistet, der Befehl endet dann mit Fehler. Dieselbe Funktion deckt beide Richtungen ab.

## Folgen und Grenzen

- Datenbankgröße und Sicherung wachsen mit den Anhängen. `scripts/backup-db.sh` sichert sie mit; ein separates Bucket-Backup entfällt, solange S3 nicht benutzt wird.
- Die Datenbank hält während Upload/Abruf eine Verbindung; Dateien im zweistelligen MiB-Bereich sind für diesen Weg nicht gedacht. Für große Datenmengen ist S3 der vorgesehene optionale Weg.
- Nicht geprüft: echter Betrieb mit großen Datenmengen, Last, `max_allowed_packet` kleiner als 2 MiB, Galera/Replikation der Datenbank, Echt-S3 (nur S3Mock, wenn Umgebungsvariablen gesetzt sind).
