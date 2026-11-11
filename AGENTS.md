# Todolino – Einstieg für Coding-Agenten

Dies ist das Hauptrepository für Backend, PWA und das globale Projektgedächtnis. Alle globalen Dokumente liegen unter docs/. Das Apple-Repository ist über .workspace.local.json auffindbar.

## Projektgedächtnis

Das Backend-/PWA-Repository ist kanonisch. Vor nichttrivialer Arbeit STATUS, aktiven Arbeitsplan, PRODUKT, relevante Architektur-/Rechtedokumente und ADRs lesen. Tatsächlichen Code, Git-Status und laufende Prozesse prüfen. Alte Chatverläufe oder private Agent-Memory sind keine Voraussetzung zur Fortsetzung.

Apple hält nur seinen lokalen Status, Einrichtung und plattformspezifische Übergaben separat. API-Verträge liegen im Hauptrepository unter contracts/. Keine unabhängig gepflegten globalen Konzeptkopien.

## Verbindlich: Sessions sind wegwerfbar

Das Repository ist die Source of Truth. Ein frischer Agent muss allein aus den versionierten Dokumenten, Verträgen und dem tatsächlichen Code weiterarbeiten können. Chatverlauf, Session-IDs und persönliche Agent-Memory dürfen dafür keine Voraussetzung sein.

Dokumentation während der Arbeit aktuell halten: neue Nutzerentscheidungen vor abhängiger Umsetzung festhalten; nach jedem abgeschlossenen Teilschritt Status und Arbeitsplan mit Änderungen, Prüfungen und nächstem Schritt aktualisieren. Wesentliche Architekturentscheidungen als ADR dokumentieren. Globale Auswirkungen aus dem Apple-Repo auch im Hauptrepo festhalten.

Vor Übergabe, Kontextwechsel oder Sessionende einen konsistenten Checkpoint schreiben: Ziel, tatsächlich implementierter Stand, betroffene Repositories/Branches, ungesicherte Änderungen, Vertrags-/Migrationsfolgen, ausgeführte Tests und deren Grenzen, offene Probleme, laufende Prozesse sowie nächster konkreter Schritt. Keine erledigte Arbeit ausschließlich im Chat dokumentieren. Widersprüche zwischen Doku und Code auflösen oder ausdrücklich als offen kennzeichnen.

## Regeln

- Nutzerentscheidungen haben Vorrang; Annahmen und Vorschläge als solche dokumentieren.
- Code, technische Bezeichner, Kommentare und Tests auf Englisch; nutzerseitige Texte zunächst auf Deutsch und über Lokalisierungsressourcen.
- Genau zwei Produkt-Repositories. Backend und PWA bleiben zusammen.
- REST, MCP und Apps verwenden dieselben Fachregeln; keine umgehbaren Rechteprüfungen.
- Konto-, Team-, Projekt-, OAuth- und Runner-Grenzen explizit prüfen.
- Referenzprojekte nicht verändern; keine pauschale Kopie ihrer Fachmodelle.
- Vorhandene Änderungen erhalten; keine destruktiven Bereinigungen für einen sauberen Status.
- Keine Secrets, Tokens, privaten Laufzeitdaten oder vollständigen Chats ins Repository.
- Keine automatischen Pushes, Veröffentlichungen oder Deployments aus einer bloßen Implementierungsaufgabe ableiten.
- Nutzerentscheidung 11.11.2026 (dauerhaft, von Lino bestätigt): Ist ein Feature fertig (Tests grün, auf `main` gemergt, Review angefragt), wird sofort gepusht, nicht gesammelt; die CI baut dann direkt ein Image. Gilt nur für die Hauptsession nach Prüfung, nie für Subagenten; vorher MariaDB-/Testbefunde beachten (rot = nicht pushen, Befund an die Review-Karte). Deploy bleibt allein bei Lino.
- Routineentscheidungen selbst treffen; nur bei tatsächlich blockierenden Unklarheiten nachfragen.
- Arbeitsweise (Nutzerentscheidung 1.11.2026, dauerhaft): Die Hauptsession bleibt so klein wie möglich und koordiniert nur (Status und Board lesen, Aufträge schneiden, Agents starten, Berichte lesen, Branches zusammenführen, Todolino abgleichen). Implementierung, Builds, Tests und Recherche erledigen Subagenten.
  - Parallele Schreiber nur in getrennten Worktrees (`isolation: worktree`) mit klarer Dateiverantwortung; Aufträge so schneiden, dass sich die Dateien nicht überschneiden.
  - Jeder Agent-Auftrag nennt: AGENTS.md und aktuellen STATUS-Checkpoint lesen, konkretes Ziel, diese Regeln, Doku-Checkpoint in STATUS/ARBEITSPLAN, Commit auf dem Worktree-Branch (kein Push) und einen Kurzbericht (Commit, Branch, Tests mit Ergebnis, offene Punkte).
  - Projekt-Subagent `swiftui-designer` (`.claude/agents/`): SwiftUI-Gestaltung im Apple-Repo, tokenbasiert, mit Layout-Checkliste, Screenshots und Previews.
  - Die Hauptsession liest nur die Berichte, nicht die Transkripte, und führt die Branches nach Prüfung zusammen. Entscheidungen, die dem Nutzer gehören (z. B. Datenschutz), werden vorher erfragt.
  - Ergänzung (Nutzerentscheidung 6.11.2026): Die Hauptsession schreibt selbst keinen Feature-Code; auch Kleinigkeiten werden delegiert. Frei nutzbare Modelle: Sonnet, Haiku, gpt-6.1-sol, terra. Opus und gpt-6-astra nur mit ausdrücklicher Genehmigung des Nutzers (vorher `ask_question`).
  - Rollen, Briefing-Vorlage, Verifikationsgate und Modellwahl: `docs/AGENT-ARBEITSWEISE.md`.

## Todolino laufend nutzen

- Texte am Board kurz und in Stichpunkten (Nutzerwunsch 2.11.2026): Überschrift = Aufgabentitel; Review = ein Satz Ergebnis + höchstens 4 Stichpunkte (neu, geprüft mit Zahlen, ansehen, offen); Frage = 1 bis 2 Zeilen + 2 bis 4 Optionen, Empfehlung zuerst; Fortschritt = 1 bis 2 Sätze; Befundlisten in die Aufgabenbeschreibung oder als Unteraufgaben. Rückfragen immer als `ask_question` am Board, nicht im Chat. `request_review` nur, wenn der Nutzer etwas ansehen oder entscheiden muss (sichtbares Ergebnis, Risiko, Rollout); Update-Infos wie Commit, Teststand und interne Änderungen gehören in `post_progress`, nicht in ein Review.
Das Board ist Teil der Arbeit, nicht nur ein Abschlussschritt (`record_sync` allein genügt nicht). Je Auftrag gibt es eine Aufgabe in Todolino (suchen, sonst `create_task`, dann `claim_task`); Entscheidungsfragen an den Nutzer gehören als `ask_question` an diese Aufgabe, nicht nur in den Chat; nach jedem Teilschritt und Commit `post_progress`; bei Fertigstellung `request_review`, nie selbst auf erledigt setzen. Startet eine Hauptsession Agenten, nennt sie die Aufgaben-ID im Agent-Prompt; die Agenten melden `post_progress` selbst, das Review stellt die Hauptsession. Details: `docs/agent-manual.md` („Board laufend nutzen“).

## Umsetzung und Abnahme

Zuerst ausführbaren vertikalen Schnitt herstellen. Relevante Änderungen mit passenden Tests prüfen; unnötige Tests und unbelegte Erfolgsaussagen vermeiden. Bei Backendänderungen Linux/MariaDB und bei nativen Änderungen betroffene Apple-Targets berücksichtigen. Fehlende Geräte-/Infrastrukturprüfungen offen nennen.

Vor Übergabe festhalten: Ziel, tatsächliche Änderungen, Branch/Commit, Vertrags-/Migrationsfolgen, ausgeführte Prüfungen, offene Fehler, laufende Jobs und nächster Schritt. Status und Arbeitsplan im selben Arbeitsschritt aktualisieren. Wesentliche Architekturänderungen als ADR begründen.
