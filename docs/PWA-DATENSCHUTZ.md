# PWA: Datenschutz der Sprachnachrichten (Karte 1614ABC6, T1-7)

Ort: Einstellungen, Daten & Datenschutz (`/settings/data`), Panel "Sprachnachrichten (Kanal #brain)" zwischen "Daten exportieren" und "Konto sperren und anonymisieren". Backend-Vertrag: `GET/PUT /v1/me/voice-privacy`, `DELETE /v1/channels/brain/messages` (siehe ADR 0030, `contracts/voice.yaml`).

## Verhalten

- Einwilligung (Checkbox, `voice-consent`) mit Datum (`voice-consent-at`). Zurücknahme schaltet "Audio behalten" serverseitig aus; die UI folgt der Antwort.
- Fristen (`voice-periods`) stammen aus `retention` der Antwort (Eingang 24 Stunden, Antwort 7 Tage, Audio behalten 30 Tage), keine festen Zahlen in der UI. Transkripte bleiben bis zum Löschen.
- "Audio behalten (bis zu 30 Tage)" (`voice-keep-audio`) ist ohne Einwilligung deaktiviert, Hinweis `voice-keep-hint`. Das Backend prüft trotzdem (409 `consent_required`).
- Zähler `voice-count` (Attribute `data-messages`, `data-audio`; Texte `voice-count-messages`, `voice-count-audio`).
- "Sprachverlauf löschen …" (`voice-delete-start`) öffnet den Dialog `voice-delete-dialog` (`voice-delete-cancel` mit Startfokus, `voice-delete-confirm`); Text: unwiderruflich, Export vorher empfehlen. Danach Meldung in `voice-status` (`role=status`), Fokus dorthin, Button deaktiviert, wenn nichts mehr gespeichert ist.
- Änderungen werden nacheinander gespeichert (Warteschlange), damit Tastaturfokus und schnelle Doppelklicks nicht verloren gehen.

## Code

- Logik (rein, getestet in `web/tests/voicePrivacy.test.ts`): `web/src/lib/voicePrivacy.ts`.
- Komponente: `web/src/lib/components/settings/VoicePrivacyPanel.svelte`, eingebunden in `DataPage.svelte`. Texte: `web/src/lib/i18n/de-voice-privacy.ts` (`settings.data.voice.*`, `error.consent_required`).
- Für 320 px bei 200 % Schrift: Umbruchklassen an `Panel` (h3), `PageHeader` (h2) und den Buttons der Daten-Seite.

## E2E

`web/e2e/voice-privacy.spec.ts` braucht ein Backend mit den Endpunkten oben und eine frische Datenbank (Bootstrap im Test):

    E2E_BASE_URL=... npx playwright test e2e/voice-privacy.spec.ts --project=chromium

Screenshots (hell/dunkel; 1280, 390, 320, 320 mit 200 % Text, Dialog) nach `$E2E_SHOTS` (Standard: `voice-privacy` im Temp-Verzeichnis). `scripts/e2e-ci.sh` nimmt neue Specs automatisch in der Chromium-Liste auf, keine Ergänzung nötig.
