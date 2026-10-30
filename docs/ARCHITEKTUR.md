# Architektur – Arbeitsentwurf

## Repository- und Komponentenstruktur

Genau zwei Repositories. Backend und PWA teilen ein Hauptrepository und dessen Dokumentation/API-Verträge. Das zweite Repository enthält die Apple-Apps und den Mac-Runner.

```text
PWA / SwiftUI / MCP-Clients / Mac-Runner
                   ↓ HTTPS
           API-Replikate im Swarm
      gemeinsame Fachlogik und Rechteprüfung
                   ↓
                MariaDB
                   + Dateispeicher

Mac-Runner → lokaler Projektordner → Claude-Code-Prozess
```

Arbeitsannahme: Swift/Vapor/Fluent, MariaDB und ein modularer Monolith. Module beispielsweise Identität, Projekte, Aufgaben, Zusammenarbeit, Anhänge, Agentenaufträge, Benachrichtigungen und MCP. HTTP-Routen und MCP-Tools rufen dieselben Anwendungsdienste auf.

Svelte/SvelteKit mit shadcn-svelte als PWA. Statische Auslieferung ist die Ausgangsannahme; Hosting und Routing explizit prüfen. SwiftUI-Clients teilen einen API-/Sync-Kern, erhalten aber angepasste Oberflächen. Native DTOs können gemeinsam nutzbar sein; Datenbankmodelle und Backend-Abhängigkeiten gehören nicht in den App-Kern.

## Datenmodell als Ausgangspunkt

| Bereich | Entitäten |
| --- | --- |
| Identität | User, Passkey, Session, RecoveryMethod, Invitation |
| Zusammenarbeit | Team, TeamMembership, ProjectGrant |
| Projekte | Project mit parentID und Eigentümer Person oder Team |
| Aufgaben | Task, Subtask/Elternbeziehung, Assignee, Label, Dependency, Milestone |
| Kommunikation | Comment, Question, Answer, ActivityEvent, Decision |
| Dateien | Attachment, UploadSession, Verknüpfung zu Aufgabe/Kommentar |
| Integration | OAuthClient, Grant, Access-/RefreshCredential |
| Ausführung | RunnerDevice, ProjectRunnerBinding, AgentJob, AgentRun, Lease, Checkpoint |
| Synchronisierung | ChangeSequence/Änderungsereignis, ClientMutation, OutboxEvent |

Dies ist noch kein verbindliches SQL-Schema. Eindeutige IDs, Zeitstempel, Versionsfelder und passende Indizes vorsehen. Projektzyklen verhindern. Eigentümerschaft und Projektverschiebungen transaktional validieren. Abhängigkeiten dürfen nicht versehentlich fremde Projekttitel offenlegen.

## API und Synchronisierung

- Versionierter Vertrag unter `contracts/`; REST-Schemas und MCP-Schemas auf gemeinsame Datentypen abstimmen.
- Listen paginieren; Änderungen inkrementell abrufbar machen.
- Schreibvorgänge mit erwarteter Version für Konflikterkennung; keine stillen Überschreibungen von Beschreibung oder Antworten.
- Wiederholbare Client-Mutationen über eindeutige Mutation-/Idempotenzschlüssel absichern.
- Offline-Erfassung dauerhaft lokal puffern. Konflikte und nicht mehr erlaubte Änderungen sichtbar machen.
- Löschungen und Rechteentzug im Sync-Protokoll berücksichtigen; betroffene lokale Daten und Vorschauen entfernen.
- Serverzeit und stabile Cursor verwenden; Clientuhren sind keine verlässliche Reihenfolge.
- Polling genügt zunächst; Live-Aktualisierung per SSE/WebSocket später austauschbar ergänzen.

## Swarm und Konsistenz

API-Replikate halten keinen für Korrektheit notwendigen lokalen Sitzungs-, Challenge-, OAuth- oder Auftragszustand. Die entsprechenden Datensätze liegen gemeinsam in MariaDB. Keine Sticky Sessions als Voraussetzung.

Migrationen laufen einmalig koordiniert, getrennt vom normalen Replica-Start. Hintergrundjobs verwenden atomare Übernahme, Lease und Erneuerung. Ein veralteter Runner darf nach Lease-Verlust keine Ergebnisse mehr als aktueller Eigentümer veröffentlichen; dafür Generation/Fencing-Wert prüfen.

DB-Transaktionen, Constraints und gezielte Sperren statt einer pauschalen globalen Anwendungssperre verwenden. Wiederholungen nach Verbindungsfehlern dürfen keine doppelten Kommentare, Anhänge oder Aufträge erzeugen. MariaDB-Isolation und konkurrierende Vorgänge gezielt prüfen.

Auftragsausführung ist nicht pauschal „exactly once“. Nach Absturz oder Netztrennung zuerst abgleichen, was lokal tatsächlich noch läuft und welche Effekte bereits entstanden sind. Keine blinde automatische Wiederholung eines möglicherweise aktiven Coding-Laufs.

Dateien liegen in einem von allen Replikaten erreichbaren Speicher: standardmäßig in der Datenbank (Tabelle `attachment_blobs`, Blöcke zu 1 MiB, ADR 0013), optional in einem S3-kompatiblen Bucket (`ATTACHMENT_STORAGE=s3`). Lokale Container-Dateien allein erfüllen den Mehrreplikabetrieb nicht. Metadaten, Uploadabschluss und Aufräumen abgebrochener Uploads koordinieren.

## Betrieb und Prüfung

Entwicklungsstack, reproduzierbarer Linux-Container, Readiness/Liveness, strukturierte datensparsame Logs, Backups und nachgewiesener Restore. Secrets über geeignete Laufzeitkonfiguration, keine Tokens im Repository.

Echte Mehrreplikaprüfung: Login-Challenge über Replica A erzeugen und über B abschließen; OAuth und Uploads replicaübergreifend nutzen; parallele Jobübernahme; Ausfall/Neustart einer Replica; keine verlorenen Updates. Eine Stack-Datei allein ist kein Betriebsnachweis.

## Timetrack als Referenz

Vorhanden sind passende Muster für Vapor/Fluent, Passkeys, Sitzungen, Recovery, OAuth/MCP, MariaDB und PWA. Jede Übernahme auf neue Fachregeln, Abhängigkeiten und Lizenzbedingungen prüfen. Keine Zeittrackingmodule übernehmen. Bekannte Grenzen aus dem Referenzstatus bleiben Prüfaufgaben und werden nicht als erledigt kopiert.
