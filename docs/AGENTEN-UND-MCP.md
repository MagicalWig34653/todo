# Agenten, Mac-Runner und MCP

## Verantwortung

Die Mac-App verwaltet lokale Runner und Agentenprozesse. Der Server speichert Aufgaben, Rechte, Aufträge, Rückfragen und Ergebnisse. Der Server benötigt keinen direkten Zugriff auf lokale Projektordner.

Ein Projekt wird auf einem konkreten Mac einem Ordner zugeordnet. Der lokale Pfad ist gerätebezogen und keine globale Projekteigenschaft. Unterprojekte können eine Zuordnung erben; Abweichungen müssen ausdrücklich sichtbar sein.

Claude Code ist der erste Anbieter. Eine kleine Adaptergrenze erlaubt später andere Coding-Agenten, ohne jetzt eine universelle Agentenplattform zu bauen.

## Vor Implementierung des echten Starts prüfen

- Unterstützte aktuelle CLI-/SDK-Schnittstelle für nichtinteraktive, fortsetzbare Läufe.
- Authentifizierung beim Anbieter und tatsächliche lokale Verfügbarkeit.
- Programmatische Berechtigungen, erlaubte Tools, Stoppen und Prozessbeobachtung.
- macOS-App-Verteilung, Sandbox/Dateizugriff, Unterprozesse und Hintergrundausführung.
- Verhalten bei geschlossener App, gesperrtem Mac, Schlafmodus und Neustart.

Die bloße Existenz einer Mac-App garantiert keinen dauerhaft aktiven Hintergrunddienst. Einen später nötigen Helper explizit entwerfen. Zunächst transparent anzeigen, wann der Runner verfügbar ist.

## Auftragsablauf

1. Mensch gibt eine Aufgabe zur Klärung oder Umsetzung frei.
2. Server erzeugt einen eindeutigen Auftrag mit Projekt, Auftraggeber, erlaubtem Umfang und Aufgabenrevision.
3. Berechtigter Runner übernimmt atomar einen Auftrag und erhält eine Lease mit Generation.
4. Runner prüft Pfad, Repository und lokale Freigaben; startet oder setzt den zugehörigen Lauf fort.
5. Regelmäßige Rückmeldung zeigt Verfügbarkeit und Fortschritt.
6. Rückfragen werden dauerhaft als strukturierte Fragen mit Antworten gespeichert.
7. Ein wartender Lauf darf pausieren und bei Antwort gezielt fortgesetzt werden. MCP allein startet keinen Prozess und garantiert keine spontane Zustellung an einen ruhenden Agenten.
8. Ergebnis, Anhänge, Links und Prüfnachweise gehen an die Aufgabe; Status „Zur Abnahme“.
9. Mensch nimmt ab oder fordert Änderungen an; Folgeauftrag behält den Zusammenhang.

Arbeitsannahme für Auftragszustände: `queued`, `claimed`, `running`, `waiting_for_answer`, `awaiting_review`, `succeeded`, `failed`, `cancelled`. Fachlicher Aufgabenstatus bleibt getrennt. Genaue Übergänge, insbesondere Review-Abschluss und Folgeauftrag, als Vertrag festlegen.

## Parallelität und Wiederanlauf

Zunächst höchstens ein aktiver Coding-Lauf pro lokalem Repository. Weitere Aufgaben warten. Ein beschäftigter Agent erhält keine zweite unabhängige Aufgabe ungefragt. Später isolierte Git-Worktrees für parallele Umsetzung.

Serveraufträge, lokale Prozesse und Anbietersitzungen erhalten getrennte IDs. Ein persistenter Checkpoint hält Kontextrevision, Sitzungsreferenz, Ergebnisstand und nächsten Schritt fest; keine Abhängigkeit von vollständigen alten Chats.

Nach Netzverlust/Neustart zuerst lokale Prozess- und Auftragssituation abgleichen. Lease-Verlust bedeutet nicht automatisch, dass der Prozess beendet ist. Keine doppelte Umsetzung starten. Veraltete Besitzer dürfen keine aktuellen Ergebnisse überschreiben. Lauf stoppen/abbrechen und Aufgabe archivieren sind verschiedene Aktionen.

## MCP-Oberfläche – Vorschlag

Werkzeuge nach fachlichen Fähigkeiten schneiden, beispielsweise:

- `list_projects`, `list_tasks`, `get_task`, `get_project_context`
- `create_task`, `update_task`, `add_comment`
- `ask_question`, `list_answers`, `update_progress`
- `begin_attachment_upload`, `complete_attachment_upload`, `list_attachments`, `get_attachment`
- `submit_for_review`

Dies sind noch keine fixierten Namen oder Protokollschemas. Runner-Steuerung wie Claim/Heartbeat kann über eine separate authentifizierte API laufen und muss nicht jedem MCP-Client zugänglich sein.

Scopes beispielsweise für Lesen, Bearbeiten, Kommentieren und Anhänge getrennt halten. Keine beliebigen Dateisystem- oder Shell-Werkzeuge im Todo-MCP anbieten. Freitext und Anhänge sind Daten; sie erweitern keine Berechtigungen. Der Verlauf nennt handelnde Person, Integration und Lauf.

## Anhänge über MCP

Eine Aufgabe oder ein Kommentar kann Anhänge besitzen. Jede Datei hat stabile ID, Eigentümerbezug, Dateiname, geprüften Medientyp, Größe, Prüfsumme und Uploadstatus. Optional Rolle `reference`, `progress`, `result` und Bezug zu einer Vorgängerversion.

Große Binärdaten nicht ungeprüft in jeden Toolaufruf einbetten. Vorgeschlagenes Verfahren:

1. MCP-Tool beantragt einen Upload für einen bereits erlaubten Aufgabenkontext.
2. Server liefert eine kurzlebige, eng begrenzte Uploadmöglichkeit.
3. Client überträgt die Datei über HTTPS.
4. Abschluss validiert Datei und Zuordnung; erst danach erscheint der Anhang regulär.
5. MCP liefert Metadaten und je nach Clientfähigkeit Bildinhalt oder einen authentifizierten/kurzlebigen Zugriff.

Ob Claude Code diesen Ablauf direkt oder über einen kleinen Runner-Adapter nutzt, im Kompatibilitätstest nachweisen. Keine stillschweigende Annahme, dass jeder MCP-Client beliebige Upload-URLs bedienen oder lokale Screenshots erzeugen kann.

Dateigrößen, Medientypen und Vorschauen begrenzen; keine öffentlich dauerhaften Links als Standard. Downloads erneut autorisieren. Abgebrochene Uploads aufräumen. Bildmarkierungen und Versionsvergleiche sind spätere Funktionen.

## Fortschritt und Ergebnisse

Ein kurzer überschreibbarer Fortschrittsstand beantwortet „Wo steht die Aufgabe?“. Ein separater dauerhafter Verlauf dokumentiert wichtige Schritte. Keine Rohlogs als normale Kommentare. Prüfergebnisse unterscheiden selbst gemeldete Checks und tatsächlich durch den Runner beobachtete Ergebnisse.

Screenshots, Branch-/Commit-/PR-Referenzen und offene Grenzen als Ergebnisartefakte speichern. Keine automatischen Commits, Pushes, Merges oder Deployments ohne entsprechende Projektfreigabe voraussetzen.
