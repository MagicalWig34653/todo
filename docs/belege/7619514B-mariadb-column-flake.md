# Beleg Karte 7619514B: unsteter MariaDB-Test `ColumnTests.testConcurrentMovesAndColumnCreationAcrossReplicas`

Stand 27.11.2026, Auftrag f-4ea38d66. Ausgangslage: Brain-Validierung `da95daf` am 26.11., erster voller MariaDB-Lauf 1 von 1039 rot (dieser Test), zweiter Lauf grün. Die Meldung ist nicht erhalten: Das Validierungs-JSON speichert nur die letzten 50 Zeilen des grünen Laufs, und der Test gab bei Rot nur Statuscodes aus.

## Umgebung
Eigene MariaDB 12.3.3 (`COMPOSE_PROJECT_NAME=todo-flake`, Port 24761, Datenbanken `todo_flake_1..5`), getrennt von `todo-dev` (23306, Brain-Validierung `todo_validierung`). Alle Läufe über `tools/sparsam`. Last parallel: iPhone-UI-Suite (`xcodebuild test`, Todo-iOS), Brain-Validierung Formular-Backend (`xctest`), Load-Average 5 bis 13 auf 14 Kernen.

## Nicht nachstellbar (Zahlen)
- Einzeltest, 5 Worker gleichzeitig auf 5 Datenbanken desselben Servers, je 50 Läufe, 07:24 bis 07:41: **250 von 250 grün, 0 rot**.
- InnoDB-Zähler des Servers nach diesen Läufen: `Innodb_deadlocks 0`, `Innodb_row_lock_waits 6516`, `Innodb_row_lock_time_max 943 ms` (Grenze `innodb_lock_wait_timeout` 50 s), `Max_used_connections 29` von 151. Es gab also viel Warten auf die Sharing-Graph-Sperre, aber keinen Deadlock und keinen Sperr-Timeout.
- Volle Suite `swift test --no-parallel` gegen MariaDB, bis zu drei gleichzeitig (07:41 bis 08:37): Lauf 3 `Executed 1071 tests, with 9 tests skipped and 0 failures`, Lauf 1 ebenso `1071, 9 skipped, 0 failures`. Lauf 2 beendet bei 235 grünen Tests (Frist). Darin je einmal der Test im Kontext der vorlaufenden Klassen.
- Gesamt in diesem Auftrag: 252 Läufe des Tests ohne Rot, dazu 50 Einzelläufe am 26.11.

## Code-Lesung (warum kein Produktfehler belegt ist)
Alle drei beteiligten Schreibpfade (`PUT /v1/tasks/:id/column`, `POST /v1/projects/:id/columns`, `POST /v1/tasks`) laufen in einer Transaktion und nehmen als erstes die Sharing-Graph-Sperre (`UPDATE sharing_lock …`, `lockSharingGraph`). Damit sind sie über beide Replikate serialisiert; der Versionsvergleich beim Verschieben und die Positionsnummerierung lesen erst nach der Sperre. Eine Lücke, die gleichzeitiges Anlegen/Verschieben in 500 oder doppelte Positionen laufen ließe, ist im Code nicht zu sehen. Mögliche Ursachen ohne Produktfehler: Verbindungsaufbau oder -abbruch der Test-MariaDB, die am 26.11. mit einer zweiten Validierung im selben Compose-Projekt geteilt war (Vorfall 1d95172, seitdem Projekt-Sperre in `validiere.py`), oder ein Sperr-Timeout unter extremer Last. Beides wäre jetzt an Status und Antworttext erkennbar.

## Diagnose für das nächste Rot
`TestApp.rawReply` (Tests/TodoKitTests/TestSupport.swift) liefert Status und Antworttext; der Test meldet bei Rot alle Statuscodes und für jede unerwartete Antwort Status plus die ersten 500 Zeichen Text. Die Prüfaussagen sind unverändert (genau 1x 200, 7x 409, 20x 201, Spaltenpositionen 0..11, 11 dichte Board-Positionen).

Nachweis mit vorübergehend falscher Erwartung (`.ok` statt `.created`, danach zurückgesetzt), Lauf gegen `todo_flake_1`:
```
ColumnTests.swift:405: error: -[TodoKitTests.ColumnTests testConcurrentMovesAndColumnCreationAcrossReplicas] : XCTAssertTrue failed - [201, 201, …, 201]; unexpected replies: ["201: {\"position\":0,\"version\":2,\"isDone\":false,\"id\":\"94403C3A-…\",\"projectID\":\"EF699538-…\",\"name\":\"N0\"}", …]
Executed 1 test, with 1 failure (0 unexpected) in 4.592 (4.592) seconds
```
Ein 500 erschiene dort als `500: {"error":true,"reason":"…"}` samt MySQL-Fehlertext im Log.

## Entscheidung
Kein Fix ohne belegte Ursache: weder ein Produktfehler noch ein Testfehler ist nachweisbar; ein „Fix" auf Verdacht (z. B. Retry im Test) würde die Prüfaussage abschwächen. Stattdessen Diagnose im Test. Kommt das nächste Rot, entscheidet der Antworttext (500 mit Deadlock/Timeout = Produktfrage, z. B. Retry bei 1213/1205; anderer Status = Testfrage).
