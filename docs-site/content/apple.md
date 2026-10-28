# Apple: iOS, iPad, macOS, watchOS

Die nativen Apps (SwiftUI) liegen in einem separaten Repository und nutzen dieselbe API und dieselben Fachregeln wie die PWA. Die API-Verträge stehen im Hauptrepository unter `contracts/` (siehe [API-Verträge](api/index.html)). Diese Seite fasst den Stand der TestFlight-Vorbereitung zusammen; sie enthält keine Zugangsdaten.

## Screenshots

Echte Aufnahmen aus dem Simulator (Demo-Daten): siehe [Screenshots](screenshots.html).

## Bundle-IDs und Domain

- iOS: `de.linolaske.todo`, macOS: `de.linolaske.todo.mac`, watchOS: `de.linolaske.todo.watch`.
- Passkeys: RP-ID und Associated Domain `webcredentials:todo.linolaske.de`.
- Das Backend liefert `/.well-known/apple-app-site-association` aus der Konfiguration `AASA_APP_IDS` (siehe [Betrieb](betrieb.html)). Ist die Variable leer, antwortet der Endpunkt mit 404.

## TestFlight-Vorbereitung

- Archiv und Export laufen über ein Skript (xcodegen, `xcodebuild archive`, `-exportArchive`, Methode `app-store-connect`). Signierwerte liegen in einer lokalen, nicht versionierten Konfigurationsdatei; Upload nur auf ausdrücklichen Wunsch.
- `PrivacyInfo.xcprivacy`: kein Tracking, keine gesammelten Datentypen; Exportcompliance `ITSAppUsesNonExemptEncryption = NO` (nur Standard-HTTPS).
- Info.plist-Texte sind deutsch (Face ID, lokales Netzwerk). Das App-Icon stammt aus Icon Composer.
- Jede Uploadrunde braucht eine neue Build-Nummer.

## Stand (27.10.2026)

- Signiertes Archiv und Export für iOS erfolgreich; ein Build ist über das angemeldete Xcode-Konto hochgeladen.
- macOS-Archiv signiert erfolgreich; Upload und App-Store-Connect-Eintrag für macOS stehen aus. Developer-ID-Signierung und Notarisierung sind nicht eingerichtet.
- Offen: Verarbeitung und Zuweisung des Builds an interne Tester, Betrieb des Backends unter der Passkey-Domain, Passkey-Test auf einem echten Gerät.

Der laufende Stand steht im [Status](status.html) des Hauptrepositorys; plattformspezifische Details pflegt das Apple-Repository (`MagicalWig34653/todo-apple`).
