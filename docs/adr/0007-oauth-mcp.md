# ADR 0007 – OAuth und MCP

Stand: 26.10.2026. Umsetzung auf `worktree-oauth-mcp`, ohne Anhänge.

## Vorgaben und Recherche

Die aktuelle Spezifikation wurde vor Umsetzung per Websuche und anhand der Primärquellen geprüft:
- https://modelcontextprotocol.io/specification/latest leitet am Prüftag auf 2026-07-28 weiter.
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
- https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
- https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
- https://www.rfc-editor.org/rfc/rfc9728 (Resource-Metadaten)
- https://www.rfc-editor.org/rfc/rfc8414 (AS-Metadaten)
- https://www.rfc-editor.org/rfc/rfc7591 (Registrierung)
- https://www.rfc-editor.org/rfc/rfc8707 (Resource Indicators)

2026-07-28 ersetzt den Initialize-Handshake durch Metadaten pro Request und `server/discover`; Header werden zusätzlich mit dem Body abgeglichen. Die ausdrücklich gewünschte Initialize-Schnittstelle wird als Legacy-Profil 2025-03-26/2025-06-18/2025-11-25 implementiert. **Keine Behauptung vollständiger Konformität mit 2026-07-28.** Unbekannte Versionsheader werden abgewiesen. JSON-Antworten über Streamable HTTP ohne SSE-Stream und ohne Protokollsitzungen; GET liefert 405. OAuth-Zustand bleibt trotzdem vollständig persistent.

## Entscheidungen

- Backend enthält getrennte Authorization-/Resource-Server-Rollen. `OAUTH_ISSUER` ist die kanonische externe Basis-URL ohne abschließenden Slash; Standard ausschließlich für lokale Entwicklung `http://localhost:28080`. Resource ist exakt `<issuer>/mcp`. Produktion benötigt HTTPS und passende Proxykonfiguration. Host-Header bestimmen niemals die Audience.
- Öffentliche Clients mit RFC-7591-Registrierung, exakten Redirect-URIs und zwingendem PKCE S256. Nur HTTPS oder HTTP-Loopback-Redirects, keine Fragmente/Userinfo. Keine Client-Secrets. Client-ID-Metadatendokumente werden bewusst nicht abgerufen (SSRF-Fläche); DCR ist der unterstützte Registrierungsweg.
- Consent als authentifizierte JSON-API statt neuer Oberfläche: GET authorize zeigt Client, Redirect-Ziel, Scopes und verfügbare Projekte; POST consent benötigt einmaligen, an Benutzer und Anfrage gebundenen Consent-Token und explizite Projekt-IDs. Antwort enthält die Callback-URL für den aufrufenden Browserclient. Keine implizite Auswahl aller Projekte. Zustimmung und Ablehnung verbrauchen den Consent. Bestehende Cookie-/JSON-/Origin-Prüfung bleibt wirksam. Eine Browseroberfläche für diesen API-Vertrag ist noch erforderlich.
- Scopes `projects:read`, `tasks:read`, `tasks:write`. Exakte Projekt-IDs, keine automatische Vererbung auf Unterprojekte. Jede Objektoperation prüft zusätzlich den aktuellen `ProjectAccess`; Verschieben braucht beide Projektfreigaben. Fehlende und fremde Objekte sind gleich behandelt.
- Individuelle Grants mit eigener Widerruf-API. Opake Codes, Access-/Refresh-/Consent-Tokens werden nur als SHA-256-Hashes gespeichert. Client-/Anfragemetadaten sind keine Secrets. MariaDB hält alle Zustände, keine In-Memory-Sitzungen.
- Access 15 Minuten, Code 2 Minuten, Consent 5 Minuten, Refresh 30 Tage. Rotation sperrt die Grant-Zeile transaktional. Verbrauchte Codes und Refresh-Tokens bleiben für Replay-Erkennung erhalten; Wiederverwendung widerruft den gesamten Grant einschließlich bereits ausgestellter Access-Tokens. Widerruf bei Replay muss committen, bevor der Fehler zurückgeht. Scope-Erweiterung beim Refresh wird abgelehnt.
- Nur vorhandene Projekte-/Aufgabenfunktionen: list_projects, list_tasks, get_task, create_task, update_task. Keine Kommentare, Fortschritts-, Datei-, Shell- oder Runner-Werkzeuge. Aufgabenvalidierung und optimistische Versionierung entsprechen dem REST-Fachkern. Wegen der vorgegebenen Dateigrenzen kann dessen private Mutation nicht extrahiert werden; zentrale Rechteprüfung wird wiederverwendet.
- Migration separat in OAuth; je eine Registrierungszeile in Configure und Routes. Arbeitsplan wird gemäß expliziter Pfadbeschränkung nicht verändert; Checkpoint und nächster Schritt stehen hier und abschließend in STATUS, dessen übrige Abschnitte unverändert bleiben.

## Prüfstand

Implementierung und Prüfungen laufen. Der erste Swift-Aufruf scheiterte an der nicht beschreibbaren globalen Clang-Modulcache; erneuter Aufruf mit Cache unter /private/tmp und deaktivierter SwiftPM-Unterprozess-Sandbox. Testausgang und reale CLI-Prüfung werden vor Commit ergänzt. Protokolltests belegen allein keine reale Clientkompatibilität.
