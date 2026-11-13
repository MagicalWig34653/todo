# Plan Telefon T1: Sprachnachrichten an das Brain

Stand 11.11.2026, Vorschlag. Grundlage: [ADR 0030](adr/0030-telefon-t1-sprachnachrichten.md) (Status Vorschlag). Nichts davon ist implementiert. Worker-Typen: swift (Backend/Runner), svelte (PWA), swiftui (App). Der Mac-Runner liegt außerhalb dieses Repos; Schritt 4 wird dort umgesetzt (anderes Repo, vorher klären).

Vorbedingung: ADR 0030 angenommen, offene Fragen 1 bis 4 beantwortet.

## Schritte

### 1. Audio-Anhänge und Voice-Limits (Backend) – umgesetzt 13.11.2026 (Branch `agent/t1-1-audio-anhaenge`)
Worker: swift. Aufwand: S. Abhängigkeiten: keine.
- `audio/mp4` (M4A) und `audio/wav` werden mit Magic-Byte-Prüfung als Anhang mit Rolle `voice` angenommen; andere Audio-Typen ergeben 415.
- Dauer über 120 s oder Größe über 5 MiB wird mit 413/422 abgelehnt; Test mit Grenzwerten.
- Download liefert `private, no-store`; fremdes Konto erhält 404; `contracts/attachments.yaml` ist angepasst.

### 2. Kanal #brain: Datenmodell, REST, MCP
Worker: swift. Aufwand: M. Abhängigkeiten: 1.
- `channels` und `channel_messages` (text, voice_in, voice_out, status) per additiver Migration; genau ein Kanal `brain` je Konto, nur der Besitzer liest und schreibt (Mandantentest mit zwei Konten).
- REST `GET/POST /v1/channels/brain/messages` mit Idempotenz über Client-UUID und Pagination; Vertrag in `contracts/voice.yaml`.
- MCP-Werkzeuge `list_channel_messages` und `post_channel_message` mit neuen Scopes `channels:read`/`channels:write`; `docs/agent-manual.md` und `docs/MCP-PARITAET.md` aktualisiert.

### 3. Sprachaufträge und Runner-Fähigkeit „sprache“ (Server)
Worker: swift. Aufwand: L. Abhängigkeiten: 2.
- `runner_devices.capabilities` (vom Runner gemeldet, in der PWA abschaltbar) und `voice_jobs` mit Zuständen queued, claimed, done, failed, expired.
- Runner-API `/v1/runner/voice/*` (Claim, Heartbeat, Audio-Download, Ergebnis) mit Geräte-Token, Lease 60 s und Generation (falsche Generation 409, abgelaufen 410); Test: ein zweiter Runner kann denselben Auftrag nicht übernehmen.
- Ohne Gerät mit „sprache“ und frischem Heartbeat entsteht sofort eine `status`-Nachricht „Brain gerade nur per Text erreichbar“; Aufträge verfallen nach 10 Minuten; Limits (1 laufender Auftrag, Rate-Limit) sind getestet.

### 4. Runner-Sprach-Worker (Mac, Engine-Adapter)
Worker: swift (Runner-Repo). Aufwand: L. Abhängigkeiten: 3.
- Runner meldet „sprache“ nur, wenn STT-Modell und TTS verfügbar sind; Audio wird lokal transkribiert (Deutsch, whisper.cpp oder WhisperKit) und mit lokaler deutscher Stimme gesprochen (AVSpeechSynthesizer, optional Piper); ein Test belegt, dass für Audio kein Netzwerkzugriff erfolgt.
- Ergebnis (Transkript, Antworttext, Antwortaudio) wird hochgeladen; Eingangs- und Zwischendateien sind nach Abschluss oder Fehler gelöscht (Test).
- Engine-Adapter ist austauschbar (HTTP/Prozess); VoiceStudio nur optional und nicht gebündelt; Dokumentation nennt Loopback-Bindung und API-Key.

### 5. Antwortlogik Brain (Text, T1-Minimum)
Worker: swift. Aufwand: M. Abhängigkeiten: 3 (parallel zu 4 vorbereitbar).
- Das Transkript erscheint als `voice_in` mit Text im Kanal; eine Lage-Anfrage („wie steht es“) wird aus Command Center und offenen Fragen beantwortet (Text, höchstens 4000 Zeichen).
- Sprachbefehle lösen keine Aktionen der Klasse C aus; Test: „lösche Projekt X“ erzeugt höchstens eine Bestätigungsanfrage in der App.
- Anfragen an die Brain-Session liegen als Kanalnachricht lesbar bereit (`list_channel_messages`).

### 6. App: Aufnahme, Einwilligung, Wiedergabe
Worker: swiftui. Aufwand: L. Abhängigkeiten: 2, 3 (Mock bis 4 fertig ist).
- Einwilligungsdialog beim ersten Gebrauch (Mikrofon, lokale Verarbeitung, Fristen) wird je Konto gespeichert und ist widerrufbar; Mikrofonberechtigung mit deutschem Verwendungszweck.
- Taste halten nimmt M4A mono auf (max. 120 s, Abbruch per Wischen), lädt hoch und zeigt Zustände (sendet, verarbeitet, Antwort, Fehler, „nur per Text erreichbar“).
- Die Antwort wird als Text und Audio im #brain-Verlauf angezeigt und abgespielt; bedienbar mit VoiceOver; Verlauf lädt per Live-Refresh/Push nach.

### 7. Datenschutz: Aufbewahrung, Löschen, Export, Einstellungen
Worker: swift (Backend), svelte (PWA-Einstellungen). Aufwand: M. Abhängigkeiten: 3.
- Cleanup löscht Eingangsaudio nach Verarbeitung, spätestens nach 24 h, Antwortaudio nach 7 Tagen, fehlgeschlagene Aufträge sofort (Test mit Zeitverschiebung); optional „Audio behalten“ bis 30 Tage.
- Konto-Export enthält Kanalnachrichten; Anonymisierung entfernt Audio und Kanalinhalte; PWA-Seite „Daten & Datenschutz“ zeigt Einwilligung, Fristen und „Sprachverlauf löschen“.
- Keine Transkripte oder Audioinhalte in Logs (Stichprobentest der Logausgabe).

### 8. PWA: #brain-Verlauf lesen (optional)
Worker: svelte. Aufwand: S. Abhängigkeiten: 2.
- Die PWA zeigt den Kanal #brain mit Text und Audio-Wiedergabe (Audioelement, Transkript sichtbar), tastaturbedienbar.
- Aufnahme in der PWA ist nicht Teil dieses Schritts (WebM/Opus).
- Playwright-Test für Laden, Wiedergabe-Steuerung und leeren Zustand.

## Reihenfolge
1, 2, 3, dann 4, 5 und 6 parallel, dann 7, dann 8. Erste Ende-zu-Ende-Demo nach 1 bis 4 und 6 (ohne Brain-Logik: Echo des Transkripts).

## Risiken
- Runner-Repo und Stack nicht geprüft; WhisperKit vs. whisper.cpp hängt davon ab.
- Latenz: kalter Modellstart, große Whisper-Modelle bei langen Clips. Gegenmaßnahme: Modell vorwärmen, Turbo-Variante.
- Mac schläft oder ist offline: Funktion nur bei wachem Mac; klare Statusmeldung nötig.
- Datenbankwachstum durch Audio (Anhänge in DB, ADR 0013); kurze Fristen und Limits.
- Datenschutz/Einwilligung rechtlich ungeprüft; Audio in Backups.
- Falsche Transkripte (Eigennamen, Fachwörter) führen zu falschen Aufträgen: Aktionen nur mit Bestätigung.
- Fremde Sprecher oder Umgebung lösen Befehle aus (Prompt-Injection per Sprache).
- VoiceStudio: AGPL (kein Bündeln/Linken, nur getrennter Dienst), Gewichte CC-BY-NC, junge schnell wechselnde Software, Loopback-API ohne Auth; deshalb nicht Standard.
- iOS: Hintergrundaufnahme, Audiosession-Konflikte, abgelehnte Berechtigung.
- Kanal als neues Konzept kann mit späterem Teamchat kollidieren: bewusst klein halten.

## Bewusst nicht in T1
- Echtzeit-Vollduplex, Unterbrechen, WebRTC (T2); „Jarvis ruft an“, VoIP-Push, CallKit (T3); SIP/Telefonnetz.
- Cloud-STT/-TTS, Sprachklonen, eigene Stimmen, Sprecherkennung oder PIN.
- Aktionen der Risikoklasse C, Shell, Deploys oder Repo-Arbeit per Sprache.
- Kanäle für Teams, mehrere Kanäle, Discord-ähnliche Funktionen, Aufnahme in der PWA, Apple Watch/CarPlay, Streaming-Transkription.
- Antwort des Brain in Echtzeit (T1 ist asynchron, „Walkie-Talkie“).

## Nicht geprüft
- Runner-Repository und tatsächlicher Runner-Stack; Brain-Anbindung (Session-Mechanik); Apple-Repo-Stand; Rechtslage Einwilligung/DSGVO; Hörqualität deutscher Stimmen; Latenzmessungen; VoiceStudio nicht ausgeführt (nur Doku und GitHub-Metadaten).
- `docs/AGENT-ARBEITSWEISE.md` existiert in diesem Repo nicht (Arbeitsweise steht in AGENTS.md und `docs/agent-manual.md`).
