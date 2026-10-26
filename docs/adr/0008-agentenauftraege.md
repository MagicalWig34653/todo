# ADR 0008 – Agentenaufträge, Runner-Lease und Wiederanlauf

Status: angenommen und serverseitig implementiert (25.10.2026); MariaDB-/Linux-Abnahme offen.

## Entscheidung

Agentenaufträge sind eigene Datensätze; keine Runner-Aktion verändert den fachlichen Aufgabenstatus. Menschen geben `clarify` (klären) oder `implement` (umsetzen) mit Aufgabenrevision und explizitem Umfang frei. `ProjectAccess.startAgent` ist eine eigene Fähigkeit und erlaubt bis zur Integration der Teamrechte ausschließlich den tatsächlichen Projekteigentümer. Ein Bearbeitenrecht genügt nicht. Geräte dürfen nur Projekte ihres Eigentümers bedienen.

Ein zehn Minuten gültiger, zufälliger Einmalcode koppelt ein Gerät. Code und Geräte-Token liegen ausschließlich als SHA-256-Hash in der Datenbank; Klarwerte werden einmal zurückgegeben. Ein widerrufenes Gerät kann weder lesen noch schreiben. Ein Binding enthält eine gerätebezogene Repository-UUID und ein Label, keinen globalen oder lokalen Dateisystempfad. Der Runner muss verschiedene Bindings desselben lokalen Repositorys derselben UUID zuordnen. Ordnerfreigabe, tatsächliche Repository-Identität und lokale Sicherheitsprüfung bleiben beim Mac.

## Übergänge

| Ausgang | Aktion | Ziel |
| --- | --- | --- |
| – | Mensch gibt frei | queued |
| queued | Runner übernimmt atomar | claimed |
| claimed / running | Fortschritt | running |
| claimed / running | strukturierte Frage | waiting_for_answer |
| waiting_for_answer | Mensch antwortet | waiting_for_answer |
| waiting_for_answer | Runner setzt nach vollständigen Antworten gezielt fort | running |
| claimed / running | Ergebnis einreichen, lokaler Lauf beendet | awaiting_review |
| awaiting_review | Mensch nimmt ab | succeeded |
| awaiting_review | Mensch fordert Änderungen | failed |
| claimed / running / waiting_for_answer | Runner meldet Fehler oder bestätigten Stillstand | failed |
| queued / claimed / running / waiting_for_answer | Mensch stoppt | cancelled |
| claimed / running / waiting_for_answer | Runner bestätigt eigenen Stop | cancelled |

Änderungswünsche sind ein dauerhaftes `request_changes`-Ereignis. Ein erneuter Auftrag benötigt eine neue explizite Freigabe und ID; `previousJobID` verbindet ihn optional mit einem abgeschlossenen Auftrag derselben Aufgabe; keine automatische Wiederholung. Antworten sind unveränderlich; identische Wiederholung liefert den bestehenden Stand, widersprüchliche Wiederholung 409. Freigaben verwenden eine vom Client gewählte Auftrags-UUID als Idempotenzschlüssel; andere Nutzdaten unter derselben ID ergeben 409.

## Atomarität und Fencing

Alle Übernahmen und Runner-Schreibvorgänge sperren innerhalb einer Transaktion zuerst die Gerätezeile. Diese kurze Sperre serialisiert Entscheidungen über alle Repository-Aliase eines Geräts; unabhängige Geräte bleiben unabhängig. Unter dieser Sperre wird nach nicht abgeschlossenen Läufen für dieselbe gerätebezogene Repository-UUID gesucht. Die Transaktion schreibt Auftrag, Lauf und Ereignis gemeinsam. Die Sperre ist keine globale Anwendungssperre und wird nicht während der lokalen Ausführung gehalten.

Eine Lease gilt 90 Sekunden. Jeder Runner-Schreibaufruf trägt Lauf-ID und erwartete Generation. Falsche Generation ergibt 409, abgelaufene Lease oder abgeschlossener Lauf 410. Generationen sind nur zusammen mit der Lauf-ID eindeutig. Heartbeat verlängert die Lease. Fragenpausen behalten ihren Repository-Platz und benötigen Heartbeats. Fortschritt ist überschreibbar; Heartbeats und Fortschritt erzeugen keinen dauerhaften Rohlog-Verlauf. Fragen, Antworten, Checkpoints, Einreichung, Stop und Abgleich erzeugen Ereignisse.

Lease-Ablauf gibt den Repository-Platz ausdrücklich **nicht** frei. `GET /v1/runner/runs` liefert nach Neustart die nicht abgeschlossenen Läufe einschließlich Checkpoint und aktueller Generation. Der Runner prüft zuerst den lokalen Prozess: `reconcile` mit `alive` übernimmt denselben Lauf mit neuer Generation und Lease, `stopped` schließt ihn mit neuer Generation als fehlgeschlagen ab (ein zuvor abgebrochener Auftrag bleibt cancelled). `alive` darf keinen neuen Prozess starten. `paused` darf ausschließlich eine nachweislich beabsichtigte Fragenpause mit gespeichertem Checkpoint übernehmen: kein lokaler Prozess aktiv, Auftrag weiterhin waiting_for_answer; neue Generation und Lease, danach gezielte Fortsetzung erst nach Antwort. Unklarer Stillstand ist keine bestätigte Fragenpause. Bei unbekannter Prozesslage gibt es keinen Schreibaufruf und keine Freigabe des Platzes. Ein menschlicher Stop erhöht die Generation sofort; erst `reconcile: stopped` mit der nun aktuellen Generation bestätigt die lokale Beendigung und gibt den Platz frei. Ein widerrufenes Gerät bleibt blockiert; eine administrative Wiederfreigabe nach geprüftem lokalem Stillstand ist noch nicht implementiert.

Einreichung, eigener Stop und Fehlermeldung bestätigen, dass der lokale Prozess beendet ist. Sie schließen den Lauf und geben den Platz frei. Nach verlorener Antwort erst den gespeicherten Stand lesen; weder Claim noch Prozessstart blind wiederholen. Das Protokoll behauptet keine Exactly-once-Ausführung externer Effekte.

Fremdschlüssel verhindern das Löschen von Aufgaben, Projekten oder Geräten mit abhängigen Agentendaten. Dadurch verschwinden aktive Repository-Sperren und dauerhafte Ereignisse nicht durch Kaskaden. Die bestehenden Löschrouten übersetzen diese Constraint-Verletzungen derzeit noch nicht in einen spezifischen fachlichen Fehler.

## Dauerhafter Kontext

Ein Checkpoint pro Lauf speichert Kontextrevision, lokale Sitzungsreferenz und nächsten konkreten Schritt. Revisionen dürfen nicht zurückgehen. Die Sitzungsreferenz ist gemäß ADR 0004 eine lokale Claude-Sitzungskennung, kein Chatverlauf und keine Voraussetzung für die Rekonstruktion aus Aufgabe, Umfang und nächstem Schritt. Ergebnisdaten enthalten Zusammenfassung, Referenzen, selbst gemeldete Checks und Grenzen; diese Checks sind keine vom Server unabhängig beobachteten Nachweise. Vollständige Chats, Tokens und Rohlogs gehören nicht in diese Ressourcen.

## Arbeitsplan und Checkpoint

- [x] Modelle und additive Migration `CreateAgentSchema` mit Fremdschlüsseln, eindeutigen Token-/Code-Hashes, einem Lauf pro Auftrag, einem Checkpoint pro Lauf, einer Antwort pro Frage und Abfrageindizes.
- [x] Eigentümerprüfung über eigene Fähigkeit `ProjectAccess.startAgent`; gemeinsame Freigabe-, Antwort-, Review- und Runner-Regeln in `AgentService`.
- [x] REST-Schnitt für Kopplung/Widerruf, Binding, Freigabe, Claim, Heartbeat, Fortschritt, Checkpoint, Fragen/Antworten, Fortsetzung, Einreichung, Review, Stop und Wiederanlauf einschließlich bestätigter Fragenpause. Vertrag: `contracts/agents.yaml`.
- [x] Zehn SQLite-Agententests ohne Fehler, auch im separaten gefilterten Lauf. Vollständiger Lauf: 24 Tests, davon fünf MariaDB-Tests übersprungen und sechs bestehende Auth-/Planning-Fehler. Unveränderter Ausgangscommit `76c7371` separat aus einem Export unter `/private/tmp` geprüft: dieselben sechs Bootstrap-Fehler bei zwölf Tests (drei MariaDB-Tests übersprungen). Ursache: gemeinsame SQLite-Datei in `TestSupport`; Folgeprüfungen erwarten erneut einen leeren Bootstrap. Die fremde Testhilfe wurde gemäß Dateigrenze nicht geändert.
- [x] Vertrag als YAML geparst, 23 Operationen, 153 Referenzen aufgelöst, eindeutige Operations-IDs; kein vollständiger OpenAPI-Schemavalidator verfügbar. `git diff --check` ohne Befund.
- [ ] Zwei neue MariaDB-Konkurrenztests ausführen: acht gleichzeitige Claims desselben Auftrags über zwei Replikate; zwei verschiedene Aufträge auf Alias-Bindings desselben Repositorys. Das verlangte Skript wurde aufgerufen, scheitert aber am gesperrten Docker-Socket. Kein Nachweis der MariaDB-Sperren oder des Linux-Builds in dieser Umgebung.
- [ ] Anschließend echten Mac-Runner gegen diesen Vertrag prüfen: lokale Freigaben/Repository-UUID, Prozessstillstand vor Submit/Stop/Fail, Netzverlust und gezielte Fortsetzung gemäß ADR 0004. Administrative Freigabe widerrufener Geräte nach geprüftem Stillstand, fachliche Löschkonflikte, Pagination/Aufbewahrung und Teamrechte bleiben Integrationsarbeit.

Nur dieses Hauptrepository, Branch `worktree-agent-a9862124df8dc00d0`; Commit-Titel `Implement agent jobs and fenced runner API`. Ein erster Git-Schreibversuch scheiterte vorübergehend an der Sandbox-Sperre auf `index.lock`; der separate erneute Staging-Aufruf war erfolgreich. Apple-Repository und Referenzprojekte unberührt. Keine Pushes oder Deployments. Keine weiterlaufenden Test-/Serverjobs bei Übergabe. Arbeitsplan für diesen begrenzten Strang liegt hier, weil der Auftrag Änderungen am globalen ARBEITSPLAN ausschließt. Ausführbare Testbefehle und Infrastrukturgrenzen stehen im Abschnitt „Agentenaufträge“ von STATUS.md.
