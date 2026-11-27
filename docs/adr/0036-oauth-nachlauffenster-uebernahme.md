# ADR 0036 – Nachlauffenster beim Refresh und Übernahme von Projekten und Vollmacht bei der Neuanmeldung

> **Geändert durch ADR 0040 (27.11.2026, Karte FFF3C6AB):** Die Frist von 300 s entfällt, die Obergrenze ist 50 statt 5, Refresh-Tokens
> gelten 90 statt 30 Tage. Die Abschnitte unten beschreiben den früheren Stand; Entscheidung 2 (Übernahme) gilt weiter.

Status: umgesetzt 26.11.2026 (Karte `BEF08998`, Teil 1 und 2, Nachtrag Security-Review), nicht deployt. Ergänzt ADR 0007 und ADR 0032.

## Anlass

Lino 26.11.: „Sowas nervt. Entweder die MCP Session bleibt länger bestehen oder die Vollmacht bleibt bestehen. Aber immer wieder alle Projekte auszuwählen nervt.“

## Ursache (belegt aus den lokalen MCP-Logs von Claude Code, Server `todolino-brain`, Zeiten UTC)

| Zeit 26.11. | Log |
| --- | --- |
| 06:44:09.539 | `Starting token refresh` (vorsorglich, Access-Token lief in 258 s ab) |
| 06:44:09.718 | `Token refresh successful` |
| 06:44:13.870 | `Token persist failed: storage write failed` |
| 06:45:07.612 | `Token expires in 200s` – gespeichert ist noch das alte Paar |
| 06:45:07.678 | `Token refresh failed with invalid_grant` (58 s nach der Rotation) |
| 06:45:12 | `Invalidated credentials`, Aufruf `decide_review` endet mit 401, `needs-auth` |

Der Client hat die erfolgreiche Antwort nicht speichern können und das alte Refresh-Token erneut gesendet. Der Server wertete das als Diebstahl und widerrief die ganze Verbindung. Das Setzen der Vollmacht hat nichts ausgelöst: sie ändert weder Scopes noch Tokens, und davor gibt es keinen 401/403; der zeitliche Zusammenhang entsteht, weil der erste Aufruf danach in das vorsorgliche Erneuern fiel.

Nicht belegt: warum das Speichern scheiterte (Vermutung: Schlüsselbund-Schreibfehler; viele parallele Prozesse teilen die Anmeldung) und die Serverseite (keine Logs der Live-Instanz eingesehen). Dass `invalid_grant` vom Replay-Zweig kam, folgt aus Code und Ablauf und passt zur Meldung der PWA „selbst widerrufen“.

## Entscheidung 1: Nachlauffenster von 300 s für das zuletzt rotierte Refresh-Token

Ein verbrauchtes Refresh-Token wird erneut angenommen, wenn **alle** gelten: Art refresh (Autorisierungscodes nie), Verbindung nicht widerrufen, gleicher Client und gleiche Resource, Token nicht abgelaufen, höchstens 300 s seit der **ersten** Benutzung (eine Wiederholung verlängert nichts), und **kein** daraus ausgestelltes Refresh-Token wurde benutzt. Die Wiederholung liefert ein weiteres Paar. Die erste Benutzung eines dieser Nachfolger entwertet die Geschwister; wer danach eines davon oder das alte Token vorlegt, widerruft die ganze Verbindung samt Access-Tokens (`revoked_reason = replay`). Ohne `consumed_at` (Altbestand, entwertete Geschwister) gibt es kein Fenster.

**Warum so (RFC 9700 §4.14.2):** Rotation soll erkennen, dass zwei Parteien dieselbe Anmeldung benutzen. Das bleibt: Von zwei Zweigen kann nur einer weiterlaufen, der andere löst bei seiner nächsten Benutzung den Widerruf aus. Das Fenster verschiebt die Erkennung bei einem Diebstahl innerhalb der 300 s auf den nächsten Refresh der Gegenseite (bei aktivem Client höchstens eine Access-Laufzeit); bis dahin hat ein Angreifer ein gültiges Access-Token, das er mit einem frischen gestohlenen Token auch ohne Fenster bekäme. Alle Wiederholungen laufen unter der Zeilensperre des Grants. Seit dem Nachtrag höchstens 5 je Token (siehe unten); jede erzeugt ein weiteres Geschwister, von denen eines überlebt.

**300 s statt der üblichen 30 bis 60 s:** Der belegte Abstand war 58 s. Claude Code erneuert, sobald weniger als 300 s Restlaufzeit bleiben; bis dahin ist das alte Access-Token noch gültig und der nächste Versuch mit dem alten Token kommt irgendwann in dieser Spanne.

**Grenze:** Ruht der Client länger als 300 s nach einem verlorenen Speichern, wird er weiterhin abgemeldet. Dafür gibt es Entscheidung 2.

Verworfen: Replay-Erkennung abschaffen; unbegrenztes Fenster „bis der Nachfolger benutzt wurde“ (ein altes Token bliebe bei ruhendem Client tagelang brauchbar); längere Access-Tokens (verschiebt nur den Zeitpunkt).

## Entscheidung 2: Übernahme nur durch die angemeldete Person auf der Zustimmungsseite

`GET /oauth/authorize` bietet höchstens **eine** frühere Verbindung an, `POST /oauth/consent` überträgt sie nur mit `takeover_grant_id`. Kein MCP-Weg, kein Automatismus beim Token-Tausch.

**Wer in Frage kommt:** Verbindung derselben Person und Resource, die aktiv ist oder höchstens 7 Tage vor dem Anzeigen bzw. dem Klick durch Replay-Erkennung beendet wurde (`revoked_at`), und von der es etwas zu übernehmen gibt (lesbares Projekt oder nicht widerrufene Vollmacht).

1. Gleiche `client_id`: aktive und durch Replay beendete.
2. Sonst, nur wenn der neue Redirect Loopback ist und der Name nicht leer und nicht der Standardname `MCP Client` (ohne `client_name` registriert) ist: gleicher Clientname, alle Redirects des alten Clients Loopback und die alte Verbindung **durch Replay beendet**. Enger als verlangt: eine funktionierende Verbindung (etwa auf einem zweiten Rechner) wird nie nur wegen des Namens ersetzt.
3. Mehrere Treffer: nichts (`takeover_ambiguous`).

**Nie:** von der Person widerrufen (auch nachträglich auf eine Replay-Verbindung, PWA „Nicht übernehmen lassen“), bereits ersetzt, Konto gesperrt (die Sperre stellt auch Replay-Verbindungen auf `account_locked`), unbekannte Ursache (Altbestand), fremde Person. Eine von der Person widerrufene Vollmacht wandert nicht mit.

**Was wandert:** Die Projektliste ist die, die die Person im Formular bestätigt (vorausgewählt: frühere Projekte und Vollmacht-Projekte, auch solche, die nicht in der alten Liste standen). Vollmacht = noch aktive Vollmacht ∩ beim Anzeigen gezeigte ∩ jetzt lesbare ∩ im Formular bestätigte Projekte. Scopes kommen ausschließlich aus der neuen Anmeldung; jedes Werkzeug prüft sie weiter. Beim Klick wird unter Sperren (Freigabegraph, Person, Vollmacht, Grant) neu geprüft; passt das Angebot nicht mehr, entsteht nichts (`409 takeover_changed`). Die alte Verbindung wird `superseded`.

**Angriffsfläche:** Bei offener dynamischer Registrierung ist der Clientname frei. Ein fremdes Programm könnte sich gleich nennen und eine Zustimmungs-URL öffnen. Dagegen stehen: Zustimmung der angemeldeten Person; Anzeige von Quelle, Vollmacht-Projekten und deutlicher Warnung vor dem Klick; Namenstreffer nur zwischen Loopback-Redirects (der Code landet auf dem Gerät der Person) und nur für eine bereits tote Verbindung. Restrisiko: Ein Schadprogramm auf demselben Gerät plus ein unaufmerksamer Klick gibt ihm Projekte und Vollmacht; die Vorauswahl macht den Klick leichter (bewusst, Auftrag). Protokoll, Widerruf und Zitat-Pflicht gelten weiter. Bei gleicher `client_id` braucht ein Angreifer den registrierten Redirect.

**Eigene Anfragen:** Die neue Verbindung merkt sich ihre Vorgänger (`predecessors`). `cannot_decide_own_review`, `cannot_answer_own_question`, `cannot_decide_own_plan` und `brainRecommended` gelten über diese Kette, sonst könnte sich das Brain nach der Neuanmeldung selbst abnehmen.

**Protokoll und Oberfläche:** je Projekt eine Zeile in `brain_connection_audits` (`mandate.taken_over` bzw. `connection.taken_over`, Servertext statt Zitat); ohne gemeinsames Projekt und ohne Vollmacht genau eine Zeile `connection.taken_over`, deren `project_id` die alte Verbindung nennt (PWA zeigt dann keinen Projektnamen). PWA: Vollmacht „Sicherheitsabmeldung“ mit Hinweis, „Übernommen von …“, ersetzte Vollmachten nur noch im Protokoll; Verbindungen nennen den Grund.

**Für Projektgruppen (Teil 3):** Was zu einer Vollmacht gehört, wird nur in `OAuthTakeover.handOver` (und angeboten in `find`) übertragen und begrenzt. Gruppen kommen dort hinzu: Gruppenbezug kopieren, Begrenzung „gezeigt ∩ jetzt lesbar“ auch darauf anwenden.

## Nachtrag Security-Review 26.11.2026

**Sperren auf MariaDB (blockierte den Push):** `retireSiblings` war `UPDATE oauth_secrets … WHERE rotated_from = ?` ohne Index. InnoDB sperrt dabei jede gelesene Zeile der Tabelle; zwei Refreshes verschiedener Verbindungen liefen in ERROR 1213 (Deadlock) bzw. unter Snapshot-Isolation in ERROR 1020 (fremde Zeile geändert), belegt durch `OAuthConcurrencyTests.testRotationsOfDifferentConnectionsRunConcurrently` (rot vor dem Fix). Jetzt: Geschwister über `rotated_from` lesen, jede Zeile einzeln über den Primärschlüssel ändern, leere Liste ändert nichts; zusätzlich Index `oauth_secrets_rotated_from` (Migration `AddOAuthRotatedFromIndex`, eigene Migration mit `IF NOT EXISTS`, damit frische Datenbanken, der Stand vor ADR 0036 und Datenbanken mit den Spalten aus dc842e3 ihn bekommen). Die übrigen Anweisungen der Token-Transaktion lesen oder schreiben nur per Primärschlüssel oder fügen ein; `judgeRepeat` liest ebenfalls über den neuen Index.

**Preis des Fensters (am Code):** Wer eine Kopie des alten Refresh-Tokens hat und es innerhalb von 300 s nach dessen erster Benutzung vorlegt, solange der Nachfolger des echten Clients unbenutzt ist, bekommt ein Paar. Benutzt danach der echte Client zuerst seinen Zweig, wird der Zweig des Diebs still entwertet; legt der Dieb ihn nie wieder vor, gibt es keinen Replay-Widerruf. Er bleibt bis zum Ablauf seines Access-Tokens unentdeckt: 900 s je Ausgabe, letzte Ausgabe spätestens 300 s nach der ersten Benutzung, also höchstens 1200 s nach der Rotation des echten Clients. Ohne Fenster wäre derselbe Versuch sofort ein Widerruf. Sichtbar bleibt er nur im Server-Log (`oauth.refresh_repeated`). Gewinnt der Zweig des Diebs, meldet der nächste Refresh des echten Clients den Replay wie bisher.

**Deckel:** höchstens 5 Wiederholungen je Token (`OAuthRotation.maxRepeats`, gezählt über die Nachfolger), die sechste wird wie ein Replay behandelt (Widerruf, `revoked_reason = replay`).

**Protokoll:** Server-Log ohne Token-Werte oder Hashes, nur Grant-, Client- und Secret-ID: `oauth.refresh_repeated` (notice, mit Nummer der Wiederholung) und `oauth.replay_revoked` (warning, mit Grund `successor_used`, `window_over`, `no_window`, `repeat_limit`, `not_refresh`). Der Widerruf selbst steht weiter in `revoked_reason`/`revoked_at`.

**Übernahmefrist:** Eine durch Replay beendete Verbindung wird nur bis 7 Tage nach `revoked_at` angeboten und beim Klick angenommen (`OAuthTakeover.offerPeriod`); danach Vollmacht neu erteilen. Kein Namenstreffer beim Standardnamen `MCP Client` oder leerem Namen.

**Zustimmungstext:** nennt jetzt alles, was die Vollmacht erlaubt (am Code: Reviews entscheiden, Fragen beantworten, Pläne freigeben oder Änderungen verlangen in `WorkflowService`/`PipelineService`, Pipeline-Einstellungen in `PipelineSettings` mit Rolle manage, Projektlisten der anderen Verbindungen in `MandatedConnectionService`, je nur in den Vollmacht-Projekten).

**Rolling-Update-Risiko (zwei Token-Zweige):** Laufen alte und neue Instanzen gleichzeitig, kann eine neue Instanz eine Wiederholung annehmen (Geschwister entsteht), während eine Instanz vom Stand vor ADR 0036 den Zweig des echten Clients rotiert, ohne Geschwister zu entwerten und ohne `consumed_at` zu schreiben. Dann laufen beide Zweige dauerhaft nebeneinander, ohne dass Replay-Erkennung zwischen ihnen greift. Gegenmittel: Update ohne Überlappung (alte Instanzen stoppen, dann migrieren und starten); sonst nur bei einer Wiederholung genau im Update-Zeitraum. Instanzen vom Stand dc842e3 haben keinen Deckel und ohne Index die Sperrprobleme; nie deployen.

## Daten und Betrieb

Migrationen `AddOAuthReuseAndRevocation` (`oauth_secrets.consumed_at`, `rotated_from`; `oauth_grants.revoked_reason`, `revoked_at`), `AddOAuthGrantLineage` (`oauth_grants.predecessors`, `taken_over_at`) und `AddOAuthRotatedFromIndex` (Index auf `oauth_secrets.rotated_from`), additiv und nullbar, `App migrate --yes` vor `serve`. Altbestand: bereits widerrufene Verbindungen (auch die Brain-Verbindung vom 26.11.) haben keine Ursache und werden **nie** angeboten; ihre Vollmacht muss einmal neu erteilt werden. Vor dem Update verbrauchte Refresh-Tokens bekommen kein Fenster. Beim Rolling-Update schreiben alte Instanzen keine neuen Spalten (strenges Altverhalten).

## Offen

- Zugriffshinweise, offene Bestätigungsanfragen, beanspruchte Karten und eigene offene Reviews (Zurückziehen) hängen weiter an der alten Grant-ID.
- Bei mehreren alten Verbindungen desselben Clients wird nichts angeboten; die Person kann überzählige in den Einstellungen widerrufen. Eine Auswahlliste ist nicht gebaut.
- Wer die Übernahme abwählt und die Vollmacht von Hand neu erteilt, bekommt wie bisher eine Verbindung ohne Vorgänger-Kette.
- Während eines Rolling-Updates kann eine alte Instanz den Widerruf durch die Person auf einer Replay-Verbindung ohne neue Ursache speichern (sie bliebe übernehmbar); nur in diesem Zeitfenster.
- Passkey-Step-up beim Erteilen bzw. Übernehmen einer Vollmacht (offen seit ADR 0032).
