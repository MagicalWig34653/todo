# ADR 0006 – REST-Anhänge mit Backend-Upload und gemeinsamem S3-Speicher

Status: umgesetzt, Infrastrukturabnahme offen (26.10.2026).

## Auftrag und Entscheidung

Nutzerauftrag: ausschließlich REST-Backend, keine MCP-/OAuth-, PWA- oder Apple-Implementierung. Dieser Arbeitsstand liegt im Hauptrepository auf `worktree-agent-a3e077ffb84e9c8a9`. Die Dateigrenzen des Auftrags haben Vorrang vor der allgemeinen Pflicht, den Arbeitsplan mitzuschreiben; der Checkpoint steht deshalb hier und im zusätzlich erlaubten Abschnitt „Anhänge“ in STATUS.md.

`Attachment` hält Aufgabe, Ersteller, Dateiname, Rolle (`reference`, `progress`, `result`), deklarierten und beim Upload/Abschluss geprüften Medientyp, Größe, SHA-256, Objektpfad und Zustand `pending`/`complete`. Kommentarverknüpfung bleibt späterer Migration vorbehalten. Anfangsgrenzen als Implementierungsannahme: 10 MiB, 15 Minuten Uploadgültigkeit, PNG/JPEG/WebP/PDF. Magic Bytes prüfen die Formatkennung, ersetzen aber keine vollständige Dekodierung oder Malwareprüfung. PDF erhält einen Download, keine Inline-Vorschau. Bildvorschauen liefern das geprüfte Original; Thumbnails folgen später.

`UploadSession` liegt gemeinsam in SQL, speichert nur den Hash des zufälligen Tokens, Ablauf und erfolgreichen Transfer. Begin erzeugt die beiden Datensätze transaktional. PUT benötigt ausschließlich den eng begrenzten Capability-Bearer; Cookie-Authentifizierung wird dort nicht verwendet. Token weder in URL noch in Logs schreiben. Andere Routen verwenden die bestehende Sitzung/CSRF-Prüfung. PUT prüft den ursprünglichen Ersteller über die aktuellen Aufgaben-/Projektrechte. Abschluss, Liste und Dateiabruf prüfen `ProjectAccess` für Aufgabe und aktuelles Projekt. Fremde und fehlende Objekte liefern 404. Erst ein erfolgreicher Abschluss macht Anhänge sichtbar; Abschluss ist wiederholbar. PUT ist einmalig nach erfolgreichem Transfer; nach unsicherem Transferergebnis kann der Client Abschluss versuchen.

MariaDB sperrt die Attachment-Zeile während Upload, Abschluss, Abbruch und Cleanup (einheitliche Sperrreihenfolge). S3-I/O liegt bewusst innerhalb dieser Transaktionen, damit ein zweites Replikat weder überschreibt noch gleichzeitig aufräumt. Das kostet eine DB-Verbindung während I/O; Timeout 30 Sekunden. DB- und S3-Transaktionen sind nicht atomar: ein unbestätigter PUT bleibt pending und kann erneut übertragen oder nach Ablauf gelöscht werden; ein erfolgter DELETE mit DB-Rollback wird idempotent wiederholt. Objekte werden ausschließlich unter serverseitigen UUID-Pfaden abgelegt.

Task-/User-Löschung lässt Attachment-Metadaten absichtlich bestehen, damit Cleanup auch verwaiste S3-Objekte kennt. Download bleibt nach Löschung gesperrt. `cleanup-uploads` und die gemeinsame Servicemethode entfernen abgelaufene pending-Uploads sowie Anhänge gelöschter Aufgaben. Erst S3 löschen, dann Metadaten; Fehler bleiben wiederholbar. Der Betreiber muss den CLI-Aufruf regelmäßig planen; kein Prozess-lokaler Timer oder automatischer Scheduler wird vorausgesetzt. Der erste Cleanup scannt alle Metadaten; Batch-/Indexoptimierung bleibt bei größerem Datenvolumen offen.

## Speicher und Konfiguration

Kleiner eigener Client auf Foundation URLSession und bestehendem Crypto, ohne neue Paketabhängigkeit; path-style URLs, SHA-256-Payload und optionale SigV4-Authentifizierung. Keine Redirects; ephemere Sessions ohne Cookie-/Cachepersistenz. Downloads erhalten `private, no-store`, `nosniff`, restriktive CSP und sicher kodierte Dateinamen. Es gibt keine öffentlichen Speicher- oder dauerhaften Vorschau-URLs.

Erforderlich: `S3_ENDPOINT`, `S3_BUCKET`; optional gemeinsam `S3_ACCESS_KEY`/`S3_SECRET_KEY`; `S3_REGION` standardmäßig `us-east-1`. Ohne Schlüssel wird unsigned angefragt; mit Schlüsseln wird signiert. Keine eingebauten Zugangsdaten. Produktiv HTTPS und private Bucket-Rechte konfigurieren. Temporäre AWS-Session-Credentials sind noch nicht unterstützt.

Entwicklung: `docker compose up -d s3`, `S3_ENDPOINT=http://127.0.0.1:29090`, `S3_BUCKET=todo-attachments`. Laut [Adobe-Dokumentation](https://github.com/adobe/S3Mock/blob/main/README.md) akzeptiert S3Mock beliebige SDK-Testcredentials und validiert presigned Signaturen nicht. Unsigned-Zugriff muss gegen den tatsächlich gestarteten Container geprüft werden; der aktuelle Sandbox-Aufruf scheitert am Docker-Socket und kann diese Prüfung nicht ersetzen. Signaturverfahren nach [AWS SigV4](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html); deterministischer Signaturtest mit öffentlichem AWS-Beispielschlüssel und unabhängig berechnetem Erwartungswert. Dieser Test belegt noch keine echte S3-Kompatibilität.

## Migration und Prüfplan

Neue Migration `CreateAttachmentSchema` mit `attachments` und `attachment_upload_sessions`, eigene eindeutige Objekt-/Token-/Zuordnungsconstraints, keine Änderung bestehender Tabellen. Migration wie bisher separat über `migrate --yes`, nie beim Replica-Start.

Vertrag: `contracts/attachments.yaml`. Testklasse `AttachmentTests`: Formatkennungen, Prüfsumme, Größen-/Typfehler, Tokenhash, unsichtbare pending-Uploads, Autorisierung, Ablauf und Signatur ohne S3. S3Mock-Integration mit getrennten Application-Instanzen auf gemeinsamer SQL-DB: Begin/PUT auf A, Abschluss/Download/Vorschau auf B, wiederholter Abschluss, Tokenwiederverwendung, fremder Zugriff, Abbruch, abgelaufene Uploads, Rechteänderung und Cleanup nach Task-Löschung. Ohne `S3_ENDPOINT` wird ausschließlich der S3-Test übersprungen.

Nächster Schritt: dokumentierte Testkommandos in einer Umgebung mit Docker-/Loopback-Zugriff ausführen; anschließend echtes S3 und Linux prüfen. MCP-Adapter, Kommentare, Thumbnailerzeugung und Endnutzerclients bleiben eigene Arbeitsaufträge.
