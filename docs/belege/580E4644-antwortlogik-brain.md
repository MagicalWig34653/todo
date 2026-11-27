# Beleg Karte 580E4644: T1-5 Antwortlogik Brain (Text, T1-Minimum)

Stand 27.11.2026, Erwartung f-3999655d. Kein Deploy.

## DoD

1. Rote Tests zuerst: `048ab31`, `swift test --filter VoiceBrainReplyTests`: 6 Tests, 30 Fehler (404 statt Funktion; Lage-Antwort `intent` nil, Klasse-C `refused` nil, Wortregeln Stub). Nach Gegenlesen `0dc735c`: 9 Tests, 16 Fehler.
2. Umsetzung grün: `a048e80`, `2c205ad`. `VoiceBrainReplyTests` 9/9. E2E über REST und MCP (`scripts/voice-brain-e2e.sh`, native Backend, frische SQLite, zwei Konten, echter Runner-Token, echte M4A, echtes OAuth-Token): 25 ok, `voice_in` mit Transkript per `list_channel_messages` gelesen, kein Transkript oder Antworttext im Backend-Log. Nachbarn: `voice-jobs` 88, `channel-brain` 46, `voice-attachments` 29 ok.
3. Suiten auf `2c205ad`: SQLite 1080, 26 übersprungen, 0 Fehler. MariaDB 12.3.3 1080, 9 übersprungen, 0 Fehler (eigener Wegwerf-Container wie `scripts/test-mariadb.sh`, zwei Teile: 603 + 477). GitHub-CI: siehe STATUS.
4. STATUS, `docs/PLAN-TELEFON-T1.md` Schritt 5, ADR 0030 Nachtrag, `contracts/voice.yaml` 1.3.0, Handbuch 1.51.0.

## Board-Texte (Todolino-MCP nicht angemeldet, vom Brain einzutragen)

**post_progress**
- Schritt 5 fertig: `POST /v1/runner/voice/jobs/{id}/transcript`; Lage-Antwort aus Command Center und offenen Fragen (≤ 4000); Klasse C wird per Sprache nie ausgeführt; Rest wartet im Kanal #brain.
- Rot `048ab31`, `0dc735c`; grün `a048e80`, `2c205ad`. SQLite und MariaDB je 1080, 0 Fehler. Kein Deploy.
- Offen: Schritt 4 (Runner, anderes Repo; muss `/transcript` vor der Sprachausgabe rufen), Schritt 6 (App).
- Lehre: Volle MariaDB-Suite dauert gedrosselt über 60 min; Gegenlesen vor den Vollsuiten starten (hier ein Neustart, 38 min verloren), dann in zwei Datenbanken parallel.

**record_decision** (Commit `a048e80`)
- Entscheidung: Ein gesprochener Klasse-C-Wunsch erzeugt keine Bestätigungsanfrage, nur den Hinweis auf die App.
- Begründung: Plan erlaubt „höchstens eine“; Sprache hat keine Verbindung (Grant), ein falsch verstandener Name soll keine Löschung vorbereiten.
- Prüfbar: „Lösche Projekt X“ sprechen: Projekt bleibt, keine offene Bestätigungsanfrage, Antwort verweist auf die App.

**Review:** keines nötig (nichts Sichtbares anzusehen; Entscheidung oben im Journal).
