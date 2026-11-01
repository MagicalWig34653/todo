# Einstellungen, Hilfe und Verwaltung (PWA)

Stand 31.10.2026. Struktur der Einstellungen, des Hilfebereichs und der Verwaltung in der PWA sowie eine Ist/Soll-Gegenüberstellung der Verwaltungsfunktionen. Vorlage für die Gliederung ist die Einstellungsstruktur der Zeiterfassungs-PWA (Referenz, nur gelesen: Gruppen links, eine Beschreibungszeile je Eintrag, Verwaltung nur für Administratoren); Design und Texte sind eigenständig.

## Aufbau in der PWA

| Pfad | Inhalt | Quelle im Code |
|---|---|---|
| `/einstellungen` | Landing: alle Bereiche mit je einer Beschreibungszeile, Suche; mobil Liste, dann Detail | `web/src/lib/settingsNav.ts`, `SettingsView.svelte` |
| `/einstellungen/profil` | Anzeigename, Benutzername, Rolle, Konto-ID | `settings/ProfilePage.svelte` |
| `/einstellungen/passkeys` `wiederherstellung` `sitzungen` | Sicherheit | `settings/*Page.svelte` |
| `/einstellungen/darstellung` | Hell/Dunkel, Akzent, Glow, Transparenz | `AppearanceSettings.svelte` |
| `/einstellungen/benachrichtigungen` `email` | Push-Einstellungen, E-Mail-Adresse | `NotificationSettings.svelte`, `EmailSettings.svelte` |
| `/einstellungen/berechtigungen` | Wer greift worauf zu | `AccessOverview.svelte` |
| `/einstellungen/verbindungen` `runner` `mcp` | OAuth-Verbindungen, Runner-Geräte (Verweis auf Agenten), Claude Code verbinden | `OAuthGrants.svelte`, `settings/RunnerPage.svelte`, `help/ClaudeConnect.svelte` |
| `/einstellungen/daten` | Export/Löschen: ehrlicher Platzhalter | `settings/DataPage.svelte` |
| `/einstellungen/verwaltung-*` | nur Administratoren: `konten`, `einladungen`, `system` sowie die **Server-Einstellungen** (ADR 0025, [KONFIGURATION.md](KONFIGURATION.md)): `server` (Überblick, Schlüssel, Änderungsprotokoll), `mail`, `push`, `speicher`, `anmeldung`, `limits`, `live`, `aufraeumen`, `instanz`, `apple` | `settings/Admin*.svelte`, `settings/Server*.svelte` |
| `/hilfe`, `/hilfe/<seite>` | `erste-schritte`, `tastaturkuerzel`, `claude-code`, `agentenhandbuch`, `ueber` | `helpNav.ts`, `HelpView.svelte`, `help/*` |

Alte Pfade: `/konto` wird zu `/einstellungen`, `/konto/<bereich>` zu `/einstellungen/<bereich>`, `/konto/verwaltung` zu `/einstellungen/verwaltung-konten` (Umleitung beim Start, `routing.ts` und `LEGACY_AREAS`).

Menüs oben rechts: Hilfemenü (Fragezeichen) und Benutzermenü (Avatar mit Einstellungen, Berechtigungen, Verwaltung nur für Admins, Darstellung hell/dunkel/System, Hilfe, Abmelden). Beide liegen im Viewport (gemeinsame `Popover`-Positionierung). Tastaturkürzel: `Q` Schnell-Hinzufügen, `?` Kürzel-Übersicht, `Esc` schließen; G-Kombinationen gibt es nicht.

### Neue Seite einhängen

1. Eintrag in `SETTINGS_GROUPS` (`settingsNav.ts`) mit `id`, Beschriftung und Beschreibung (Schlüssel in `i18n/de-settings.ts`), `adminOnly` für Verwaltung.
2. Eine `{:else if id === '…'}`-Verzweigung in `SettingsView.svelte`.
3. Hilfeseiten analog in `helpNav.ts` und `HelpView.svelte`.
`tests/settings.test.ts` prüft Eindeutigkeit, Beschreibungen und die Sichtbarkeit für Nicht-Admins.

## Wie die PWA Administratoren erkennt

`GET /v1/me` und die Sitzung liefern `isAdmin`. Der erste Konto-Inhaber (Bootstrap) ist Administrator. Die PWA blendet die Verwaltung für alle anderen aus; ein Direktaufruf zeigt nur „Nur für Administratoren“. Maßgeblich ist immer das Backend (`createInvitation` und Recovery verlangen Admin, sonst 403).

## Ist/Soll gegen die Zeiterfassungs-PWA

| Funktion | Ist (Backend und PWA) | Soll | Priorität |
|---|---|---|---|
| Konten verwalten | **Liste und Admin-Rolle gebaut (1.11.2026):** `verwaltung-konten` zeigt alle Konten (`GET /v1/admin/users`), Administratorrolle erteilen/entziehen (`PUT /v1/admin/users/{id}/admin`, letzter Admin bleibt: 409) | Sperren, Löschen | 1 (Rest) |
| Einladungen | **Liste und Zurückziehen gebaut (1.11.2026):** `GET /v1/invitations` (open/used/expired, ohne Code), `DELETE /v1/invitations/{id}` (benutzt: 409), Erzeugen liefert zusätzlich `id` | Gültigkeit wählen, Versand per Mail | 2 (Rest) |
| Recovery | Admin stellt Code aus (`POST /v1/identity/accounts/{id}/recovery`), optional per Mail | Konto aus Liste wählen statt ID einfügen | 3 (hängt an Kontenliste) |
| Mail | **gebaut (31.10.2026):** Zugangsdaten, Absender, Test-Mail in der PWA (`verwaltung-mail`), Umgebung hat Vorrang | - | erledigt |
| APNs | **gebaut:** Key-ID, Team-ID, Bundle-IDs, .p8-Inhalt (verschlüsselt), Push-Test (`verwaltung-push`) | - | erledigt |
| Speicher/Anhänge | **gebaut:** Ablage (Datenbank/S3), S3-Zugang, Limit, Speicher-Prüfung (`verwaltung-speicher`) | Verbrauch je Konto | 5 |
| Module | nicht vorhanden (Todolino kennt keine abschaltbaren Module) | nicht geplant | - |
| Sitzungen | eigene Sitzungen anzeigen/beenden (PWA); fremde Sitzungen nicht | Admin: Sitzungen eines Kontos beenden | 6 |
| API-Tokens | OAuth-Verbindungen für KI-Clients (anzeigen, widerrufen); keine persönlichen Tokens | persönliche API-Tokens mit Scopes | 6 |
| Passkeys | eigene verwalten (PWA); fremde nicht | Admin: Passkeys zurücksetzen (Recovery deckt den Notfall) | 7 |
| Exporte / Datenschutz | nicht vorhanden | Export aller eigenen Daten (JSON/ZIP), Konto löschen mit Frist, Auskunft | 2 |
| Server-Version | `/health/ready` liefert keine Versionsnummer | `version` und `build` im Health- oder Capabilities-Dokument | 4 |
| Änderungsprotokoll | keines; Verweis auf den Commit-Verlauf | `CHANGELOG.md` und Anzeige unter „Über Todolino“ | 6 |
| Profil bearbeiten | Anzeigename und Rolle nur lesbar | Anzeigename ändern | 3 |

Alle „Ist“-Angaben stammen aus `contracts/*.yaml` und `Sources/TodoKit` (Stand 31.10.2026). Die PWA zeigt für jede Lücke auf der betreffenden Seite „Backend noch nicht vorhanden“. Es wurden keine neuen Backend-Funktionen gebaut.
