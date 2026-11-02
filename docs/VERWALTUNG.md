# Einstellungen, Hilfe und Verwaltung (PWA)

Stand 31.10.2026. Struktur der Einstellungen, des Hilfebereichs und der Verwaltung in der PWA sowie eine Ist/Soll-Gegenüberstellung der Verwaltungsfunktionen. Vorlage für die Gliederung ist die Einstellungsstruktur der Zeiterfassungs-PWA (Referenz, nur gelesen: Gruppen links, eine Beschreibungszeile je Eintrag, Verwaltung nur für Administratoren); Design und Texte sind eigenständig.

## Aufbau in der PWA

| Pfad | Inhalt | Quelle im Code |
|---|---|---|
| `/settings` | Landing: alle Bereiche mit je einer Beschreibungszeile, Suche; mobil Liste, dann Detail | `web/src/lib/settingsNav.ts`, `SettingsView.svelte` |
| `/settings/profile` | Anzeigename, Benutzername, Rolle, Konto-ID | `settings/ProfilePage.svelte` |
| `/settings/passkeys` `recovery` `sessions` | Sicherheit | `settings/*Page.svelte` |
| `/settings/appearance` | Hell/Dunkel, Akzent, Glow, Transparenz | `AppearanceSettings.svelte` |
| `/settings/notifications` `email` | Push-Einstellungen, E-Mail-Adresse | `NotificationSettings.svelte`, `EmailSettings.svelte` |
| `/settings/permissions` | Wer greift worauf zu | `AccessOverview.svelte` |
| `/settings/connections` `runner` `mcp` | OAuth-Verbindungen, Runner-Geräte (Verweis auf Agenten), Claude Code verbinden | `OAuthGrants.svelte`, `settings/RunnerPage.svelte`, `help/ClaudeConnect.svelte` |
| `/settings/data` | Datenexport (JSON) und „Konto sperren und anonymisieren“ mit zweistufiger Bestätigung | `settings/DataPage.svelte`, `accountData.ts` |
| `/settings/admin-*` | nur Administratoren: `accounts`, `invitations`, `system` sowie die **Server-Einstellungen** (ADR 0025, [KONFIGURATION.md](KONFIGURATION.md)): `server` (Überblick, Schlüssel, Änderungsprotokoll), `mail`, `push`, `storage`, `sign-in`, `limits`, `live`, `cleanup`, `instance`, `apple` | `settings/Admin*.svelte`, `settings/Server*.svelte` |
| `/help`, `/help/<page>` | `getting-started`, `shortcuts`, `claude-code`, `agent-manual`, `about` | `helpNav.ts`, `HelpView.svelte`, `help/*` |

Alle URL-Pfade der PWA sind englisch (Entscheidung 2.11.2026; Anzeigetexte bleiben deutsch): `/for-you`, `/today`, `/inbox`, `/upcoming`, `/up-next`, `/search`, `/overview`, `/activity`, `/agents`, `/teams`, `/filter`, `/filter/<id>`, `/labels/<id>`, `/project/<id>[/list|board|overview|comments]`, `/task/<id>`, `/settings`, `/help`. Die Testids (`settings-link-<id>`) und i18n-Schlüssel behalten die internen deutschen Ids; die Zuordnung Id zu URL-Segment steht in `SETTINGS_SLUGS` (`settingsNav.ts`) und `HELP_SLUGS` (`helpNav.ts`).

Alte Pfade (weiter gültig, werden beim Start per `history.replaceState` auf den englischen Pfad umgeschrieben; Lesezeichen, Mail-Links, App-Deep-Links, Plugin-Anleitung): `/fuer-dich`, `/heute`, `/eingang`, `/anstehend`, `/als-naechstes`, `/suche`, `/ueberblick`, `/aktivitaet`, `/agenten`, `/projekt/<id>/liste|ueberblick|kommentare`, `/aufgabe/<id>`, `/einstellungen[/<bereich>]`, `/hilfe[/<seite>]`, `/konto[/<bereich>]` (`/konto/verwaltung` wird `/settings/admin-accounts`). Umsetzung: `routing.ts` (`LEGACY_SIMPLE`, `LEGACY_SUBS`), `normalizeArea`/`LEGACY_AREAS`, `normalizeHelpArea`. Das Backend liefert für alle diese Pfade den SPA-Fallback (keine reservierten Segmente betroffen); Mail-Links nutzen nur `/confirm-email` und `/recover`.

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
| Konten verwalten | **gebaut (2.11.2026):** Liste mit Status (Aktiv/Gesperrt/Anonymisiert), Administratorrolle, Sperren/Entsperren/Anonymisieren (`POST /v1/admin/users/{id}/disable|enable|anonymize`, Details unten) | Projekte gesperrter Konten übertragen (siehe unten) | erledigt |
| Einladungen | **Liste und Zurückziehen gebaut (1.11.2026):** `GET /v1/invitations` (open/used/expired, ohne Code), `DELETE /v1/invitations/{id}` (benutzt: 409), Erzeugen liefert zusätzlich `id` | Gültigkeit wählen, Versand per Mail | 2 (Rest) |
| Recovery | Admin stellt Code aus (`POST /v1/identity/accounts/{id}/recovery`), optional per Mail | Konto aus Liste wählen statt ID einfügen | 3 (hängt an Kontenliste) |
| Mail | **gebaut (31.10.2026):** Zugangsdaten, Absender, Test-Mail in der PWA (`verwaltung-mail`), Umgebung hat Vorrang | - | erledigt |
| APNs | **gebaut:** Key-ID, Team-ID, Bundle-IDs, .p8-Inhalt (verschlüsselt), Push-Test (`verwaltung-push`) | - | erledigt |
| Speicher/Anhänge | **gebaut:** Ablage (Datenbank/S3), S3-Zugang, Limit, Speicher-Prüfung (`verwaltung-speicher`) | Verbrauch je Konto | 5 |
| Module | nicht vorhanden (Todolino kennt keine abschaltbaren Module) | nicht geplant | - |
| Sitzungen | eigene Sitzungen anzeigen/beenden (PWA); fremde Sitzungen nicht | Admin: Sitzungen eines Kontos beenden | 6 |
| API-Tokens | OAuth-Verbindungen für KI-Clients (anzeigen, widerrufen); keine persönlichen Tokens | persönliche API-Tokens mit Scopes | 6 |
| Passkeys | eigene verwalten (PWA); fremde nicht | Admin: Passkeys zurücksetzen (Recovery deckt den Notfall) | 7 |
| Exporte / Datenschutz | **gebaut (2.11.2026):** `GET /v1/me/export` (JSON: Konto, eigene Projekte, Aufgaben, Kommentare, Labels; ohne Geheimnisse; höchstens 20 MiB, sonst 413 `export_too_large`) und `POST /v1/me/anonymize` (`{confirm:"ANONYMIZE"}`) | ZIP mit Anhängen, geteilte Inhalte, Auskunft | 2 (Rest) |
| Server-Version | `/health/ready` liefert keine Versionsnummer | `version` und `build` im Health- oder Capabilities-Dokument | 4 |
| Änderungsprotokoll | keines; Verweis auf den Commit-Verlauf | `CHANGELOG.md` und Anzeige unter „Über Todolino“ | 6 |
| Profil bearbeiten | Anzeigename und Rolle nur lesbar | Anzeigename ändern | 3 |

Alle „Ist“-Angaben stammen aus `contracts/*.yaml` und `Sources/TodoKit` (Stand 31.10.2026). Die PWA zeigt für jede Lücke auf der betreffenden Seite „Backend noch nicht vorhanden“. Es wurden keine neuen Backend-Funktionen gebaut.

## Konten sperren und anonymisieren (Nutzerentscheidung 1.11.2026, gebaut 2.11.2026)

Es wird nichts gelöscht. Konten werden gesperrt und anonymisiert; Aufgaben, Kommentare und Projekte bleiben.

- **Sperren** (`disabled_at`, `disabled_by` am Konto, umkehrbar): löscht alle Sitzungen, Anmeldeherausforderungen, Recovery-Codes und offene Einladungen des Kontos, widerruft OAuth-Grants (MCP-/Refresh-Token ungültig), sperrt Runner- und Push-Geräte, bricht offene Agenten-Jobs des Kontos oder auf dessen Geräten ab und sperrt die Läufe. Anmeldung (Passkey, Passwort, Recovery) liefert 403 `account_disabled`; eine bestehende Sitzung liefert 401 `account_disabled`. Neue Freigaben und Teameinladungen an gesperrte Konten: 409 `account_disabled`; die Verzeichnissuche blendet sie aus.
- **Entsperren** nur ohne Anonymisierung (sonst 409 `account_anonymized`); beendete Sitzungen und widerrufene Grants kommen nicht zurück.
- **Anonymisieren** (`anonymized_at`, unumkehrbar, idempotent): sperrt zusätzlich und setzt den Namen auf „Ehemaliges Mitglied“; entfernt Benutzername, Passwort-Hash, Passkeys, E-Mail-Adresse und -Verifizierungen, Mail-Warteschlange, Push-Geräte, -Einstellungen und -Warteschlange, Runner-Pairings und -Token; ersetzt den Namen in Audit-Einträgen; entzieht die Administratorrolle. Weil der Name im Konto selbst ersetzt wird, zeigen Listen, Kommentare, Teams und Feed nie Rohdaten.
- **Schutz:** der letzte aktive Administrator ist nicht sperrbar (409 `last_admin_required`); über die Admin-Route nie das eigene Konto (409 `cannot_lock_self`, dafür gibt es die Selbstbedienung). `setAdmin` zählt nur aktive Administratoren. Audit-Schlüssel `admin.account` (Aktion `account`, Detail `disabled|enabled|anonymized:<Konto-ID>`).
- **Selbstbedienung:** `POST /v1/me/anonymize` mit `{confirm:"ANONYMIZE"}` (ohne Bestätigung 400 `confirmation_required`); die PWA verlangt zwei Schritte und das Eintippen von „ANONYMISIEREN“. `GET /v1/me/export` liefert den Datenexport.
- **Offen:** Teams ohne aktiven Admin bleiben bestehen; Export enthält keine Anhänge und keine fremden, mit dem Konto geteilten Inhalte; Wiederaufnahme eines Kontos nach Anonymisierung ist bewusst nicht vorgesehen. Der CLI-Befehl `delete-account` (ADR 0019) bleibt als Betreiberwerkzeug bestehen.
- **Projekte übertragen (gebaut 2.11.2026):** Gesperrte oder anonymisierte Konten behalten ihre Projekte, können sie aber nicht mehr verwalten. Admin (Verwaltung > Konten, Aktion „Projekte übertragen“, nur wenn `ownedProjects` > 0) wählt Projekte und ein Ziel (Person über PersonPicker oder Konto-ID, Team aus `GET /v1/admin/teams`). API: `GET /v1/admin/users/{id}/projects` (id, name, parentID, parentName, taskCount; 409 `account_not_disabled` für aktive Konten), `POST /v1/admin/users/{id}/transfer-projects` mit `{to:{type,id}, projectIDs?}` (leer = alle). Regeln: wirksamer Eigentümer ist das `ProjectSharing`-Overlay vor `projects.owner_id`; Übertragung setzt `ownerType/ownerID` wie `PUT /projects/{id}/owner` (eine Transaktion unter Sharing-Sperre), widerruft Runner-Bindungen und offene Jobs des früheren Eigentümers (`AgentService.revokeRunnerAccess`) und schreibt Audit `admin.transfer` (Aktion `account`, Detail `transfer:<alt>:<typ>:<ziel>:<anzahl>`). Ziel: aktives Konto (sonst 409 `transfer_target_disabled`) oder Team mit mindestens einem angenommenen aktiven Admin (sonst 409 `team_without_active_admin`). Unterprojekte folgen dem Elternprojekt nur, wenn das gesperrte Konto sie ebenfalls besitzt; fremde Kinder bleiben. Nicht besessene IDs: 409 `project_not_owned`. Keine Ausweitung: Grants anderer Personen bleiben unverändert, das alte Konto bleibt gesperrt. Code: `Maintenance/ProjectTransfer.swift`, `settings/ProjectTransferDialog.svelte`.
