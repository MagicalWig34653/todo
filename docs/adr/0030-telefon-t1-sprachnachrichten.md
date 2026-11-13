# ADR 0030 – Telefon T1: Sprachnachrichten an das Brain

Status: Vorschlag (11.11.2026). Schritt 1 (Audio-Anhänge, Rolle `voice`, Limits) umgesetzt am 13.11.2026, der Rest nicht. Umsetzungsschritte: [PLAN-TELEFON-T1.md](../PLAN-TELEFON-T1.md). Nummer 0030, weil 0029 im Hauptstand bereits vergeben ist (dieser Worktree basiert auf einem Stand bis 0028).

## Kontext

Nutzerentscheidung (Lino, 11.11.2026, Quelle: `orchestrator/PLAN-TELEFON.md`, „Gewählter Weg“): Statt SIP/Telefonnetz telefoniert Lino über die Todolino-App mit dem Brain. Stufe T1 ist „Walkie-Talkie“: Taste halten, sprechen, Aufnahme geht an einen Mac-Runner, Antwort kommt als Text und Audio zurück. Keine Echtzeit. Festlegungen: Spracherkennung und Sprachausgabe laufen dauerhaft **lokal auf dem Mac** (Cloud-Server ohne GPU); ist der Mac offline, gibt es nur Text bzw. Push („Brain gerade nur per Text erreichbar“). Am Telefon gelten die Rechte der App; keine Shell, keine Deploys. T2 (WebRTC-Anruf) und T3 (VoIP-Push/CallKit) sind nicht Teil dieser ADR.

Vorhandene Bausteine (Code/ADR geprüft): Runner-Geräte mit Einmalkopplung und gehashtem Geräte-Token, Lease/Generation-Fencing und Checkpoints (ADR 0008, `Sources/TodoKit/Agents`); Anhänge mit Begin/PUT/Complete, Magic-Byte-Prüfung, SHA-256, Limit 10 MiB, Speicher in Datenbank oder S3 (ADR 0006, 0013, `contracts/attachments.yaml`; heute nur PNG/JPEG/WebP/PDF); Aufgabenchat und Projektkommentare (`contracts/collaboration.yaml`, `AttachmentChat.swift`); MCP-Scopes `comments:write`, `attachments:read`, `agents:read` (ADR 0007, 0026, 0028). **Nicht vorhanden:** ein Konzept „Kanal“ (#brain), eine Fähigkeitsliste am Runner-Gerät (`RunnerDevice` kennt keine Capabilities) und Audio-Medientypen. Beides ist neu und Teil dieser ADR.

## Entscheidung

1. **Aufnahme und Upload.** Die App (iPhone zuerst; PWA später) nimmt AAC/M4A mono auf (Push-to-talk, Obergrenze 120 s) und lädt die Datei über den bestehenden Anhangsweg (Begin/PUT/Complete) hoch. Neu: Medientypen `audio/mp4` (M4A) und `audio/wav` mit Magic-Byte-Prüfung, eigene Rolle `voice`, eigenes Limit (Vorschlag 5 MiB bzw. 120 s Dauer, serverseitig aus Container-Metadaten geprüft, sonst 413/422).
2. **Kanal #brain.** Neue Ressource „Kanal“ (kontobezogen, Typ `brain`), mit Nachrichten (`kind`: `text`, `voice_in`, `voice_out`, `status`). Ein Kanal pro Konto, nur der Besitzer liest/schreibt. Kein Aufgaben- oder Projektbezug nötig; ein späterer Bezug (Nachricht erzeugt Karte) läuft über normale MCP-Werkzeuge des Brain, nicht über den Kanal. Abgrenzung: kein Discord-Klon, kein allgemeines Chatsystem (siehe PLAN-TELEFON, Festlegungen).
3. **Server-Auftrag.** Eine `voice_in`-Nachricht erzeugt einen `VoiceJob` (eigener Datensatz, Zustände `queued → claimed → done | failed | expired`, Idempotenzschlüssel = Client-UUID wie ADR 0008). Der Auftrag trägt `required_capability = "sprache"`, Anhangs-ID, Konto-ID. Er ist **kein** Agentenauftrag aus ADR 0008 (kein Repository-Platz, keine Review-Pflicht), nutzt aber dieselbe Gerätekopplung, Lease (kürzer, 60 s) und Generation.
4. **Fähigkeit „sprache“.** `RunnerDevice` erhält additiv `capabilities` (Liste, vom Runner beim Heartbeat gemeldet, vom Besitzer in der PWA abschaltbar). Der Server vergibt Sprachaufträge nur an Geräte des Kontos mit „sprache“ und frischem Heartbeat. Gibt es keins, antwortet der Server sofort mit einer `status`-Nachricht „Brain gerade nur per Text erreichbar“ und sendet optional Push; der Auftrag läuft nach 10 Minuten ab (`expired`), die Aufnahme wird gelöscht.
5. **Runner-Verarbeitung (ausschließlich lokal).** Runner lädt die Audiodatei über einen Gerätetoken-Download, prüft SHA-256, transkribiert lokal, ermittelt die Antwort (T1: Transkript als Text an das Brain bzw. Lage-Antwort über das vorhandene Board/MCP; die Brain-Anbindung ist Schnittstelle, nicht Teil des Sprachadapters), erzeugt Audio per lokaler deutscher TTS und lädt Transkript, Antworttext und Antwortaudio hoch. Der Runner spricht nur über die Runner-API und führt keine Shell-Aktionen aus Sprachbefehlen aus.
6. **Rückweg.** Antwort wird als `voice_out`-Nachricht (Text + Audioanhang `audio/mp4`) in #brain gespeichert; die App spielt sie ab und zeigt beide an. Live-Refresh (ADR 0022) und Push (ADR 0021) melden das Eintreffen.
7. **Sprach-Engine als Adapter.** Der Runner kapselt STT und TTS hinter zwei kleinen Schnittstellen (`transcribe(file, language) -> text`, `synthesize(text, voice) -> audio`), Implementierung per lokalem HTTP-Aufruf oder Prozessaufruf. Empfehlung: **Standardweg ohne VoiceStudio** (whisper.cpp oder WhisperKit für STT; Apple `AVSpeechSynthesizer` bzw. Piper für TTS). VoiceStudio bleibt **optionaler, getrennt installierter Dienst** hinter derselben Schnittstelle, nur wenn Lino ihn ausdrücklich will (z. B. für bessere Stimmen).

## Alternativen (Sprach-Engine)

Geprüft am 11.11.2026 über Repository-Seiten und Doku (nichts installiert oder ausgeführt).

**VoiceStudio** (github.com/debpalash/voicestudio): Electron-Desktop-App mit Python-Backend; Sprachklonen, Stimmdesign, Dubbing, Diktat, Transkription (STT), Hörbuch/Narration (TTS), „646 Sprachen“; Standardmodell OmniVoice. Lokale API auf Port 3900: OpenAI-kompatibles `POST /v1/audio/transcriptions`, WebSocket-Streaming, MCP (Streamable HTTP `/mcp/`, stdio-Shim) mit Werkzeugen `transcribe`, `generate_speech`, `list_voices`, `list_languages`. Apple Silicon: Metal (MPS) „stable“ ab macOS 13.3. Lizenz AGPL-3.0-only (Copyright Palash Debnath, Pflege durch Yupcha Softwares Pvt Ltd, CLA; kommerzielle Doppellizenz und Pro-Funktionen kostenpflichtig). Reife: 108 233 Sterne, 11 996 Forks, 16 offene Issues, 30 Beitragende, Repository angelegt 9.4.2026, letzter Push 11.11.2026, Release v0.5.7 (26.10.2026), also Vor-1.0 und sehr schnell veränderlich; die Sternezahl im Verhältnis zum Alter ist ungewöhnlich und wurde nicht verifiziert. Offene Issues zeigen Installations-, Signatur- und Engine-Probleme sowie einen Aufräumvorschlag für ca. 210 000 Zeilen ungenutzten Codes.
- Vorteile: STT und TTS aus einer Hand, lokale API und MCP fertig, Metal-Beschleunigung, aktive Pflege.
- Nachteile: großes, schnell wanderndes Paket (Electron + Python + Modelle); Sicherheitsmodell der API nur teilweise belegt (Loopback ohne Credentials, Bearer-Key u. a. im Docker-Beispiel, LAN-Freigabe per PIN über unverschlüsseltes HTTP, MCP-Transport laut Doku selbst nicht authentifiziert, Host-Header-Prüfung vorhanden); Deutsch als Qualitätsmerkmal nirgends belegt (nur „646 Sprachen“, README auf Deutsch vorhanden); Gewichte des Standardmodells CC-BY-NC (nicht kommerziell), weitere Modelle uneinheitlich, laut Lizenzhinweis keine kommerzielle Freigabe; gebündeltes FFmpeg/PyAV mit teils ungeklärten Weitergabepflichten; AGPL (siehe unten).

**whisper.cpp / WhisperKit (nur STT).** whisper.cpp (MIT, C++, Metal/Core ML) oder WhisperKit (MIT, Swift, Core ML). Vorteile: Deutsch gut belegt (z. B. `large-v3-turbo`, `small`), klein, permissive Lizenz, ohne Netz, passt zu einem Swift-Runner (WhisperKit) und zu Linos Vorgabe „Whisper (mlx)“ (mlx-whisper als Python-Variante). Nachteile: nur STT; Modell-Download und Latenz bei langen Clips je nach Modell. (Aus eigenem Wissen, nicht neu geprüft.)

**Apple `AVSpeechSynthesizer` (TTS).** In macOS eingebaut, deutsche Systemstimmen (auch nachladbare Enhanced/Premium), keine Zusatzabhängigkeit, keine Lizenzfrage. Vorteile: einfach, offline, stabil. Nachteile: Klang schlechter als neuronale Stimmen; Dateiausgabe über `write(_:toBufferCallback:)` mit Eigenheiten; nur macOS.

**Piper (TTS).** Lokales neuronales TTS, deutsche Stimmen vorhanden (z. B. thorsten), schnell auf CPU. Vorteile: natürlicher als Systemstimme, klein. Nachteile: eigener Prozess; Lizenz von Code und Stimmen je Stimme prüfen (Code zuletzt unter GPL-3.0 geführt, vor Einsatz klären); Aussprache von Anglizismen mittel.

**Apple `SFSpeechRecognizer`:** nur Notlösung; kann Audio in die Cloud senden, `requiresOnDeviceRecognition = true` wäre Pflicht. Nicht empfohlen.

**Empfehlung:** STT = whisper.cpp oder WhisperKit, TTS = zuerst `AVSpeechSynthesizer`, optional Piper. VoiceStudio **nicht als Pflicht**, sondern austauschbarer Dienst hinter dem Adapter; Entscheidung dafür erst nach Hörprobe und Lizenzfreigabe der gewählten Stimme (offene Frage 1).

## Lizenzfolgen VoiceStudio (AGPL-3.0)

- Zulässig und empfohlen: VoiceStudio unverändert als **eigener Prozess/Dienst** betreiben und nur per HTTP/MCP ansprechen. Das ist Nutzung, kein Linken oder Einbetten; Todolino-Code bleibt davon unberührt (Einschätzung des Teams, keine Rechtsberatung).
- Verboten für Todolino: Code, Bibliotheken oder Python-Pakete von VoiceStudio in Backend, Runner-Binary oder Apps einbinden, Quellen kopieren, den Dienst in dasselbe Binary/Paket linken.
- Eigene Änderungen an VoiceStudio, die Dritten über ein Netz zugänglich sind, müssten unter AGPL offengelegt werden. Todolino nutzt es nur lokal für das eigene Konto; trotzdem keine Änderungen vornehmen.
- **Verteiltes Runner-Paket:** Wird der Todolino-Runner an andere ausgeliefert, darf VoiceStudio nicht mitgeliefert oder gebündelt werden (sonst Weitergabepflichten: AGPL-Quelle, Lizenztext, Modell- und FFmpeg-Hinweise; Standardgewichte CC-BY-NC verbieten kommerzielle Nutzung). Der Runner dokumentiert VoiceStudio nur als optionale, vom Nutzer selbst installierte Engine mit Verweis auf dessen Lizenz; der Adapter spricht eine generische Schnittstelle (OpenAI-kompatible Transkription, einfaches TTS-JSON), keinen VoiceStudio-spezifischen Code. Die Standardauslieferung nutzt MIT-lizenzierte oder Systemkomponenten.
- Vor geschäftlicher Nutzung: Gewichtelizenzen je gewählter Stimme/Modell prüfen.

## Datenfluss

```
iPhone-App ──(1) Begin/PUT/Complete: Audio-Anhang (Rolle voice, audio/mp4, <=120 s)──► Server
        └─(2) POST /v1/channels/brain/messages {voice_in, attachmentID, clientUUID} ──► Server
Server: legt VoiceJob an; Gerät mit „sprache“ und frischem Heartbeat?
   ja   ─► Job queued
   nein ─► status-Nachricht „Brain gerade nur per Text erreichbar“ (+ Push)
Mac-Runner: (3) Claim (Lease 60 s) ─► (4) Audio laden (Gerätetoken) ─► (5) STT lokal ─► Transkript
            (6) Antworttext (Brain/Lage über Runner-API/MCP) ─► (7) TTS lokal ─► Antwortaudio
            (8) Ergebnis hochladen: Transkript, Antworttext, Audio
Server: speichert voice_out in #brain, löscht Eingangsaudio nach Frist, Live-Refresh + Push
App: spielt Audio ab, zeigt Text
```
Fehlerfälle: Runner verliert Lease (Job wird neu vergeben, Generation fenced); STT/TTS-Fehler (`failed` mit Code, Textnachricht an die App); Mac offline (siehe Entscheidung 4); Doppel-Upload (Idempotenz über Client-UUID und SHA-256).

## Datenschutz

- **Nur lokal verarbeiten:** Kein Cloud-STT, keine Cloud-TTS, keine Weitergabe von Audio an Dritte (auch nicht an die Claude-API); an das Brain geht ausschließlich Text. Der Runner meldet seine Engine; Konfigurationen mit Netzzugriff (z. B. `SFSpeechRecognizer` ohne On-Device-Pflicht) sind unzulässig.
- **Einwilligung:** Beim ersten Gebrauch erklärt die App in einem Dialog Mikrofonnutzung, Speicherung auf dem eigenen Server, lokale Verarbeitung auf dem Mac und Löschfristen; die Einwilligung wird je Konto gespeichert (Zeitpunkt, Textversion) und ist widerrufbar (Funktion aus, Audiodaten löschen). iOS-Mikrofonberechtigung mit eigenem Verwendungszweck-Text. Hinweis auf Dritte im Hintergrund. Gesundheitsdaten (Art. 9) gehören nicht ans Telefon (Festlegung PLAN-TELEFON); der Dialog nennt das.
- **Aufbewahrung (Vorschlag, mit Lino zu bestätigen):** Eingangsaudio wird nach erfolgreicher Verarbeitung, spätestens nach 24 Stunden, serverseitig gelöscht; optional „Audio behalten“ je Konto bis 30 Tage. Transkript und Antworttext bleiben als Kanalverlauf bis zur Löschung durch den Besitzer. Antwortaudio 7 Tage. Fehlgeschlagene/abgelaufene Aufträge: Audio sofort. Der Runner behält keine Audiodateien (Temp-Datei nach Abschluss löschen, im Test geprüft). Löschung läuft im bestehenden Cleanup (ADR 0019) und bei Konto-Anonymisierung/-Export (`/v1/me/export`, `/v1/me/anonymize`): Kanalnachrichten sind im Export enthalten, Audio nach Wahl.
- **Speicherort:** Audio nutzt den Datenbank-Anhangsspeicher (ADR 0013); Datenbankgröße und Backup (`scripts/backup-db.sh`) beachten, kurze Fristen halten sie klein. Backups enthalten Audio bis zur Rotation; im Datenschutztext benennen.
- **Protokolle:** Keine Transkripte oder Audioinhalte in Server-/Runner-Logs; nur IDs, Größen, Dauern, Fehlercodes.

## Sicherheit

- **Rechte:** Nur das Konto selbst nimmt Sprachaufträge an; Kanal #brain ist kontobezogen (kein Teilen, kein Team). Neue MCP-/OAuth-Scopes `channels:read`, `channels:write`; ohne sie sehen Agenten den Kanal nicht. Sprachaufträge laufen mit denselben Rechten wie die Person in der App; Aktionen des Brain gehen durch die normalen Dienste (Risikoklassen A/B/C aus `docs/MCP-PARITAET.md`; Klasse C weiterhin nur per Bestätigungsanfrage in der App, nie per Sprache allein).
- **Auth Runner:** vorhandenes Geräte-Token (Hash in DB), Gerät gehört dem Konto, widerrufene Geräte können nichts. Neue Runner-Routen `/v1/runner/voice/*` (Claim, Heartbeat, Download, Ergebnis) prüfen Gerät, Konto, Lease und Generation (409/410 wie ADR 0008). Audio-Download nur für das claimende Gerät, nur während gültiger Lease.
- **Mandanten:** Jeder Voice-Datensatz trägt die Konto-ID; Abfragen filtern immer darauf; fremde IDs ergeben 404. Test: zwei Konten, zwei Geräte, kein Übergreifen.
- **Limits:** Audio <= 120 s und <= 5 MiB (Vorschlag, separat konfigurierbar), 1 laufender Auftrag je Konto, Rate-Limit (z. B. 10 Aufnahmen/Minute, 200/Tag), Antworttext <= 4000 Zeichen, Antwortaudio <= 120 s, <= 5 offene Aufträge. Format- und Containerprüfung vor Annahme; der Runner behandelt Audio als nicht vertrauenswürdige Eingabe (Decoder/Engine mit Zeitlimit).
- **Prompt-Injection:** Transkripte sind Nutzereingabe, keine Systemanweisung; Umgebungsgeräusche oder fremde Sprecher könnten Befehle auslösen: deshalb keine Klasse-C-Aktion und keine Shell per Sprache.
- **Lokale Engines/VoiceStudio:** nur an `127.0.0.1` binden, API-Key setzen, LAN-Freigabe aus, kein Reverse-Proxy; der Runner meldet „sprache“ nur, wenn die Engine auf Loopback erreichbar ist. Hinweis: Loopback ohne Credentials bedeutet, dass jeder lokale Prozess auf dem Mac den Dienst nutzen kann.
- **Transport:** TLS wie überall; Audio nie in URLs.

## Konsequenzen

- Neue Tabellen `channels`, `channel_messages`, `voice_jobs`, `voice_consents`; additive Spalte `runner_devices.capabilities`; neue Anhangsrolle `voice` und Audio-Medientypen (additive Migration, `App migrate --yes`). Verträge: neue `contracts/voice.yaml`, Ergänzungen in `attachments.yaml`, `agents.yaml` (Capabilities), `oauth-mcp.yaml` (Scopes), `docs/agent-manual.md`, `docs/MCP-PARITAET.md` (Tools `list_channel_messages`, `post_channel_message`).
- Runner-Repo (Mac): neuer Sprach-Worker mit Engine-Adapter; Mac muss laufen und wach sein (bekannte Grenze).
- Lokale Modellinstallation nötig (Whisper-Modelle grob 0,5 bis 1,6 GB je Variante).
- App: Mikrofonrecht, Aufnahme-/Wiedergabe-UI, Offline-/Fehlerzustände.
- Kein Einfluss auf ADR 0008: Agentenaufträge bleiben getrennt.

## Offene Fragen

1. VoiceStudio nur optional (Empfehlung) oder gar nicht? Hörprobe deutscher Stimmen (System/Piper/VoiceStudio) durch Lino.
2. Aufbewahrungsfristen (24 h Eingang, 7 Tage Antwort) und optionale Audiospeicherung bestätigen.
3. Wie entsteht der Antworttext: Brain-Session per Board/MCP (asynchron, Latenz Minuten) oder lokales Modell (LM Studio) für kurze Lagefragen? T1-Vorschlag: Lage-Antwort lokal, Brain asynchron.
4. Kanal als eigene Ressource (empfohlen) oder vorerst Projektkommentare eines festen Projekts „Brain“ (schneller, weniger sauber)?
5. WhisperKit im Runner-Prozess oder whisper.cpp/mlx als Subprozess? Hängt vom Runner-Stack ab (nicht geprüft).
6. Mehrere Macs mit „sprache“: Auswahlregel (zuletzt aktiv, Priorität).
7. Aufnahme in der PWA (MediaRecorder liefert WebM/Opus, nicht M4A) in T1 oder später?
8. Datenschutzerklärung und Einwilligungstext juristisch prüfen.
