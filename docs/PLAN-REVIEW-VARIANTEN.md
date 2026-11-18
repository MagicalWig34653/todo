# Plan: Review mit Variantenwahl (Karte 1D9C8B0C)

Stand 18.11.2026, Entwurf zur Freigabe durch das Brain. Nichts davon ist umgesetzt, kein Agent gestartet.

## Ziel
Ein Review kann 2–4 benannte Varianten (A/B/…) anbieten. Lino wählt mit einem Tipp, der Agent erhält die Wahl strukturiert. Ergänzt die Sammelfreigabe (9791E2C3, gemergt).

## Vorhandene Arbeit (geprüft, keine Doppelbeauftragung)
- Keine Variantenlogik im Backend, in der PWA oder in TodoCore (Suche nach variant/variants: nur UI-Props in shadcn-Komponenten).
- Branch `agent/reviews-sammelfreigabe` ist vollständig in `main` (0 offene Commits). Nachnutzen: `ReviewDecision.svelte`, `ReviewList.svelte`, `ReviewDTO`, `decideReview(expectedReviewID:)`.
- Karte F96206D5 (Handy-Rechte-Abfragen) ist zurückgestellt und unabhängig.

## Datenmodell (additiv, Vertrag command-center Minor)
- `task_reviews`: neue Spalten `variants` (JSON, nullable, 2–4 Einträge `{id, label, description?, attachmentID?}`) und `chosen_variant_id` (nullable).
- `request_review` (REST + MCP): optional `variants`. Validierung: 2–4, `id` a–d oder kurzer Slug, `label` ≤ 60, `description` ≤ 500, `attachmentID` muss zur Aufgabe gehören und `complete` sein.
- Entscheidung: `accept` mit `variantID` (Pflicht, wenn das Review Varianten hat; sonst 422 `variant_required`; unbekannte ID 422 `unknown_variant`). `request_changes` braucht keine Variante.
- Ohne Varianten ändert sich nichts (rückwärtskompatibel, alte Clients ignorieren die Felder).
- Wahl landet im Verlauf („Lino wählte Variante B: <Label>“), in der Aktivität und in `get_task_context.review`.
- `decide_review` (Brain-Pfad) übernimmt `variantID` und bleibt an Mandat und Pflichtzitat gebunden.
- Handbuch 1.36.0, ADR-Nachtrag, STATUS-Nachtrag.

## Oberfläche
```
┌ Review: Kartenwahl ShowerNow ─────────────────┐
│ Zusammenfassung (1 Satz, bis 4 Punkte)        │
│ ┌─ A ───────────┐  ┌─ B ───────────┐          │
│ │ [Bild]        │  │ [Bild]        │          │
│ │ Windkarte     │  │ Radarkarte    │          │
│ │ kurze Beschr. │  │ kurze Beschr. │          │
│ │ (Wählen)      │  │ (Wählen)      │          │
│ └───────────────┘  └───────────────┘          │
│ [Änderungen anfordern]                        │
└───────────────────────────────────────────────┘
```
- PWA: Auswahlkarten in `ReviewDecision.svelte` und im Karten-Detail; Tastatur (Pfeile/Enter), Bestätigungsschritt wie bei der Sammelfreigabe, Undo-Fenster bleibt.
- Sammelfreigabe: Reviews mit Varianten sind nicht sammelbar (Wahl nötig), Hinweis in der Leiste.
- App (TodoCore + SwiftUI): `ReviewVariant` tolerant dekodieren, gleiche Auswahlkarten; ältere App-Stände zeigen das Review wie bisher.

## Tests (zuerst rot)
- Backend (swift test, SQLite + MariaDB): Validierung der Varianten, `variant_required`, `unknown_variant`, Fremdanhang, Entscheidung mit Wahl speichert `chosen_variant_id`, Undo, Verlauf, `decide_review` mit Mandat und Zitat, Review ohne Varianten unverändert.
- PWA: vitest für Auswahl/Validierung/Anzeige; **E2E** `web/e2e/review-variants.spec.ts` gegen echtes Backend (Muster `reviews-bulk.spec.ts`, Chromium + WebKit): Review mit 2 Varianten + Bild anlegen, in Überblick und Karten-Detail A/B sehen, B wählen, Verlauf zeigt B, Aufgabe `done`, Review `accepted` mit `chosenVariantID`, Sammelfreigabe lässt das Review aus, Review ohne Varianten verhält sich wie vorher, Screenshots nach `docs/screenshots/review-variants`.
- Apple: TodoCore-Tests (Dekodieren mit/ohne Varianten), App-Screenshot.

## Stufen und Aufwand (M)
1. Backend + MCP + Verträge + Handbuch (S–M).
2. PWA + E2E (M).
3. App (M), danach TestFlight-Karte 6C3E3F88.
Je Stufe: Worker (Sonnet, Worktree), eigener Lauf im Hauptcheckout über `sparsam`, Merge `--no-ff` mit Rollback-Ref, Push nach grünen Tests, CI prüfen. Kein Deploy.

## Offene Entscheidungen (Empfehlung zuerst)
1. Wahl = Annahme mit Variante (Empfehlung), nicht ein eigener Zustand `variant_chosen`.
2. Bilder pro Variante über vorhandene Anhänge (`attachmentID`), kein neuer Upload-Weg.
3. Reihenfolge Stufe 1 → 2 → 3, App nach Linos Abnahme der PWA.
