# Runner: Claude Code auf dem eigenen Mac

Der Runner (`todo-runner`) ist ein Kommandozeilenprogramm für den Mac. Er nimmt freigegebene Aufträge aus der Steuerzentrale an, startet dafür die lokale `claude`-CLI in einem freigegebenen Projektordner und meldet Fortschritt, Rückfragen und Ergebnis über die Runner-API an die Aufgabe. Aufträge und Checkpoints liegen in der App, nicht in einer Chat-Sitzung; deshalb kann jede neue Sitzung weiterarbeiten.

Der Runner liegt im separaten Apple-Repository. Die vollständige Anleitung zu Einrichtung, Sicherheitsmodell und Fehlersuche steht dort: [docs/RUNNER.md im Apple-Repository](https://github.com/MagicalWig34653/todo-apple/blob/main/docs/RUNNER.md). Architektur: [Agenten und MCP](agenten-und-mcp.html), Entscheidungen: [ADR 0004](adr/0004-runner-claude-start.md) und [ADR 0008](adr/0008-agentenauftraege.md), Vertrag: [Agenten](api/agents.html).

## Ablauf in Kürze

1. Runner bauen und `todo-runner pair https://<server> <Code>` ausführen; den Einmalcode erzeugt die Seite „Agenten“ der PWA oder App. Das Geräte-Token landet im macOS-Schlüsselbund.
2. Ordner freigeben: `todo-runner approve <Ordner>` gibt eine Repository-UUID aus. Mit dieser UUID verbindet man in der PWA das Projekt mit dem Gerät. Pfade verlassen den Mac nie, der Server kennt nur die UUID.
3. `todo-runner doctor` prüft CLI, Kopplung, Server und Ordner. Gestartet wird mit `run-once` (ein Auftrag) oder `run` (dauerhaft, optional per LaunchAgent).
4. In der Steuerzentrale einen Auftrag freigeben (Klärung oder Umsetzung). Der Runner meldet gedrosselt Fortschritt; Fragen erscheinen unter „Offene Fragen“, das Ergebnis als Review.

![Agenten-Seite in der PWA: Runner koppeln, Geräte, Aufträge](screenshots/agenten.png)

## Sicherheit in Kürze

- Aufträge laufen nur in lokal freigegebenen Ordnern, höchstens ein offener Lauf je Ordner.
- Claude läuft mit expliziter Werkzeugliste und ohne interaktive Rückfrage: Klärung nur lesend, Umsetzung zusätzlich mit Edit und Write; kein Bash, kein Netzwerkwerkzeug, keine MCP-Server. Commit, Push und Deploy sind untersagt.
- Das Geräte-Token gilt nur für die Runner-API, wird nie geloggt und ist in der App widerrufbar.
- Jede Schreibaktion trägt eine Generation. Bei Besitzverlust (Lease abgelaufen, Stop) veröffentlicht der Runner nichts mehr; unklare Läufe blockieren den Ordner, bis ein Mensch sie freigibt. Es gibt keinen blinden Neustart.

## Stand und Grenzen

Der Runner ist mit 65 Tests und Live-Läufen gegen die echte `claude`-CLI und ein natives Backend geprüft. Nicht geprüft: echter Ruhezustand und Aufwachen (nur Zeitsimulation), `pair`, `run` und `run-once` gegen einen echten Server, die LaunchAgent-Installation, Stop-, Lease-Verlust- und Neustartszenarien gegen das echte Backend. Nicht Teil des Runners: Runner-Steuerung in der Mac-App, App-Sandbox, Screenshots an Aufgaben. Ein Hinweis aus dem Backend: Der Runner startet Claude derzeit ohne MCP; die MCP-Anbindung für Agenten ist der separate Weg über das [Plugin](projekt-onboarding.html).
