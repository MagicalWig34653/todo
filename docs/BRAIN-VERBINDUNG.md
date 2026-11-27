# Brain-Verbindung: Vollmacht einrichten (ADR 0032, Nachtrag 23.11.2026)

Das Brain (Orchestrator) und weitere Agenten wie Codex dürfen Reviews entscheiden und Fragen beantworten ("nimm das an", "antworte B"), aber nur mit einer eigenen MCP-Verbindung je Agent und einer Vollmacht, die Lino in den Einstellungen für genau diese Verbindung erteilt. Mehrere Verbindungen können gleichzeitig eine Vollmacht haben, jede mit eigener Projektliste. Ohne Vollmacht entscheidet keine Verbindung fremde Reviews oder Fragen (`brain_mandate_required`).

## 1. Eigene Verbindung anmelden

1. Für das Brain einen eigenen MCP-Eintrag anlegen, nicht die gemeinsame Projekt-Verbindung wiederverwenden (sonst entscheiden alle Sitzungen mit): `claude mcp add --transport http --scope user todolino-brain https://todo.linolaske.de/mcp`.
2. Beim Consent mindestens die Rechte `tasks:read`, `tasks:write` und `comments:write` geben. `tasks:read` wird für `wait_for_events` gebraucht (der Wächterdienst des Brains ruft damit per Long-Poll auf), `tasks:write` für `decide_review`/`answer_question`, `comments:write` für Empfehlungs-Kommentare.
3. Projektliste der Verbindung: alle Projekte, in denen das Brain entscheiden soll (Entscheidungen gelten nur in der Schnittmenge aus Grant-Projekten und Mandat-Projekten).
4. Das Refresh-Token rotiert: es gilt 90 Tage ab dem letzten Refresh (ADR 0040), jedes Refresh liefert ein neues und entwertet das alte, sobald das neue benutzt wird. Ein Dienst muss das neue Token atomar speichern (in eine temporäre Datei schreiben, dann umbenennen), sonst ist die Verbindung nach einem Absturz mitten im Refresh verloren und muss neu angemeldet werden.
5. Der Name der Verbindung (Einstellungen, Verbindungen) sollte eindeutig sein, zum Beispiel "Brain".

## 2. Vollmacht erteilen

PWA: Einstellungen, "Brain-Vollmacht" (`/settings/brain-mandate`, Gruppe "Verbundene Apps & Agenten"). Oben steht die Liste der Vollmachten (je Verbindung: Status, Projekte, erteilt/geändert/zuletzt benutzt), darunter das Formular "Vollmacht hinzufügen": eigene, nicht widerrufene Verbindung wählen, Projekte ausdrücklich wählen (1 bis 200, Suche, keine "alle"-Abkürzung, nichts vorausgewählt), speichern. Für eine zweite Verbindung (zum Beispiel Codex neben dem Brain) das Formular einfach noch einmal ausfüllen: die erste Vollmacht bleibt unverändert. Wählt man eine Verbindung, die schon eine aktive Vollmacht hat (oder "Projekte ändern" in ihrem Listeneintrag), zeigt das Formular deren Projekte; entfallen Projekte, zeigt die Seite vorher einen Vorher/Nachher-Vergleich mit hinzugekommenen und entfallenen Projekten, erst "Projektumfang jetzt ändern" speichert. Screenshots: `docs/screenshots/brain-mandat/`. Dasselbe per REST mit Personen-Sitzung (OAuth-Token werden abgelehnt):

```
PUT    /v1/settings/brain-mandate            {"grantID": "<Verbindung>", "projectIDs": ["<Projekt>", ...]}
GET    /v1/settings/brain-mandate            -> {"mandates": [{grantID, grantName, projectIDs, active, ...}, ...]}
GET    /v1/settings/brain-mandate/audit
```

- Seit ADR 0037 kann die Auswahl auch Projektgruppen nennen (Einstellungen, „Projektgruppen“) oder „alle meine Projekte außer …“ lauten (REST: zusätzlich `selection {mode: "selected"|"all_except", groupIDs, excludedProjectIDs, excludedGroupIDs}`). Neue Projekte einer gewählten Gruppe bzw. neue eigene Projekte (nicht die von Agenten angelegten und nicht die, die dir eine andere Person übertragen hat) kommen dann von selbst dazu; Ausschlüsse gewinnen; Entfernen aus einer Gruppe und Löschen wirken sofort. Die Seite zeigt die wirksamen Projekte, Agenten können weder Gruppen noch Vollmachten ändern.
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

## 5. Projekte für andere Verbindungen freigeben (z. B. Wächter, seit Handbuch 1.39.0)

Sieht eine Verbindung ein Projekt nicht (typisch: "Wächter (Mac)" sieht Formular Backend, CarbStock oder GearFlow nicht und weckt das Brain dort deshalb nicht), muss ihre Projektliste das Projekt enthalten. Das Brain kann das jetzt selbst, wenn seine Vollmacht das Projekt enthält. Voraussetzung: die Brain-Verbindung hat die Scopes `projects:read` (Liste) und `projects:write` (Ändern) und die Vollmacht nennt die Projekte, die sie freigeben darf (Einstellungen, "Brain-Vollmacht"). Bei einer schon angemeldeten Verbindung ohne diese Scopes einmal neu anmelden.

1. `list_connections {}`: zeigt die übrigen Verbindungen der Person mit `grantID`, Name ("Wächter (Mac)"), Scopes, letzter Nutzung und den Projekten, die schon in der **eigenen Vollmacht** des Brains liegen. Projekte außerhalb der Vollmacht erscheinen nicht, auch wenn die Verbindung sie hat.
2. `set_connection_projects {grantID: "<Wächter>", addProjectIDs: ["<Formular Backend>", "<CarbStock>", "<GearFlow>"], quote: "<Linos Worte, z. B. 'Gib dem Wächter Formular Backend, CarbStock und GearFlow frei'>"}`. Bis zu 50 Projekte je Liste, `removeProjectIDs` entzieht Projekte wieder. Wiederholen ist unschädlich.
3. Antwort `{grantID, name, projects, added, removed}`; die Wächter-Verbindung sieht die Projekte beim nächsten Aufruf (`list_projects`, `wait_for_events`), ohne neue Anmeldung.

Regeln: nie die eigene Verbindung (`cannot_change_own_connection`); nur Verbindungen derselben Person (`not_found`, auch für fremde Ids); eine widerrufene Verbindung ist `grant_revoked`; ein Projekt außerhalb der eigenen Vollmacht ist `outside_brain_mandate` und es wird gar nichts angewendet (dann in den Einstellungen die Vollmacht um das Projekt erweitern, das kann nur die Person); ohne Zitat `quote_required`; die Person muss das Projekt aktuell lesen können (sonst `not_found`). Vollmachten selbst kann kein Agent ändern. Jede Änderung steht mit Zitat im Protokoll (`GET /v1/settings/brain-mandate/audit`, kinds `connection.project_added` und `connection.project_removed`; in der PWA unter "Brain-Vollmacht, Protokoll"). Die Person kann sie jederzeit im Teilen-Fenster des Projekts oder unter Verbundene Apps zurücknehmen.
