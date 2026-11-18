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

## Nachtrag 18.11.2026: Review mit Variantenwahl (Karte 1D9C8B0C, Stufe 1)

Plan: `docs/PLAN-REVIEW-VARIANTEN.md`. Entschieden (Lino/Brain): Die Wahl ist eine Annahme mit Variante, kein eigener Zustand; Variantenbilder sind vorhandene Anhaenge (`attachmentID`); Reihenfolge Backend/MCP, PWA, Apple.

- **Modell:** additive Migration `AddReviewVariants` (`task_reviews.variants` TEXT mit JSON, `chosen_variant_id`, beide nullable). Alte Zeilen und Reviews ohne Auswahl bleiben unveraendert; `ReviewDTO` und `pendingReview` der Karten tragen `variants`, `ReviewDTO` nach der Annahme `chosenVariantID` (Felder fehlen im JSON, wenn leer).
- **Anfordern:** `variants` 2-4 Eintraege `{id, label, description?, attachmentID?}`; id `[a-z0-9-]{1,20}` eindeutig, label 1-60, description <= 500, attachmentID = fertiger Anhang derselben Aufgabe. 422 `invalid_variants` / `invalid_variant_attachment`. Erneutes Anfordern ersetzt die Varianten.
- **Entscheiden:** `accept` auf eine Review mit Varianten braucht `variantID` (422 `variant_required`, `unknown_variant`); `variantID` ohne Varianten oder zusammen mit `request_changes` ist 422 `unexpected_variant` (bewusst streng: `chosen_variant_id` bedeutet nur "angenommen mit dieser Variante"). Die Pruefung laeuft nach allen bisherigen Pruefungen (Eigen-Review, Brain-Mandat, Pflichtzitat, benannter Reviewer), die Reihenfolge der alten Fehler bleibt. Gleicher Fachpfad fuer REST und MCP `decide_review`; Runner-Reviews tragen keine Varianten.
- **Spur:** Chat-Eintrag an der Review "Variante B gewaehlt: <Label>" (ein Buchstabe gross, sonst die id), Feed- und Update-Text der Entscheidung nennen die Wahl; Undo setzt `chosen_variant_id` zurueck, die Varianten bleiben.
- **Sammelfreigabe:** `accept` laesst Reviews mit Varianten aus (Einzelergebnis `invalid`, `reason` `variant_required`), `changes_requested` bleibt moeglich; kein neuer Ergebniscode, damit die Summenstruktur stabil bleibt.
- **Grenzen:** Der Wert der Wahl steht nur in `chosen_variant_id` (kein Verlauf frueherer Wahlen nach Undo); die Anhaenge werden nicht beim Loeschen eines Anhangs aus den Varianten entfernt (die `attachmentID` zeigt dann ins Leere, Clients muessen das tolerieren).
