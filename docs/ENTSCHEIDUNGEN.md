# Entscheidungen und offene Punkte

## Bestätigte Nutzervorgaben

1. Todo und Projektplanung in einer intuitiven Anwendung.
2. Frei verschachtelte Projekte; keine feste Privat-/Arbeit-Trennung.
3. Teams und Projektfreigaben.
4. Passkey primär; Benutzername/Passwort nachrangig, serverseitig schaltbar.
5. MariaDB, Swarm mit mehreren Backend-Replikaten.
6. Svelte-PWA mit shadcn; SwiftUI für iPhone, iPad, Mac und Watch.
7. MCP mit OAuth, einschließlich Screenshot-/Anhangsfunktionen.
8. Coding-Agenten lesen Ideen, fragen in der App nach und dokumentieren Fortschritt.
9. Mac-App kann in einem zugeordneten Projektordner selbstständig Claude starten.
10. Genau zwei Repositories an den im Startauftrag genannten Orten; die Einrichtung darf bereits durch Codex erfolgen. Backend/PWA ist das Hauptarbeitsrepo.
11. Sessions sind wegwerfbar. Das Repository ist die Source of Truth; seine Dokumentation bleibt während der Arbeit aktuell und ermöglicht die Fortsetzung ohne alten Chat.
12. Als S3-kompatibler Speicher für Entwicklung und Tests dient der S3Mock von Adobe (`adobe/s3mock`). Entscheidung vom 25.10.2026. Seit 30.10.2026 nur noch für den optionalen S3-Speicher (Entscheidung 15).
13. Die Timetrack-Projekte bleiben ausschließlich Lesereferenz. Kein Code wird kopiert; Passkey-, OAuth- und weitere Module werden neu geschrieben. Damit ist die Lizenzfrage zur Codeübernahme erledigt. Entscheidung vom 25.10.2026.
14. Der Nutzer überlässt die Strukturierung der Arbeit dem Agenten; Routineentscheidungen werden selbst getroffen und dokumentiert.
15. S3 darf nicht verpflichtend sein: Anhänge liegen standardmäßig in der Datenbank, S3 ist optional (ADR 0013). Entscheidung vom 30.10.2026.

## Arbeitsannahmen, noch keine endgültigen Nutzerentscheidungen

- Swift/Vapor statt des ursprünglich gewünschten Go, wegen nutzbarer Timetrack-Grundlagen. Der Nutzer erlaubt Swift; die konkrete Empfehlung stammt aus dem Brainstorming.
- Modularer Monolith und REST-Vertrag mit gemeinsamer Autorisierung für MCP.
- Hauptrepository als kanonisches Projektgedächtnis; Apple mit lokalem Status.
- Projektbesitz durch Person oder Team, vorgeschlagene vier Projektrollen und unterbrechbare Vererbung.
- Explizite Agentenfreigabe; zunächst ein Lauf pro lokalem Repository.
- Menschliche Abnahme, getrennte Zustände für Aufgabe und Agentenauftrag.
- Liste/Board vor Kalender/Timeline; schrittweise Umsetzung der Zusatzfunktionen.
- Einladungsbasierte Registrierung nach erstem Bootstrap.

Claude darf diese Arbeitsannahmen begründet konkretisieren und dokumentieren. Bestätigte Nutzervorgaben dürfen nicht stillschweigend geändert werden.

## Früh zu klären oder technisch zu entscheiden

- Verteilung der Mac-App und daraus folgende Runner-/Sandbox-Architektur.
- Verlässlicher automatisierter Claude-Start, Authentifizierung und Fortsetzung.
- Präzise Rechtevererbung, Eigentümerwechsel und Teamrollen.
- Dateispeicher und Uploadgrenzen.
- Registrierung/Recovery und Standardwert des Passwort-Schalters.
- RP-ID, App-Kennungen und Domainkonzept mit Platzhaltern vorbereiten.

Produktname, Geschäftsmodell und Komfortfunktionen blockieren kein Grundgerüst. Infrastruktur- und Kennungswerte als Platzhalter konfigurieren; keine persönlichen Werte erfinden.

## Referenzsichtung vom 25.10.2026

Gelesen wurden relevante Dokumentation und Quellstellen aus timetrack-backend und timetrack-pwa, insbesondere Package.swift, AuthSupport, RecoveryService, PlanningServices/-Persistence, OAuth/MCP und die PWA-Anmeldeseite.

Erkenntnisse: Swift/Vapor/Fluent, MariaDB-Anbindung, Passkeys, Recovery, OAuth/MCP und Svelte/shadcn sind passende Referenzen. Rückfallpasswort dient Recovery; Freigaben sind zeitdatenbezogen. Ein globaler auth_lock ist vorhanden. Reale Swarm-/Mehrreplikatests und reale MCP-Client-Kompatibilität dürfen nicht aus der Referenz abgeleitet werden. Die Sichtung war kein vollständiges Audit und kein ausgeführter Funktionstest.
