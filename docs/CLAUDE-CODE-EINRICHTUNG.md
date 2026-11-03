# Claude Code mit Todolino einrichten

Ziel: Todolino einmal global in Claude Code hinzufügen, danach in einem Projekt sagen „Richte das Projekt in Todolino ein“, und dafür sorgen, dass das Board aktuell bleibt. Technische Grundlage: [ADR 0018](adr/0018-projekt-onboarding-und-aktualitaet.md) und das [Agentenhandbuch](agent-manual.md). Alles, was unten als „Annahme“ steht, ist nicht belegt.

## Weg A: Plugin (empfohlen)

Das Plugin liegt in diesem Repository (`claude-plugin/`, Marketplace `.claude-plugin/marketplace.json`). Es enthält den MCP-Server, drei Skills und die Hooks.

1. Marketplace hinzufügen (Claude Code, einmal pro Rechner/Konto): `/plugin marketplace add MagicalWig34653/todo`
2. Plugin installieren: `/plugin install todolino@todolino` (Scope „user“ = global für alle Projekte).
3. Beim Aktivieren fragt Claude Code nach der Server-Adresse (`server_url`). Standard: `https://todo.linolaske.de/mcp`. Für eine andere Instanz die MCP-URL eintragen (`/plugin configure todolino@todolino`).
4. Anmelden: in Claude Code `/mcp`, den Server `todolino` wählen und im Browser anmelden (OAuth, Passkey). Auf der Zustimmungsseite die Rechte bestätigen. Für das Anlegen neuer Projekte durch den Agenten braucht die Verbindung den Scope `projects:write`; bereits freigegebene Projekte werden gewählt, neue Projekte werden der Verbindung automatisch hinzugefügt.
5. In einem Projektverzeichnis sagen: „Richte das Projekt in Todolino ein“. Das Skill `todolino:setup` (oder `/todolino:setup`) liest README, AGENTS.md/CLAUDE.md, docs/, Plandateien und Git-Log, legt das Projekt per MCP an (oder findet das vorhandene über die Git-Remote), importiert Features, Aufgaben, Unteraufgaben und Kriterien idempotent, schreibt `.todolino.json` und einen kurzen Abschnitt in CLAUDE.md und ruft `record_sync` auf.

Wirkung danach:
- SessionStart-Hook: in Repositories mit `.todolino.json` bekommt der Agent den Kontext „an Todolino gebunden, Pflichtregeln „Board laufend nutzen“: Lage prüfen (offene Fragen, Reviews, eigene Aufgaben), Aufgabe suchen oder anlegen und claimen, post_progress je Teilschritt, Entscheidungen als ask_question, request_review, record_sync; feste Texte, kein Netzwerk; in Git-Repositories ohne Marker nur den Hinweis „noch nicht eingerichtet“.
- Stop-Hook: siehe „Durchsetzung und ihre Grenzen“.
- SessionStart nennt die fertige ToolSearch-Zeile (`select:mcp__plugin_todolino_todolino__post_progress,...`), weil Tool-Schemas deferred sind und direkte Aufrufe sonst mit `invalid_arguments` scheitern; ein Plugin kann Schemas nicht vorladen.
- Codex-Jobs (Companion/Sandbox) erreichen Todolino-Tools nicht: die startende Claude-Sitzung ist der Wrapper und meldet per `post_progress`/`add_comment` mit `agentName` `codex@<thema>`. Der Stop-Hook zaehlt Board-Aufrufe der Hauptsitzung und der Subagenten (`<session>/subagents/*.jsonl` neben dem Transcript), also auch diese Meldung.
- PostToolUse-Hook (Bash) nach echtem `git commit` (auch `git -C x commit`, verkettet, mit Quotes) oder `git push`: Befehl wird aus `tool_input.command` geparst; `git status`, `git log --grep commit`, `echo "git commit"` loesen nichts aus. Commit: dringende Erinnerung, sofort `post_progress` auf der passenden Aufgabe zu schreiben (sonst `create_task` und `claim_task`), bei Fertigstellung `request_review` (nur gebundene Repositories).

## Weg B: ohne Plugin

1. MCP global hinzufügen: `claude mcp add --transport http --scope user todolino https://todo.linolaske.de/mcp` (Syntax laut Claude-Code-Doku; Optionen vor dem Servernamen).
2. Anmelden: in Claude Code `/mcp` → `todolino` → im Browser anmelden (alternativ in der Shell `claude mcp login todolino`).
3. Die Prompts des Servers erscheinen als Slash-Befehle `/mcp__todolino__setup_project`, `/mcp__todolino__sync_project`, `/mcp__todolino__session_start` (Namensschema für selbst hinzugefügte Server; für den Plugin-Server lautet der Servername `plugin:todolino:todolino`, die genaue Schreibweise der Prompt-Befehle ist **nicht belegt** (Annahme: `/mcp__plugin_todolino_todolino__setup_project`); das Plugin bringt deshalb eigene Skills mit).
4. Textbaustein für die globale `~/.claude/CLAUDE.md`:

```markdown
## Todolino
Enthält ein Repository eine Datei `.todolino.json`, ist es an Todolino gebunden und Todolino muss aktuell bleiben.
- Sitzungsbeginn: Todolino-Prompt `session_start` ausführen (oder `get_sync_status` und `get_command_center`). Ist der Stand `stale` oder `never`, zuerst `sync_project`.
- Während der Arbeit: `claim_task`, `post_progress` nach jedem sinnvollen Schritt, `ask_question` statt zu raten, `request_review` bei Fertigstellung; eigene Arbeit nie selbst auf erledigt setzen.
- Sitzungsende: Status aktualisieren und `record_sync` aufrufen. Aufgaben gelten erst als erledigt, wenn Todolino sie widerspiegelt.
- Ohne `.todolino.json`: nichts einrichten, außer der Nutzer sagt „Richte das Projekt in Todolino ein“ (Prompt `setup_project`).
```

Ohne Plugin gibt es keine Hooks; die Pflicht beruht dann nur auf diesem Textbaustein und dem Projektabschnitt.

## Projektabschnitt für CLAUDE.md / AGENTS.md

`setup_project` schreibt (und aktualisiert idempotent) den Abschnitt zwischen den Markern `<!-- todolino:begin -->` und `<!-- todolino:end -->`. Vorlage: `claude-plugin/templates/claude-md-section.md`. Die Marker-Datei `.todolino.json` enthält `schema`, `server`, `projectID`, `repository`, bewusst keine Geheimnisse, und darf eingecheckt werden.

## Was bei einem Account-Wechsel passiert

- Der MCP-Server mit `--scope user` bzw. das Plugin mit Scope „user“ stehen in der Benutzerkonfiguration von Claude Code (Annahme: unabhängig vom angemeldeten Anthropic-Konto, solange dasselbe Config-Verzeichnis `~/.claude` benutzt wird; nicht geprüft).
- Die Todolino-Anmeldung (OAuth-Token) gehört zum Todolino-Konto, nicht zum Anthropic-Konto. Meldet sich Claude Code mit einem anderen Anthropic-Konto an, bleibt die Todolino-Verbindung bestehen, sofern die Token im selben Config-Verzeichnis gespeichert sind (Annahme). Ist sie weg, genügt `/mcp` → `todolino` → neu anmelden; Projekte, Bindungen und `.todolino.json` liegen auf dem Server bzw. im Repository und bleiben erhalten.
- Wer mit einem anderen **Todolino**-Konto anmeldet, sieht dessen Projekte; ein Repository, das nur im anderen Konto gebunden ist, wird nicht gefunden (kein Querzugriff) und `setup_project` legt dann ein eigenes Projekt an.
- Hinweis: Eine bestehende Verbindung ohne den neuen Scope `projects:write` kann Projekte nicht anlegen (`create_project` ist ausgeblendet); in `/mcp` neu anmelden.

## Durchsetzung und ihre Grenzen

Was erzwungen werden kann (nur mit Plugin, nur in Repositories mit `.todolino.json`):
- Der Stop-Hook hält die Sitzung **höchstens einmal** auf, wenn in der Sitzung Dateien geändert wurden (Edit/Write im Transcript) und `record_sync` nie aufgerufen wurde, und nennt den Grund. Danach darf die Sitzung enden (kein Endlosloop, `stop_hook_active` und eine Marke je Sitzung).
- Board-Aktivität: Gab es in der Sitzung Dateiänderungen oder Commits, aber im Transcript keinen Aufruf von `post_progress`, `request_review` oder `ask_question`, hält der Stop-Hook die Sitzung mit festem Text auf und verlangt das Board-Update vor dem Beenden (höchstens `TODOLINO_STOP_MAX` Mal, Standard 1, je Sitzung; dieser Block ersetzt dann die `record_sync`-Erinnerung). Nur Aufrufe als `tool_use` zählen, keine bloßen Erwähnungen.
- Zusätzlich hält der Stop-Hook die Sitzung auf, solange eine **blockierende Frage** (`ask_question`) ohne anschließendes `get_question` offen ist: fester Text, der `wait_for_events` und danach `get_question` verlangt (keine Nutzertexte), höchstens 6 Fortsetzungen je Sitzung. Das trägt nur wenige Minuten (Claude Code erlaubt höchstens 8 aufeinanderfolgende Fortsetzungen), ist kein echtes Push und noch nicht in einer echten Sitzung erprobt. Siehe [PUSH-AN-CLAUDE-CODE.md](PUSH-AN-CLAUDE-CODE.md).
- Fehler jeder Art (kein Transcript, unlesbare Eingabe, Zeitüberschreitung) führen dazu, dass der Hook nichts tut („fail-open“). Hooks nutzen kein Netzwerk und keine Tokens.
- Abschalten für eine Sitzung: Umgebungsvariable `TODOLINO_HOOKS_OFF=1`.

Was nicht erzwungen werden kann:
- Der Hook prüft nur, **ob** `record_sync` aufgerufen wurde, nicht ob der Inhalt stimmt. Ein Agent kann `record_sync` ohne echten Abgleich aufrufen.
- Ohne Plugin, in Repositories ohne Marker, bei beendeten Sitzungen (Fenster schließen, Absturz, SessionEnd hat nach Doku keine Blockiermöglichkeit) oder wenn der Nutzer die Erinnerung nach dem ersten Block ignoriert, bleibt es bei der Erinnerung.
- Hooks können nicht prüfen, ob Todolino erreichbar ist.
- Serverseitig sichtbar ist nur die Aktualität (`fresh`/`stale`/`never` in der Steuerzentrale, `get_stale_projects`); der Server kann niemanden zum Abgleich zwingen.

## Plugin aktualisieren (Version 1.3.0)

Version 1.5.0 (3.11.2026): Commit-Hook nur bei echtem git commit/push, ToolSearch-Zeile beim Sitzungsstart, Codex-Wrapper-Weg dokumentiert, Stop-Hook zaehlt Subagenten-Transcripts. Version 1.3.0 (2.11.2026): Reviews nur für Dinge, die der Nutzer ansehen oder entscheiden muss; Update-Infos (Commit, Tests, interne Änderung) gehören in `post_progress`. Version 1.2.0 (2.11.2026): Board-Texte kurz und in Stichpunkten (Sitzungsstart, Erinnerung nach Commit, Skill, CLAUDE.md-Vorlage). Version 1.1.0 (1.11.2026): Pflichtregeln beim Sitzungsstart, schärfere Erinnerung nach Commits, Stop-Hook mit Board-Aktivitätsprüfung, überarbeitete Skills und CLAUDE.md-Vorlage, Agentenhandbuch 1.2.0 (Abschnitt „Using the board while you work“). Hooks wirken erst in neuen Sitzungen.

Aktualisieren beim Nutzer (**Befehle nicht geprüft**; `claude plugin --help` war in dieser Umgebung nicht ausführbar, Angabe nach Claude-Code-Doku): Marketplace auffrischen mit `/plugin marketplace update todolino`, Plugin mit `/plugin update todolino@todolino` (Shell: `claude plugin update todolino@todolino`), danach Claude Code neu starten. Die installierte Version zeigt `/plugin`. Den Projektabschnitt „## Todolino“ erneuert `/todolino:setup` (zwischen den Markern) oder man übernimmt `claude-plugin/templates/claude-md-section.md` von Hand.

## Selbsttest

- `claude plugin validate .` (Marketplace) und `claude plugin validate ./claude-plugin`.
- Hook-Tests: `sh claude-plugin/tests/test-hooks.sh`.
- Ende-zu-Ende gegen ein echtes Backend (OAuth + MCP über HTTP): `scripts/onboarding-e2e.sh` (Modi `compose`, `sqlite`, `devdb`, siehe Kopf des Skripts).
