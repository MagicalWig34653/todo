# ADR 0001 – Backend-Stack: Swift, Vapor, Fluent, MariaDB

Status: angenommen (25.10.2026), bis eine konkrete Hürde dagegen spricht.

**Entscheidung.** Modularer Monolith in Swift 6 mit Vapor 4, Fluent und dem MySQL-Treiber gegen MariaDB 12.3. Passkeys über `webauthn-swift`. Ziele: `TodoKit` (Fachlogik, Routen) und `App` (Einstieg). SQLite im Speicher dient nur schnellen Tests; Konkurrenz- und Sperrtests laufen gegen MariaDB.

**Begründung.** Swift teilt DTOs mit den SwiftUI-Clients; Timetrack zeigt als Lesereferenz, dass der Stack für Passkeys, Sessions und MariaDB trägt. Go bleibt Alternative bei konkreten Hindernissen.

**Folgen.** Keine Replikazustände im Prozess; Migrationen laufen getrennt vom Start. Liveness (`/health/live`) und Readiness (`/health/ready`, prüft die DB) sind getrennt.
