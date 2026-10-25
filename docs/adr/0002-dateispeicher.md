# ADR 0002 – Dateispeicher: S3-kompatibel, S3Mock für Entwicklung und Tests

Status: angenommen (25.10.2026, Nutzerentscheidung).

**Entscheidung.** Anhänge liegen in einem S3-kompatiblen Speicher, den alle Replikate erreichen. Entwicklung und Tests verwenden Adobe S3Mock (`adobe/s3mock:5.2.3`, Bucket `todo-attachments`, Port 29090 lokal). Produktiv ist ein echter S3-kompatibler Dienst nötig; dessen Wahl ist offen.

**Grenzen.** S3Mock ist ein Testdouble und kein Betriebsnachweis. Ein eigenes `STORE_ROOT` auf einem Volume lieferte HTTP 500; die Standardablage funktioniert. Daten überleben dadurch keinen Containerneustart, was für Tests gewollt ist.
