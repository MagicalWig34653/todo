# Brain-Verbindung: Vollmacht einrichten (ADR 0032)

Das Brain (Orchestrator) darf Reviews entscheiden und Fragen beantworten ("nimm das an", "antworte B"), aber nur mit einer eigenen MCP-Verbindung und einer Vollmacht, die Lino in den Einstellungen erteilt. Ohne Vollmacht entscheidet keine Verbindung fremde Reviews oder Fragen (`brain_mandate_required`).

## 1. Eigene Verbindung anmelden

1. Für das Brain einen eigenen MCP-Eintrag anlegen, nicht die gemeinsame Projekt-Verbindung wiederverwenden (sonst entscheiden alle Sitzungen mit): `claude mcp add --transport http --scope user todolino-brain https://todo.linolaske.de/mcp`.
2. Beim Consent mindestens die Rechte `tasks:read`, `tasks:write` und `comments:write` geben. `tasks:read` wird für `wait_for_events` gebraucht (der Wächterdienst des Brains ruft damit per Long-Poll auf), `tasks:write` für `decide_review`/`answer_question`, `comments:write` für Empfehlungs-Kommentare.
3. Projektliste der Verbindung: alle Projekte, in denen das Brain entscheiden soll (Entscheidungen gelten nur in der Schnittmenge aus Grant-Projekten und Mandat-Projekten).
4. Das Refresh-Token rotiert: es gilt 30 Tage, jedes Refresh liefert ein neues und entwertet das alte. Ein Dienst muss das neue Token atomar speichern (in eine temporäre Datei schreiben, dann umbenennen), sonst ist die Verbindung nach einem Absturz mitten im Refresh verloren und muss neu angemeldet werden.
5. Der Name der Verbindung (Einstellungen, Verbindungen) sollte eindeutig sein, zum Beispiel "Brain".

## 2. Vollmacht erteilen

PWA: Einstellungen, "Brain-Vollmacht" (`/settings/brain-mandate`, Gruppe "Verbundene Apps & Agenten"): eigene, nicht widerrufene Verbindung wählen, Projekte ausdrücklich wählen (1 bis 200, Suche, keine "alle"-Abkürzung, nichts vorausgewählt), speichern. Wird eine aktive Vollmacht ersetzt (andere Verbindung und/oder andere Projekte), zeigt die Seite vorher einen Vorher/Nachher-Vergleich mit hinzugekommenen und entfallenen Projekten und dem Hinweis, dass die bisherige Verbindung die Vollmacht sofort verliert; erst "Vollmacht jetzt übertragen" speichert. Die Seite zeigt außerdem Status (aktiv, widerrufen, Verbindung selbst widerrufen = wirkungslos), Projekte im Umfang, erteilt/geändert/zuletzt benutzt und das Protokoll der letzten Entscheidungen mit Zitat und Link zur Karte. Screenshots: `docs/screenshots/brain-mandat/`. Dasselbe per REST mit Personen-Sitzung (OAuth-Token werden abgelehnt):

```
PUT /v1/settings/brain-mandate   {"grantID": "<Verbindung>", "projectIDs": ["<Projekt>", ...]}
GET /v1/settings/brain-mandate
GET /v1/settings/brain-mandate/audit
```

- Höchstens eine Vollmacht je Person; erneut erteilen überschreibt sie. Projekte gelten genau wie genannt, ohne Unterprojekte.
- Der Grant muss Lino gehören und darf nicht widerrufen sein.

## 3. Widerrufen

`DELETE /v1/settings/brain-mandate` (oder in den Einstellungen "Vollmacht widerrufen", mit Bestätigung). Wirkt sofort für die nächste Entscheidung; ein widerrufener Grant macht die Vollmacht ebenfalls wirkungslos. Bereits getroffene Entscheidungen bleiben (Rücknahme wie bisher durch die Person).

## 4. Was das Brain tun muss

- `decide_review {taskID, decision, note?, quote}` und `answer_question {questionID, answer, quote}`: `quote` sind Linos eigene Worte (Pflicht, höchstens 2000 Zeichen). Ohne: `quote_required`.
- Eigene Reviews/Fragen der Brain-Verbindung bleiben gesperrt.
- Jede Entscheidung steht im Chat der Review/Frage als "Brain im Auftrag von <Name>: Entscheidung von <Name> (Zitat): ..." und im Protokoll (`GET /v1/settings/brain-mandate/audit`).
- `get_connection.brainMandate {active, projectIDs}` zeigt dem Brain lesend, ob die Vollmacht gilt.
- Die Markierung "Brain empfohlen" setzt nur ein Kommentar dieser Verbindung (`add_comment` mit `reviewID`) in einem Projekt der Vollmacht.
