# ADR 0027 – Review-Entscheidung rückgängig machen

Status: umgesetzt (2.11.2026), SQLite und Chromium geprüft, MariaDB ungeprüft.

## Kontext

Ein versehentliches Annehmen oder „Änderungen anfordern“ setzt die Aufgabe auf erledigt bzw. zurück an den Agenten. Nutzerwunsch: Entscheidung in den ersten Minuten zurücknehmen können.

## Entscheidung

- **Fenster:** `WorkflowLimits.reviewUndoWindow` = 5 Minuten ab `decided_at`, nur auf dem Server erzwungen. Das DTO liefert `undoUntil` (nur bei Personen-Entscheidung, nicht bei Runner-Reviews, nur solange das Fenster offen ist); die PWA zeigt nur die Restzeit.
- **Endpunkt:** `POST /v1/tasks/{id}/review/undo` (`WorkflowService.undoReviewDecision`, gleiche Sperrreihenfolge wie `decideReview`, Recht `edit`). Review geht auf `pending` (Entscheidung, Notiz, Snapshot gelöscht, `version` +1); die Aufgabe bekommt Status und Spalte von vor der Entscheidung zurück (Position ans Spaltenende; fehlt die Spalte, greift die Status-Abstimmung).
- **Snapshot:** additive Migration `AddReviewUndo` (`task_reviews.undo_status`, `undo_column_id`, `undo_task_version`), beim Entscheiden geschrieben; alte Zeilen haben keinen Snapshot und sind nicht rückgängig zu machen (`not_undoable`).
- **Verweigert (409):** `nothing_to_undo` (neueste Review ist nicht entschieden), `not_undoable` (Runner-Review, anderer Entscheider, kein Snapshot), `undo_window_expired`, `already_acted_on`. Letzteres, wenn die Aufgabe seit der Entscheidung geändert wurde (Version weicht ab) oder ein Nicht-Personen-Akteur (Agent/Run) nach dem Entscheidungs-Aktivitätseintrag etwas geschrieben hat (Fortschritt, Frage, Claim, Kommentar, Build). Kein Zugriff auf die Aufgabe: 404 wie überall.
- **Spur:** Aktivität `task.status_changed` und `review.undone`, ein Chat-Eintrag im Review-Chat („Freigabe zurückgenommen.“ / „Änderungswunsch zurückgenommen.“). Der Feed blendet frühere Entscheidungs-Beiträge aus, deren Review wieder `pending` ist.
- **Wiederkehrende Aufgaben:** Beim Annehmen erzeugte Folgeaufgaben werden nicht zurückgenommen (Folgeaufgabe bleibt bestehen); das ist eine bekannte Grenze.
- **PWA:** `ReviewUndoBar` (Knopf „Rückgängig“, Restzeit „noch m:ss“) im Ergebnisabschnitt der Karte und als Toast (`ReviewUndoToast`) nach dem Entscheiden außerhalb des Kartenfensters; Zustand `reviewUndo`.
- **MCP:** keine Änderung. Agenten entscheiden keine Reviews der eigenen Anforderung (`cannot_decide_own_review`) und brauchen kein Undo; ein Agent-Eingriff nach der Entscheidung schließt das Undo ohnehin aus.
