<!-- todolino:begin -->
## Todolino

Dieses Projekt wird in Todolino geplant (Projekt-ID und `repository` in `.todolino.json`; `repository` bei `get_sync_status` und `record_sync` immer mitgeben, ein Projekt kann mehrere Bindungen haben). Das Board laufend nutzen, nicht nur einmal am Ende:
- Start: `session_start` (Skill `todolino`) oder `get_sync_status`, `get_command_center`, `list_open_questions`, `list_pending_reviews` (immer mit der `projectID` aus `.todolino.json`; Aufgaben fremder Projekte nie bearbeiten, erwähnen oder anbieten); ist das Board veraltet, zuerst `sync_project`.
- Vor der Arbeit: passende Aufgabe suchen oder mit `create_task` anlegen (keine Duplikate), dann `claim_task`.
- Nach jedem abgeschlossenen Teilschritt und jedem Commit: `post_progress`.
- Entscheidungen des Nutzers als `ask_question` an der Aufgabe stellen statt nur im Chat zu fragen.
- Fertig: `request_review` NUR wenn der Nutzer etwas ansehen oder entscheiden muss (sichtbares Ergebnis, Risiko, Rollout). Reine Update-Infos (Commit, Tests grün, interne Änderung) gehören in `post_progress`, nicht in ein Review. Belegt fertig (gemergt, Tests grün, nichts zu entscheiden): nach `post_progress` mit Beleg selbst `update_task status=done`. Ende: `record_sync`.
- Texte am Board kurz und in Stichpunkten: Überschrift = Aufgabentitel; Review: ein Satz Ergebnis + höchstens 4 Stichpunkte (neu, geprüft, ansehen, offen); Frage: 1 bis 2 Zeilen + 2 bis 4 Optionen, Empfehlung zuerst; Fortschritt: 1 bis 2 Sätze.
- Gestartete Agenten bekommen die Aufgaben-ID im Prompt und melden `post_progress` selbst; die Hauptsession stellt das Review.
<!-- todolino:end -->
