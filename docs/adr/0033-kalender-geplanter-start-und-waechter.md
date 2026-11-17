# ADR 0033 – Kalender: geplanter Start getrennt von Fälligkeit, Planung per MCP; Wächter startet fällige Karten

Status: Entwurf (17.11.2026), noch nicht umgesetzt; wartet auf die Antworten zu den drei offenen Fragen unten. Karten `8CECAD24` (Kalender) und `6C19C1C1` (Wächter startet fällige Karten, blockiert durch die Kalenderkarte).

## Kontext

Heute kennt eine Karte zwei Zeitpunkte in `task_planning` (ADR Planungsdaten, `Sources/TodoKit/PlanningExt`): `dueAt` (Fälligkeit; steuert "Heute", "Demnächst", überfällig) und `plannedAt` ("geplante Bearbeitung"; steuert laut Planungs-ADR ausdrücklich keine Ansicht, die PWA zeigt nur einen Chip). Es gibt weder Kalenderansicht noch Dauer, und `PUT /v1/tasks/{id}/planning` ersetzt alle Planungsdaten auf einmal (für Drag&Drop ungeeignet: ein Verschieben darf Priorität, Wiederholung und Erinnerungen nicht überschreiben). Der Sync-Befehl `task.planning` ist ebenfalls ein vollständiger Ersatz (fehlende Felder löschen).

Agenten können Planung per MCP lesen und schreiben (`get_task_planning`, `update_task_planning` mit `dueDate`/`dueTime` in UTC, `dueAt`, `plannedAt`, `list_planned_tasks`). Aufträge an den Mac-Runner entstehen nur auf Menschenwunsch: `start_agent_job` (Scope `runs:write`, Klasse B) legt über eine bestehende Bindung (`ProjectRunnerBinding`: Projekt, Runner-Gerät, `repositoryKey`) einen Job `queued` an; Rechte: Eigentümer des Projekts (`startAgent`) und des Geräts. Der Runner übernimmt per `claim` mit Lease und Generation, ein Repository kann nicht doppelt belegt werden (`repository_busy_reconcile_first`), und ein Job ist an `taskRevision` gebunden.

Der Wächter (Python auf dem Mac, schreibt `status.json` und meldet per `PUT /v1/system-status` mit dem Runner-Gerätetoken: `claude_ampel`, `claude_frei_fuer_brain`, `platte_ampel`, `platte_frei_gb`, `codex`) kennt Kontingent und Platte bereits. Er soll fällige Karten selbst starten, ohne dass Lino jede einzeln freigibt. Das ist der heikelste Teil: Es führt Code auf dem Mac aus, ausgelöst durch Daten (Datum, Schalter), die auch andere Beteiligte oder Agenten schreiben können.

## Entscheidung

### 1. Datenmodell: `plannedAt` wird der geplante Start, `dueAt` bleibt die Frist

Kein neues Datumsfeld `scheduledStart`. `plannedAt` hat genau diese Bedeutung, ist in REST, Sync, PWA, MCP und Wiederholungslogik (`spawnNext` verschiebt es) vorhanden und wird bisher nirgends fachlich ausgewertet; ein zweites Feld würde Verträge, Sync und Apple doppeln. Anzeigename in den Oberflächen: "Geplanter Start" (statt "Bearbeitung geplant"); der API-Name bleibt `plannedAt`. Bestehende Werte bleiben gültig und werden zu Startzeitpunkten (keine Datenumschreibung); ohne Zusatzfelder ändert sich für niemanden etwas.

Neue, additive Spalten an `task_planning` (eine Migration `AddScheduleToTaskPlanning`, alle nullable oder mit Default, zweiter `migrate` ist ein No-op, kein Backfill):

| Spalte | Typ | Bedeutung |
|---|---|---|
| `planned_minutes` | int, null | Dauer in Minuten, 5 bis 1440; null = keine Dauer (Anzeige: 30 Minuten) |
| `planned_all_day` | bool, Default false | Karte ist einem Tag zugeordnet, ohne Uhrzeit; `plannedAt` ist dann der Tagesbeginn in der Zeitzone des Clients, der es gesetzt hat |
| `auto_start` | bool, Default false | Mensch hat erlaubt, dass der Wächter diese Karte zum geplanten Start automatisch einem Runner übergibt (Abschnitt 4) |
| `auto_started_at` | datetime, null | Zeitpunkt der automatischen Übergabe (Anzeige und Sperre gegen Wiederholung) |

Semantik: Der Kalender zeigt eine Karte im Block `plannedAt` bis `plannedAt + Dauer`; `dueAt` erscheint getrennt als Fristmarke. Ganztägige Karten (`planned_all_day`) stehen im Tageskopf und werden vom Wächter nie gestartet (kein Uhrzeitbezug). Eine Karte ohne `plannedAt` ist "ungeplant" und liegt in der Seitenleiste des Kalenders. Erledigte Karten bleiben sichtbar (gedämpft), werden aber nicht mehr verschoben oder gestartet.

Zeitzonen: Gespeichert werden Zeitpunkte (UTC, `datetime`), wie bisher. Das Zeitraster rendert jeder Client in seiner Zeitzone; der Server kennt keine Kontozeitzone und braucht keine, weil der Wächter und die Abfragen nur Zeitpunkte vergleichen. Die Wiederholungsregel behält ihre eigene IANA-Zeitzone (ein täglicher 09:00-Start bleibt über die Sommerzeitgrenze 09:00 Ortszeit, `RecurrenceRule.next`). Beim Verschieben über eine Sommerzeitumstellung rechnet der Client in Ortszeit (Zielzeit in der Zeitzone, nicht +24 h); nicht existierende Ortszeiten (Lücke) rutschen auf die nächste gültige Minute. MCP-Eingaben `dueDate`/`dueTime` bleiben UTC; für den Start gilt nur `plannedAt` als ISO-8601-Zeitpunkt mit Offset.

### 2. Verträge und MCP

REST (neu, additiv, `contracts/planning-ext.yaml` auf 1.1.0, Planung im Sync additiv in `contracts/sync.yaml`):
- `GET /v1/planning/schedule?from=&to=&projectID=&limit=` (Rolle read, nur sichtbare Projekte): Karten mit Start im Fenster, Fristen im Fenster und ganztägige; je Eintrag `taskID`, Titel, Status, `plannedAt`, `plannedMinutes`, `plannedAllDay`, `dueAt`, `blocked`, `autoStart`, `autoStartedAt` und der Zustand des neuesten Agent-Jobs. Fenster höchstens 62 Tage, Limit 500. Ungeplante Karten über den bestehenden Planungs-Endpunkt `view=unscheduled` (neu in `plannedTasks`).
- `PATCH /v1/tasks/{id}/schedule` `{plannedAt?, plannedMinutes?, plannedAllDay?, version}` (Rolle edit): ändert nur diese Felder, `null` löscht, prüft die Aufgabenversion (`version_conflict` 409) und erhöht sie, schreibt Aktivität `task.scheduled`. Das ist der einzige Schreibweg für Drag&Drop; die Wiederholungs-, Erinnerungs- und Prioritätsfelder bleiben unberührt. `recurrence_requires_date` bleibt gültig (Start löschen ist nur ohne Wiederholung oder mit `dueAt` erlaubt).
- `PUT /v1/tasks/{id}/auto-start` `{enabled}`: nur Sitzung (Mensch), nicht über OAuth/MCP (Abschnitt 4 und Angriffsfläche).
- Sync: `task.planning` erhält additiv `plannedMinutes` und `plannedAllDay`. Weil der Befehl ein Vollersatz ist, würde ein alter Client die Dauer löschen; deshalb Sync-Minor-Erhöhung und Hinweis im Vertrag, dass fehlende neue Felder bei Clients vor dieser Version auf ihrem bisherigen Wert bleiben (Server übernimmt die Felder nur, wenn der Client sie mitsendet). `auto_start` ist kein Sync-Feld (nur der eigene Endpunkt).

MCP (Parität, `docs/MCP-PARITAET.md`, `contracts/oauth-mcp.yaml` Minor, Handbuch Minor):
- `get_task_planning` liefert die neuen Felder mit (additiv).
- `update_task_planning` nimmt `plannedMinutes` und `plannedAllDay` an (gleiche Validierung wie REST). Es nimmt `autoStart` nicht an (`invalid_arguments`).
- Neu `list_schedule {from, to, projectID?, limit?}` (`tasks:read`, nur Projekte im Grant, gleiche Antwort wie REST), damit Agenten und der Wächter den Kalender lesen. Planen per Agent geht damit über `update_task_planning` (Klasse A, wie bisher).
- `start_agent_job` erhält ein optionales `releaseID` (UUID) für Idempotenz und das Feld `origin` ("manual" Standard, "scheduler"); ohne beides unverändert. Der Server leitet nichts daraus ab außer Aktivität und Wiederholungserkennung (Abschnitt 4).

### 3. Drag&Drop-Semantik (PWA und Apple)

- Ansichten: Tag, Woche (Standard), Monat; ungeplante Karten in einer Seitenleiste (auf dem Telefon als Blatt). Zeitraster 15 Minuten, Einrasten beim Loslassen; Standarddauer 30 Minuten; Dauer per Ziehen am unteren Rand (Schritte 15 Minuten, Minimum 15).
- Aus der Seitenleiste ins Raster: setzt Start (und Dauer). Innerhalb des Rasters: verschiebt Start, Dauer bleibt. Auf den Tageskopf oder in die Monatsansicht: ganztägig am Zieltag, Uhrzeit entfällt (bei Wechsel zurück ins Raster zählt der Drop-Zeitpunkt). Zurück in die Seitenleiste: löscht `plannedAt` (nur ohne Wiederholung ohne `dueAt`, sonst Hinweis).
- `dueAt` wird nie durch Ziehen geändert; es erscheint als Marke am Fälligkeitszeitpunkt. Die Fälligkeit ändert nur der Karten-Dialog.
- Konflikte werden angezeigt, nicht verhindert: überlappende Blöcke stehen nebeneinander; Warnsymbol, wenn Start oder Ende hinter `dueAt` liegen, wenn ein Vorgänger (Abhängigkeit) später liegt oder nicht erledigt ist, und wenn zwei Karten mit Agent-Auftrag über dieselbe Bindung (`repositoryKey`) zeitlich überlappen (der Runner führt je Repository nur einen Job aus, die zweite würde warten). Verschieben auf vergangene Zeit ist erlaubt (nachtragen), eine Karte mit `auto_start` wird dabei mit Rückfrage entschärft (Abschnitt 4, "verpasst").
- Schreiben: optimistisch anzeigen, `PATCH .../schedule` mit der Aufgabenversion; bei 409 oder Fehler zurückrollen, Hinweis, neu laden. Zeitgleiche Änderung durch eine zweite Person, die Karte erscheint beim Live-Refresh (bestehender Live-Token) an der neuen Stelle. Nur mit Rolle edit ziehbar; sonst nur lesen.
- Tastatur und Screenreader (Pflicht, ADR zur Barrierefreiheit der PWA): Karte fokussieren, Pfeiltasten verschieben um 15 Minuten bzw. einen Tag, Umschalt+Pfeil ändert die Dauer, Eingabetaste öffnet den Dialog "Start und Dauer" als Alternative zum Ziehen; Änderungen werden per `aria-live` angesagt.
- Apple: SwiftUI `draggable`/`dropDestination` im Wochenraster (iPad und Mac), auf dem iPhone Tages-Liste mit langem Druck und Bearbeiten-Blatt; gleiche Regeln, gleicher Endpunkt, Offline-Warteschlange über `task.planning` im Sync (Dauer und Ganztägig als Felder).

### 4. Schnittstelle für den Wächter

Grundsatz: Der Wächter entscheidet lokal und fail-closed, ob ein Start jetzt vertretbar ist (er kennt Kontingent, Leistung und Platte des Macs); der Server entscheidet, ob er darf (Rechte, Berechtigung, Idempotenz) und führt nichts aus, was ein Mensch nicht schon erlaubt hat.

Wer darf was:
- Ein Mensch setzt je Karte `auto_start` ("Wächter darf diese Karte zum geplanten Start automatisch starten"). Voraussetzungen beim Setzen: Rolle Eigentümer (wie `startAgent`), genau eine nutzbare Bindung (oder gewähltes Gerät), `plannedAt` mit Uhrzeit, nicht ganztägig. Das ist die Vollmacht für genau diese Karte, kein Projekt- oder Kontoschalter. Das Setzen ist nur per Sitzung möglich (nicht per MCP, nicht durch Agenten) und schreibt Aktivität `agent.auto_start_enabled`.
- Zusätzlich ein Kontoschalter "Automatische Starts erlauben" (Standard aus) in den Einstellungen; ist er aus, startet der Wächter nichts, egal was an den Karten steht. Er wird in `GET /v1/system-status` neben der Ampel angezeigt.
- Bezug zur Vollmacht-Karte `11DA4A38`: Die Reviews-Vollmacht (automatisches Annehmen auf "Brain empfohlen") bleibt davon getrennt und wird durch den Wächter nicht erweitert. Der automatische Start löst nur `implement` oder `clarify` aus; Annehmen eines Ergebnisses bleibt Menschensache, bis diese Karte etwas anderes beschließt.

Abfrage fälliger Karten (Wächter, alle 60 Sekunden, bereits laufender Takt): Der Wächter bekommt eine eigene MCP-Verbindung (OAuth-Grant, ADR 0028 "MCP-Verbindungen als Beteiligte") mit nur `tasks:read` und `runs:write`, beschränkt auf die betroffenen Projekte; er ruft `list_schedule` mit `to=jetzt` und sucht Einträge mit `autoStart=true`, `autoStartedAt=null`, Status nicht `done`, nicht `blocked`, Job-Zustand weder aktiv noch erfolgreich, Start im Fenster [jetzt − Karenz, jetzt]. Die Karenz ist 15 Minuten; liegt der Start länger zurück (Mac war aus, Wächter pausiert), wird die Karte nicht gestartet, sondern als "verpasst" markiert (Kommentar am Ende, siehe Fehlerfälle). Ein Start pro Durchlauf (kein Schwall nach einem Neustart), höchstens `max_parallel` gleichzeitige Auto-Jobs (Standard 1).

Sperren, alle lokal im Wächter, jede einzelne blockiert (UND-Verknüpfung), Daten fehlen oder sind älter als 30 Minuten = blockiert:
- Kontingent: `claude_ampel` ist `gruen` (bei `gelb` nur, wenn `claude_frei_fuer_brain` über der Schwelle der Konfiguration liegt), `codex.freigabe` ist `true`, wenn der Job Codex nutzt.
- Leistung: neu additives Feld `leistung_ampel` (`gruen|gelb|rot`) und `leistung_last_pct` im Status-JSON (`contracts/system-status.yaml` 1.1.0, zulässig, weil unbekannte Felder erhalten bleiben; Prüfung ergänzt); der Wächter berechnet es aus Last und Speicherdruck und startet nur bei `gruen`. Keine neuen Server-Entscheidungen daraus.
- Platte: `platte_ampel` ist `gruen` und `platte_frei_gb` über der konfigurierten Mindestgröße.
- Zusätzlich: Runner-Gerät hat einen frischen Herzschlag (`last_seen_at`), und die Bindung ist nicht belegt (der Server meldet sonst `repository_busy_reconcile_first` beim `claim`; der Wächter prüft vorher `list_agent_jobs`).

Idempotenz: Der Wächter startet mit `start_agent_job {taskID, version, releaseID, origin:"scheduler"}`, wobei `releaseID` deterministisch aus Karte und geplantem Start gebildet wird (UUID-Version 5 über `taskID` + `plannedAt` in Sekunden). `AgentService.release` erkennt dieselbe `body.id` und liefert den vorhandenen Job zurück (`release_id_conflict` bei abweichenden Daten). Damit ergeben Neustart, Doppelaufruf, zwei Wächter-Instanzen und Netzwiederholung genau einen Job je Karte und Startzeitpunkt. Nach der Übergabe setzt der Server `auto_started_at` und löscht `auto_start` (Ein-Mal-Erlaubnis): eine wiederholte Ausführung braucht eine neue Freigabe durch den Menschen (bei Wiederholungskarten legt `spawnNext` die Folgekarte ohne `auto_start` an). `version` ist die aktuelle Aufgabenversion, die der Wächter eben gelesen hat; ändert jemand die Karte dazwischen, gibt es `task_revision_changed` und der nächste Durchlauf entscheidet neu.

Fehlerfälle: Jede Entscheidung "nicht gestartet" mit Grund (`blocked_by_quota|performance|disk|device_offline|binding_busy|missed|error`) landet im Status des Wächters (`waechter.letzte_entscheidung`, `waechter.naechster_start`) und wird einmal je Grundwechsel als Fortschrittsnotiz (`post_progress`-Äquivalent über die Verbindung) an der Karte hinterlegt, nie bei jedem Takt. Technische Fehler (`no_binding`, `device_required`, 401/403, 5xx) sperren den Wächter mit Backoff (60 s bis 15 min) und schalten bei Autorisierungsfehlern den Auto-Start ab. Bei "verpasst" bleibt `auto_start` gesetzt und die Karte im Kalender sichtbar mit Hinweis; der Mensch verschiebt sie oder startet sie von Hand.

Audit: Aktivität `agent.released` (besteht) mit `origin: scheduler`, Akteur ist die Wächter-Verbindung (nicht die Person), dazu `agent.auto_start_enabled`/`disabled` mit Person. Jeder Job zeigt in der Detailansicht "automatisch gestartet durch Wächter, geplant für ...". Fortschrittsnotiz an der Karte beim Start.

Abschalten, gestuft: (1) Karte: Schalter aus; (2) Konto: "Automatische Starts erlauben" aus; (3) Verbindung des Wächters widerrufen (sofortiger Stopp, Standardfunktion der Verbindungsverwaltung); (4) Mac: Datei oder Umgebungsvariable `TODOLINO_AUTOSTART=off` und das Beenden des Wächters; (5) laufende Jobs: `stop_agent_job`. Ohne Netz oder bei abgelaufenem Token startet nichts.

## Angriffsfläche

- Automatische Codeausführung durch Daten: Wer `auto_start` und `plannedAt` setzen kann, kann Code auf Linos Mac auslösen, dessen Eingabe der Kartentext ist (Prompt-Injection: ein Kommentar oder eine Beschreibung, die ein Agent oder eine fremde Person geschrieben hat). Gegenmaßnahmen: `auto_start` nur per Sitzung und nur durch den Projekteigentümer, nie per MCP/Agent; Ein-Mal-Erlaubnis; Kontoschalter Standard aus; Änderungen an Titel oder Beschreibung durch jemand anderen als den Eigentümer nach dem Setzen löschen `auto_start` (Server prüft in `PlanningService.update`/MCP-Schreibpfaden, Aktivität `agent.auto_start_revoked`); der Job übernimmt weiter nur `taskRevision` und die bestehenden Runner-Grenzen (Bindung, Projektordner, kein neuer Pfad).
- Fremde Planung: Beteiligte mit edit können `plannedAt` verschieben, aber ohne `auto_start` hat das keine Wirkung; bei gesetztem `auto_start` führt ein fremdes Verschieben dazu, dass die Karte zu einem anderen Zeitpunkt startet. Deshalb löscht jede Änderung von `plannedAt`/`plannedMinutes` durch jemand anderen als den Eigentümer ebenfalls `auto_start`.
- Wächter-Zugang: eigene Verbindung mit minimalem Scope; Diebstahl des Tokens erlaubt nur, Karten mit `auto_start` zu starten, und nur die, die ein Mensch freigegeben hat; nie Annehmen, Löschen oder Rechte ändern. Widerruf wirkt sofort.
- Zeitmanipulation: Der Server verwendet seine Uhr für Frische und `auto_started_at`; Client-Zeitstempel bestimmen nur `plannedAt`. Ein sehr naher Start (z. B. "jetzt") ist erlaubt, wird aber wie jeder andere durch Kontoschalter, Karenz und Sperren begrenzt.
- Ressourcen: Fensterabfrage begrenzt (62 Tage, 500 Einträge, eigenes Rate-Limit je Konto), Wächter-Startrate begrenzt (ein Start je Durchlauf, `max_parallel`), Drag&Drop-PATCH mit Rate-Limit wie `update_task_planning`.
- Rechte und Sichtbarkeit: Kalender und `list_schedule` verwenden `ProjectAccess` (fremde Karten sind 404/ausgeblendet); Karten außerhalb des OAuth-Grants erscheinen nicht. Fristen und Titel dürfen nicht über die Kalender-Abfrage an Unberechtigte gelangen.

## Folgen

- Eine Quelle für "wann": `plannedAt` plus Dauer; "Heute" bleibt an `dueAt` hängen. Karten ohne Frist, aber mit Start erscheinen nicht unter "Heute" (bewusst; falls gewünscht, eigene Ansicht "Geplant für heute" in einem Folgeschritt).
- Sync-Clients vor dieser Version sehen weiter nur `plannedAt`; Dauer und Ganztägig kennen sie nicht (bleiben unverändert, s. oben).
- Wiederholungen verschieben `plannedAt` wie bisher; `planned_minutes` und `planned_all_day` werden kopiert, `auto_start` nicht.
- Der Wächter ist ein zweiter, ungeprüfter Verbraucher von `system-status`; neue Felder (`leistung_ampel`) müssen im Wächter-Repository (`orchestrator/tools/waechter.py`) umgesetzt werden, außerhalb dieses Repositories.
- "Verpasst" setzt ein Nachholen durch den Menschen voraus; eine automatische Nachhol-Logik gibt es bewusst nicht.
- Grenzen: keine Mehrbenutzer-Terminpläne (Kapazität je Person), keine Zeitblöcke ohne Karte, kein Kalender-Export (ICS) und keine Synchronisation mit Systemkalendern; keine Priorisierung mehrerer gleichzeitig fälliger Karten außer "älterer Start zuerst".

## Umsetzungsplan (Stufen, jeweils eigener Zweig, TDD, Handbuch und Verträge mit)

| Stufe | Inhalt | Schätzung |
|---|---|---|
| 1 Backend Kalender | Migration (`planned_minutes`, `planned_all_day`, `auto_start`, `auto_started_at`), `PATCH /v1/tasks/{id}/schedule`, `GET /v1/planning/schedule`, `view=unscheduled`, Sync-Felder, MCP `list_schedule`, Erweiterung `get/update_task_planning`, Verträge, Handbuch, MCP-Parität, Tests (Rechte, Versionskonflikt, Zeitzonen und Sommerzeit, MariaDB) | 2 Tage |
| 2 PWA Kalender | Wochen-, Tages-, Monatsansicht, Seitenleiste, Drag&Drop mit Einrasten, Dauer, Tastaturbedienung, Konfliktsymbole, Live-Refresh, Playwright (Chromium, WebKit, mobil) | 4 Tage |
| 3 Apple Kalender | SwiftUI-Raster, Drag&Drop, iPhone-Liste, Sync-Felder, Previews/Screenshots | 3 Tage (anderes Repository) |
| 4 Backend Auto-Start | `PUT .../auto-start` (nur Sitzung), Kontoschalter, Widerruf bei fremder Änderung, `releaseID`/`origin` an `start_agent_job`, deterministische Idempotenz, `auto_started_at`, Aktivitäten, Tests und E2E gegen echtes Backend | 1,5 Tage |
| 5 Wächter | Abfrage, Sperren (Kontingent, Leistung, Platte), Karenz, Backoff, Entscheidungsstatus, `leistung_ampel` im Status, Schalter lokal, Trockenlauf-Modus (nur protokollieren) | 2 Tage (Wächter-Repository) |
| 6 Abnahme | Trockenlauf eine Woche, danach scharf mit einer Testkarte; Anzeige "automatisch gestartet" in PWA und App; Status und Handbuch | 1 Tag plus Beobachtung |

Reihenfolge: 1, dann 2 und 3 parallel, 4 und 5 erst nach 1; Stufe 5 scharf frühestens nach der Abnahme von 4 und der Antwort zu Frage 1.

## Offene Fragen an Lino

1. **Wie meldet sich der Wächter am Server an?** Eigene MCP/OAuth-Verbindung mit `tasks:read` und `runs:write` (sichtbar in der Verbindungsverwaltung, sofort widerrufbar; `start_agent_job` ist bereits darauf ausgelegt) oder das bestehende Runner-Gerätetoken, das ein neuer Endpunkt für den Start akzeptieren müsste. Empfehlung: eigene Verbindung (kleinere Rechte, vorhandener Widerruf, kein Sonderweg).
2. **Wo liegt die Erlaubnis für automatische Starts?** Je Karte als Ein-Mal-Erlaubnis plus Kontoschalter (Empfehlung: sicherer, jede Ausführung wurde bewusst freigegeben) oder je Projekt dauerhaft ("alle Karten dieses Projekts mit Startzeit starten automatisch"; bequemer, aber ein fremd gesetzter Termin löst Codeausführung aus).
3. **Was passiert bei einem verpassten Start** (Mac aus, Sperre aktiv, länger als 15 Minuten her)? Empfehlung: nicht nachholen, Karte als "verpasst" markieren und Lino entscheiden lassen (Alternative: nach Ende der Sperre bis zu 2 Stunden nachholen).
