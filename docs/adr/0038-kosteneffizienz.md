# ADR 0038: Kosteneffizienz (Nutzungsmeldung und Kennzahlen)

Stand 27.11.2026, Karte `71FD73CF`, Phase 1 (Server). Vertrag: `contracts/usage.yaml`.

## Entscheidungen

- **Nur Aggregate:** Zählerstände und Kennungen, keine Prompts, Titel, Pfade oder Namen; unbekannte Felder werden abgelehnt.
- **Eigentum je Konto:** Zeilen, Preise und Schwellen gehören dem meldenden Konto, niemand sieht fremde. Ein Projekt wird nur zugeordnet, wenn das Konto es lesen darf (MCP: zusätzlich im Grant). Das Leserecht wird beim Lesen erneut geprüft; die Antwort verrät nicht, ob ein Projekt existiert.
- **`tasks:write` statt neuem Scope:** Der Sammler läuft mit der bestehenden Verbindung, kein neuer Consent. Lesen und Einstellungen gibt es nur per REST mit Personen-Sitzung.
- **Idempotenz durch Ersetzen:** eindeutiger Schlüssel (Konto, Tag, Sitzung, Modell). Meldungen eines Kontos laufen unter einer Zeilensperre auf `users` (MariaDB) bzw. in der Schreibtransaktion (SQLite) nacheinander.
- **Kosten beim Lesen:** Es werden keine Beträge gespeichert; korrigierte Preise wirken rückwirkend.
- **Ein Kalendertag als Auflösung:** „24 h“ ist ein Tag in der Zeitzone des Sammlers.
- **Erledigte Karten näherungsweise:** Status erledigt und `updated_at` im Fenster (wie Übersicht „Jetzt“). Eine spätere Änderung verschiebt die Karte in ein anderes Fenster.
- **Keine Standardpreise für Codex/GPT:** nicht belegt; das Konto trägt sie ein, bis dahin stehen die Modelle in `unpricedModels`.

## Folgen

- Additive Migration `CreateUsage` (`usage_daily`, `usage_settings`); ASCII-Spalten mit `ascii_bin`, damit der Schlüssel unter MariaDB kurz bleibt und Groß-/Kleinschreibung wie unter SQLite zählt.
- Kontolöschung und Anonymisieren entfernen beide Tabellen; Projektlöschung setzt `project_id` auf NULL; Projektübertragung ändert nichts.
- Der Datenexport enthält `usage` und `usageSettings`. Er zählt zur 20-MB-Grenze; sehr lange Historien könnten sie erreichen.
- Keine Aufbewahrungsfrist; Befunde, Regeln und `list_cost_findings` folgen in Phase 3.
