# Zuständigkeit Teil 2: Ansichten in PWA und iOS (Beschreibung, noch nicht gebaut)

Karte `8B4BAC2E`. Teil 1 (Server, Verträge, MCP) steht: [ADR 0043](adr/0043-zustaendigkeit.md),
[`contracts/assignments.yaml`](../contracts/assignments.yaml). Teil 2 ändert nur Oberflächen. Abgestimmt mit
[`design/ux-konzept/konzept.md`](../design/ux-konzept/konzept.md) (Bereich „Für dich“, ein Kartenfenster).

## Vorhandene Daten

| Zweck | Quelle |
| --- | --- |
| „Für mich“ | `GET /v1/for-me?projectID=&limit=` → `tasks`, `questions`, `reviews`, `truncated` |
| Auswahlliste | `GET /v1/projects/{id}/assignees` (nur mit `edit`) |
| Setzen, entfernen | `PUT /v1/{tasks,questions,reviews}/{id}/assignee {assigneeID}` |
| Anzeige | `assigneeID` an Aufgabe (auch im Sync-Feed), Frage, Review |

## PWA

1. **Kartenfenster:** Feld „Zuständig“ in der Seitenspalte (Konzept Schritt 2): Name oder „Niemand“; Auswahl aus `assignees`,
   gefiltert nach `task`. Auch im Entwurf „Aufgabe erstellen“ (nach dem Anlegen als zweiter Aufruf).
2. **Frage und Review** (Karte und „Für dich“): Zeile „Für <Name>“; „Weitergeben“ mit Auswahl (`question` bzw. `review`).
   Bei benannter Review ist „Weitergeben“ nur für diese Person und `manage` aktiv (`not_the_reviewer`); Entscheidungsknöpfe
   für andere ausgeblendet mit dem Hinweis „Entscheidet: <Name>“.
3. **Für dich › Braucht dich** (Konzept Schritt 4): Segment bzw. Filter **„Für mich“ (Standard, wenn nicht leer)** und „Alle“.
   „Für mich“ speist sich aus `/v1/for-me`; „Alle“ bleibt wie heute. Der Zähler der Navigation zählt „Für mich“ plus nicht
   Zugewiesenes (dieselbe Regel wie das Push-Abzeichen).
4. **Listen und Board:** kleines Namenskürzel an Karten mit Zuständigkeit; Filter „Meine“.
5. Texte deutsch über die Sprachdateien; hell und dunkel, Handy und Desktop; E2E: zwei Konten, zuweisen, nur die
   zugewiesene Person sieht den Eintrag unter „Für mich“.

## iOS (Apple-Repository)

1. Reiter/Abschnitt „Für mich“ ganz oben in „Für dich“, gleiche Quelle; Leerzustand „Nichts wartet auf dich“.
2. Push-Tipp öffnet Frage oder Review direkt (Kennungen stehen schon im Payload); Antworten und Annehmen aus der Mitteilung
   bleibt an die bestehende Anmeldung gebunden (Deploy-Konzept §8.9).
3. Zuständig-Feld in der Karte, „Weitergeben“ bei Frage und Review wie in der PWA.
4. Unbekannte Felder dürfen beim Speichern nichts löschen; Zuweisen läuft nur über die `assignee`-Routen.

## Dafür am Server noch nötig (klein, additiv)

- Namen für Leserechte: `assignees` verlangt `edit`; Leser sehen sonst nur IDs. Vorschlag: `assigneeName` in
  `TaskContextDTO` und in den Einträgen von `/v1/for-me`.
- Kommentare: Erwähnung und Zuweisung (`x-draft.commentResponsibility`).
- Mitteilung beim Zuweisen einer Karte (Kategorie `assignments`, heute ohne Auslöser) samt Schalter in den Einstellungen.
- Review mit angekündigter Folge (`x-draft.reviewConsequence`); offen: mehrere Zuständige eines Deploy-Ziels.
- Feed „Für dich“ (`/v1/feed`) und Steuerzentrale zeigen weiterhin alles; Filter „nur meine“ dort mit Konzept Schritt 4.

## Offene Entscheidungen für Lino (erst mit Teil 2)

1. Soll „Für mich“ auch nicht Zugewiesenes zeigen? Empfehlung: nein, dafür „Alle“.
2. Mehrere Zuständige je Review (Deploy-Ziel mit Lino und Designer)? Empfehlung: eine Person je Review, Push an alle
   Zuständigen des Ziels, eine Annahme zählt.
