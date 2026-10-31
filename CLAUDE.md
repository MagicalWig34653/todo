# Claude Code – Todolino

Hauptrepository: globale Dokumentation unter docs/, aktueller Arbeitsplan unter docs/ARBEITSPLAN.md.

1. AGENTS.md lesen und befolgen.
2. Im Hauptrepository docs/STATUS.md, den aktuellen Arbeitsplan und relevante Konzept-/Architekturdokumente lesen. Im Apple-Repository zusätzlich den lokalen Status lesen und das Hauptrepository über die lokale Workspace-Konfiguration finden.
3. Code, Git-Status und aktuelle Verträge prüfen; dokumentierte Planung ist keine Implementierung.
4. Den nächsten überschaubaren vertikalen Schritt aus docs/UMSETZUNGSPLAN.md bearbeiten.
5. Passende Prüfungen ausführen und einen fortsetzbaren Stand dokumentieren.

Produktkern: intuitive Todo-/Projektplanung mit frei verschachtelten Projekten, Teams und Freigaben; Passkey zuerst; PWA und SwiftUI; MCP/OAuth; lokale Mac-Runner für Claude Code; Rückfragen, Fortschritt und Screenshots direkt an Aufgaben.

Keine Abhängigkeit von alten Claude-Sitzungen aufbauen. Die App selbst muss Aufträge und Checkpoints so speichern, dass auch neue Agentensitzungen weiterarbeiten können.

**Verbindlich für die Entwicklung:** Sessions sind wegwerfbar; das Repository ist die Source of Truth. Dokumentation nach jedem abgeschlossenen Teilschritt aktualisieren, nicht erst am Sessionende. Neue Entscheidungen, tatsächlicher Stand, Testnachweise, offene Probleme und nächste Schritte müssen ohne alten Chat verständlich sein. Vor Kontextwechsel oder Übergabe einen vollständigen Checkpoint in Status und Arbeitsplan hinterlassen.

<!-- todolino:begin -->
## Todolino

Dieses Projekt wird in Todolino geplant (Projekt-ID in `.todolino.json`). Todolino muss aktuell bleiben:
- Sitzungsstart: `session_start` ausfuehren (Prompt `/mcp__todolino__session_start` bzw. Skill `todolino`) oder `get_sync_status` und `get_command_center` aufrufen.
- Waehrend der Arbeit: `claim_task`, `post_progress` nach jedem sinnvollen Schritt, `ask_question` statt zu raten, `request_review` bei Fertigstellung.
- Sitzungsende: Status aktualisieren und `record_sync` aufrufen. Eine Aufgabe gilt erst als erledigt, wenn Todolino sie widerspiegelt.
- Ist das Board veraltet (`get_sync_status`), zuerst abgleichen (`sync_project`).
<!-- todolino:end -->
