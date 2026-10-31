<!-- todolino:begin -->
## Todolino

Dieses Projekt wird in Todolino geplant (Projekt-ID in `.todolino.json`). Todolino muss aktuell bleiben:
- Sitzungsstart: `session_start` ausfuehren (Prompt `/mcp__todolino__session_start` bzw. Skill `todolino`) oder `get_sync_status` und `get_command_center` aufrufen.
- Waehrend der Arbeit: `claim_task`, `post_progress` nach jedem sinnvollen Schritt, `ask_question` statt zu raten, `request_review` bei Fertigstellung.
- Sitzungsende: Status aktualisieren und `record_sync` aufrufen. Eine Aufgabe gilt erst als erledigt, wenn Todolino sie widerspiegelt.
- Ist das Board veraltet (`get_sync_status`), zuerst abgleichen (`sync_project`).
<!-- todolino:end -->
