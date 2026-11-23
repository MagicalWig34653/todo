# Brain-Verbindung: Vollmacht einrichten (ADR 0032, Nachtrag 23.11.2026)

Das Brain (Orchestrator) und weitere Agenten wie Codex dürfen Reviews entscheiden und Fragen beantworten ("nimm das an", "antworte B"), aber nur mit einer eigenen MCP-Verbindung je Agent und einer Vollmacht, die Lino in den Einstellungen für genau diese Verbindung erteilt. Mehrere Verbindungen können gleichzeitig eine Vollmacht haben, jede mit eigener Projektliste. Ohne Vollmacht entscheidet keine Verbindung fremde Reviews oder Fragen (`brain_mandate_required`).

## 1. Eigene Verbindung anmelden

1. Für das Brain einen eigenen MCP-Eintrag anlegen, nicht die gemeinsame Projekt-Verbindung wiederverwenden (sonst entscheiden alle Sitzungen mit): `claude mcp add --transport http --scope user todolino-brain https://todo.linolaske.de/mcp`.
2. Beim Consent mindestens die Rechte `tasks:read`, `tasks:write` und `comments:write` geben. `tasks:read` wird für `wait_for_events` gebraucht (der Wächterdienst des Brains ruft damit per Long-Poll auf), `tasks:write` für `decide_review`/`answer_question`, `comments:write` für Empfehlungs-Kommentare.
3. Projektliste der Verbindung: alle Projekte, in denen das Brain entscheiden soll (Entscheidungen gelten nur in der Schnittmenge aus Grant-Projekten und Mandat-Projekten).
4. Das Refresh-Token rotiert: es gilt 30 Tage, jedes Refresh liefert ein neues und entwertet das alte. Ein Dienst muss das neue Token atomar speichern (in eine temporäre Datei schreiben, dann umbenennen), sonst ist die Verbindung nach einem Absturz mitten im Refresh verloren und muss neu angemeldet werden.
5. Der Name der Verbindung (Einstellungen, Verbindungen) sollte eindeutig sein, zum Beispiel "Brain".

## 2. Vollmacht erteilen

PWA: Einstellungen, "Brain-Vollmacht" (`/settings/brain-mandate`, Gruppe "Verbundene Apps & Agenten"). Oben steht die Liste der Vollmachten (je Verbindung: Status, Projekte, erteilt/geändert/zuletzt benutzt), darunter das Formular "Vollmacht hinzufügen": eigene, nicht widerrufene Verbindung wählen, Projekte ausdrücklich wählen (1 bis 200, Suche, keine "alle"-Abkürzung, nichts vorausgewählt), speichern. Für eine zweite Verbindung (zum Beispiel Codex neben dem Brain) das Formular einfach noch einmal ausfüllen: die erste Vollmacht bleibt unverändert. Wählt man eine Verbindung, die schon eine aktive Vollmacht hat (oder "Projekte ändern" in ihrem Listeneintrag), zeigt das Formular deren Projekte; entfallen Projekte, zeigt die Seite vorher einen Vorher/Nachher-Vergleich mit hinzugekommenen und entfallenen Projekten, erst "Projektumfang jetzt ändern" speichert. Screenshots: `docs/screenshots/brain-mandat/`. Dasselbe per REST mit Personen-Sitzung (OAuth-Token werden abgelehnt):

```
PUT    /v1/settings/brain-mandate            {"grantID": "<Verbindung>", "projectIDs": ["<Projekt>", ...]}
GET    /v1/settings/brain-mandate            -> {"mandates": [{grantID, grantName, projectIDs, active, ...}, ...]}
GET    /v1/settings/brain-mandate/audit
```

- Höchstens eine Vollmacht je Verbindung; erneut erteilen für dieselbe Verbindung überschreibt nur deren Vollmacht. Projekte gelten genau wie genannt, ohne Unterprojekte, und je Verbindung getrennt: eine Verbindung entscheidet nie in Projekten, die nur in der Liste einer anderen stehen.
- Der Grant muss Lino gehören und darf nicht widerrufen sein.
- Nach dem Update (einmalig, Migration `BrainMandateGrantUnique`): die bisherige Vollmacht bleibt bestehen. Codex-Verbindung (eigener MCP-Eintrag, eigene Anmeldung, Projektliste der Verbindung enthält die gewünschten Projekte) anschließend in derselben Seite zusätzlich berechtigen.

## 3. Widerrufen

PWA: "Vollmacht widerrufen" im Eintrag der Verbindung (mit Bestätigung), oder per REST `DELETE /v1/settings/brain-mandate/<Verbindung>`; `DELETE /v1/settings/brain-mandate` ohne ID widerruft alle. Wirkt sofort für die nächste Entscheidung dieser Verbindung, die Vollmachten der anderen bleiben. Ein widerrufener Grant macht nur seine eigene Vollmacht wirkungslos. Bereits getroffene Entscheidungen bleiben (Rücknahme wie bisher durch die Person).

## 4. Was das Brain tun muss

- `decide_review {taskID, decision, note?, quote}` und `answer_question {questionID, answer, quote}`: `quote` sind Linos eigene Worte (Pflicht, höchstens 2000 Zeichen). Ohne: `quote_required`.
- Eigene Reviews/Fragen der Brain-Verbindung bleiben gesperrt.
- Jede Entscheidung steht im Chat der Review/Frage als "Brain im Auftrag von <Name>: Entscheidung von <Name> (Zitat): ..." und im Protokoll (`GET /v1/settings/brain-mandate/audit`).
- `get_connection.brainMandate {active, projectIDs}` zeigt der aufrufenden Verbindung lesend, ob ihre eigene Vollmacht gilt (und für welche Projekte).
- Die Markierung "Brain empfohlen" setzt nur ein Kommentar einer Verbindung mit eigener Vollmacht (`add_comment` mit `reviewID`) in einem Projekt ihrer Vollmacht.
- Fehler: `brain_mandate_required` heißt "diese Verbindung hat keine aktive Vollmacht" (die Vollmacht einer anderen Verbindung hilft nicht), `outside_brain_mandate` "das Projekt steht nicht in der Liste der eigenen Vollmacht".
