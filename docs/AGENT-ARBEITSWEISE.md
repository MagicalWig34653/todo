# Agenten-Arbeitsweise

Arbeitsprotokoll für Hauptsession (Orchestrator) und Subagenten. Ergänzt `AGENTS.md` (Abschnitt „Arbeitsweise“, Nutzerentscheidung 1.11.2026) und ändert sie nicht. Das Repository und das Board sind die Wahrheit, nie ein Worker-Chat.

## Nutzerentscheidung 6.11.2026 (dauerhaft)

Die Hauptsession koordiniert nur und schreibt selbst keinen Feature-Code. Implementierung, Tests, Suche und Review laufen in Subagenten.

| Modell | Status | Einsatz (Empfehlung) |
|---|---|---|
| Haiku | frei | Suche (Explorer), Kleinigkeiten (Tippfehler, Einzeiler) |
| Sonnet | frei | Implementierung (Worker), Verifier |
| gpt-6.1-sol, terra | frei | Zweitmeinung und Review über den Codex-Weg |
| Opus, gpt-6-astra | nur mit ausdrücklicher Genehmigung | Orchestrator fragt vorher per `ask_question`/Formular |

## Quellen (abgerufen)

- Anthropic, Building effective agents (https://www.anthropic.com/engineering/building-effective-agents): Orchestrator-Worker, Evaluator-Optimizer, einfach anfangen und nur bei Bedarf Komplexität ergänzen.
- Anthropic, Multi-agent research system (https://www.anthropic.com/engineering/multi-agent-research-system): ausführliches Briefing, Aufwandsregeln im Prompt, verdichtete Rückgabe, Plan extern speichern, ca. 15x Tokens; bei eng gekoppelten Coding-Aufgaben nur wenige klar geschnittene Worker.
- Anthropic, Effective harnesses for long-running agents (https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents): Fortschrittsdatei plus Git-Log, ein Feature je Session, End-to-End prüfen wie ein Nutzer.
- Claude Code, Subagents (https://code.claude.com/docs/en/sub-agents): eigener Kontext, Tool-Allowlist, `isolation: worktree`, Fortsetzen per SendMessage.
- Anthropic, Writing tools for agents (https://www.anthropic.com/engineering/writing-tools-for-agents): klare, sparsame Tool-Schnittstellen und kompakte Rückgaben.

## Rollen

- Orchestrator (Hauptsession): Planung, Slicing, Briefing, Review, Merge, Doku, Todolino. Kein Feature-Code.
- Worker: `isolation: worktree`, genau ein vertikaler Schritt, TDD, eigener Branch. Schreibt weder `STATUS.md` noch das Board. Keine Verschachtelung (startet keine Subagenten).
- Verifier: frischer Kontext, read-only, führt Tests selbst aus, prüft den Diff gegen die Kriterien.
- Explorer: read-only Suche, liefert Fundstellen statt Dateiinhalte.

## Was der Orchestrator behält und was er delegiert

Behält: STATUS, Arbeitsplan und Board lesen; `claim_task`; Aufgabenschnitt; Konfliktplanung (parallel nur bei disjunkten Dateien); Entscheidungen und `ask_question`; Merge; Gesamttests; alle Doku- und Board-Updates.

Delegiert: Implementierung, Tests schreiben, breite Suche, Review.

## Briefing-Vorlage (selbsttragend, der Worker sieht keinen Chat)

1. Ziel und Akzeptanzkriterien, mit Task-ID.
2. Kontext: relevante Pfade, Verträge, Regeln aus `AGENTS.md`, aktueller STATUS-Checkpoint.
3. Grenzen: erlaubte und verbotene Dateien; kein Schreiben von Doku oder Board.
4. Vorgehen: erst Tests, dann Code; genannte Prüfbefehle ausführen.
5. Aufwandsgrenze: ein Schritt; bei Blockade stoppen und berichten, nicht raten.
6. Ausgabeformat (max. ca. 30 Zeilen): Branch/SHA, geänderte Dateien, Befehle mit echtem Ergebnis, offene Punkte, Annahmen, Risiken. Lange Artefakte als Datei im Repo oder Scratchpad ablegen und nur den Pfad nennen.

## Verifikationsgate vor „erledigt“

1. Orchestrator liest den Diff gegen die Akzeptanzkriterien.
2. Unabhängiger Verifier (frischer Kontext) prüft und führt Tests selbst aus.
3. Höchstens 2 Korrekturschleifen; danach `ask_question` oder die Aufgabe neu schneiden.
4. Nach dem Merge laufen die Gesamttests im Hauptcheckout.
5. Es zählt die Evidenz der eigenen Ausführung, nicht der Worker-Bericht.

## Berichtswege

- `post_progress` bei Delegation und nach bestandenem Gate.
- `request_review` nur, wenn der Nutzer etwas ansehen oder entscheiden muss (siehe `AGENTS.md`).
- `STATUS.md` und Arbeitsplan aktualisiert der Orchestrator nach jedem Teilschritt.
- Rückfragen von Workern gehen nur an den Orchestrator; Nutzerfragen stellt er per `ask_question`.
- Sessionende: vollständiger Checkpoint in Status und Arbeitsplan, dann `record_sync`.

## Leitplanken

- Auch Kleinstkorrekturen (Einzeiler, Tippfehler) macht der Orchestrator nicht selbst: koordinieren statt selbst machen, also delegieren (Haiku).
- Einfach anfangen: so wenige Worker wie möglich; Multi-Agent kostet ca. 15x Tokens und lohnt bei eng gekoppelten Änderungen kaum.
- Parallelität nur bei disjunkten Dateien und getrennten Worktrees.
- Wahrheit liegt in Repo und Board; ein neuer Agent muss ohne alten Chat weiterarbeiten können.
