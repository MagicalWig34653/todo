# Todoist-Vergleich und Roadmap-Empfehlung

Stand: 31.10.2026 (Abrufdatum aller Quellen). Reine Recherche, keine Code-Änderung. Todolino hat kein Paywall-Konzept (Selbsthosting, alles frei); die Spalte „Todoist“ dient nur dazu, den Funktionsumfang einzuordnen, den Nutzer bei Todoist hinter der Bezahlschranke erleben. Es werden keine Todoist-Texte, -Grafiken oder -Marken übernommen; Todolino braucht eigenes Design und eigene Formulierungen.

## 1. Todoist: Pläne und Preise

Quelle: <https://www.todoist.com/pricing> (abgerufen 31.10.2026; Preise in USD, Business zzgl. lokaler Steuer). Die Planbezeichnungen dort: Beginner (kostenlos), Pro, Business.

| Plan | Monatlich | Jährlich |
| --- | --- | --- |
| Beginner | 0 | 0 |
| Pro | 7 USD | 5 USD/Monat bzw. 60 USD/Jahr |
| Business | 10 USD je Nutzer | 8 USD je Nutzer/Monat bzw. 96 USD/Jahr |

Limits und Funktionen laut Pricing-Seite (gleiche Quelle):

| Merkmal | Beginner | Pro | Business |
| --- | --- | --- | --- |
| Persönliche Projekte | 5 | 300 | 300 je Mitglied |
| Dateigröße je Upload | 5 MB | 100 MB | 100 MB |
| Benutzerdefinierte Filter | 3 | 150 | 150 je Mitglied |
| Personen je persönlichem Projekt | 5 | 5 | 5 |
| Fälligkeit, Priorität, Unteraufgaben, einfache Erinnerungen | ja | ja | ja |
| Eigene (mehrere) Erinnerungen, Aufgabendauer, Deadlines | nein | ja | ja |
| Listenansicht | ja | ja | ja |
| Board-Ansicht | ja | auch für Label-/Filteransichten | auch Teamprojekte |
| Kalenderansicht | nein | ja | ja, auch Teamprojekte |
| Wiederkehrende Fälligkeiten, Labels, Beschreibungen, Produktivitätsansicht, 90+ Integrationen | ja | ja | ja |
| Aktivitätsverlauf | 1 Woche | vollständig | vollständig |
| Automatische Backups | nein | ja | ja |
| Themes | 4 | 8 | 8 |
| KI: Filter Assist | ja | ja | ja |
| KI: Task Assist, Email Assist | nein | ja | ja |
| KI: Ramble (Spracheingabe) | begrenzte Sitzungen | unbegrenzt | unbegrenzt |
| Team-Workspace, Team-Aktivitätsprotokoll, Teamprojekte (bis 500), 250 Personen je Teamprojekt, bis 1.000 Mitglieder/Gäste, Ordner, Rollen/Rechte, zentrale Abrechnung, geteilte Vorlagen | nein | nein | ja |
| Projektvorlagen | ja | ja | ja plus geteilte Vorlagen |

Zuverlässigkeit: Die Pricing-Seite wurde per Abruf in eine Zusammenfassung umgesetzt (kleines Modell, nicht wörtlich). Zahlen sind plausibel und konsistent mit dem Bekannten, sollten aber vor einer Entscheidung auf der Live-Seite gegengeprüft werden. Die Hilfeseite „plans-and-pricing-comparison“ lieferte keine Tabelle.

## 2. Todoist: Funktionsdetails aus dem Help Center

| Thema | Beleg | Plan / Unsicherheit |
| --- | --- | --- |
| Filtersyntax: `&`, `\|`, `!`, Klammern, Komma (mehrere Listen), `search:`, `%label` (`@` läuft Ende 2026 aus), `#projekt`, `##` inkl. Unterprojekte, `/abschnitt`, `no date`, `overdue`, `p1`–`p4`, `assigned to:`/`assigned by:`, `subtask` | <https://www.todoist.com/help/articles/introduction-to-filters-V98wIH> | Filter in allen Plänen, Anzahl begrenzt (3/150), Kalenderlayout für Filterergebnisse nur Pro/Business |
| Wiederkehrend: `every`, `every!` (ab Erledigung), `every other`, `starting`, `ending/until`, `for`, Uhrzeiten, Wochentagslisten, Feiertagsnamen; nur ein `every`-Muster je Aufgabe | <https://www.todoist.com/help/articles/introduction-to-recurring-dates-YUYVJJAV> | alle Pläne |
| Natürliche Spracheingabe im Schnellerfassen (Web „Quick Add“, mobil „Dynamic Add“): Datum, Wiederholung werden erkannt und hervorgehoben | gleiche Seite | alle Pläne; Czech/Turkish nicht unterstützt |
| Erinnerungen: automatisch (aus Datum+Uhrzeit), eigene, wiederkehrend, ortsbasiert; `!`-Kürzel in Quick Add; Snooze nur iOS/Android; dringende Erinnerungen iOS 26+/Android | <https://www.todoist.com/help/articles/introduction-to-reminders-9PezfU> | Mehrere eigene Erinnerungen und `!`-Kürzel: Pro/Business. Ortsbasierte Erinnerungen: nur iOS/Android; Planzuordnung **unsicher** (Artikel nennt keine, Pricing-Seite führt sie nicht auf) |
| Kalenderlayout: Woche/3 Tage/Monat, Drag-and-drop, Aufgaben ohne Datum, Deadline-Chips, Zukunftstermine wiederkehrender Aufgaben, Färbung nach Priorität/Label/Projekt | <https://www.todoist.com/help/articles/use-the-calendar-layout-in-todoist> | Pro/Business |
| Kalenderfeed (einseitig, je Projekt ein Kalender) | <https://todoist.com/hc/articles/208789889> (nur über Suchtreffer bestätigt) | laut Suchtreffer alle Pläne bzw. Pro, **unsicher** |
| Google-Calendar-Integration, nach Doist-Eigenangabe zweiseitig; Dritte widersprechen teils | <https://todoist.com/integrations/apps/google-calendar> (Suchtreffer, nicht selbst abgerufen) | Planbindung **unsicher** |
| Karma/Produktivität: Punkte, Tages-/Wochenziele (Standard 5/25), Streaks, Urlaubsmodus, Streak-Wiederherstellung (3x), Level bis „Enlightened“ | <https://www.todoist.com/help/articles/OgWkWy> | alle Pläne; Pro zusätzlich Wochenverlauf-Diagramme |
| E-Mail an Todoist: Weiterleitung an Projektadresse erzeugt Aufgabe, an Aufgabenadresse einen Kommentar; Email Assist formuliert Titel um | <https://todoist.com/help/articles/360000249160> | Weiterleitung selbst vermutlich alle Pläne (**unsicher**), Email Assist Pro/Business |
| Apple Watch: Aufgaben hinzufügen/erledigen, Synchronisierung über iPhone | <https://www.todoist.com/help/articles/use-todoist-on-apple-watch-vTvnTJFz> | Siri auf der Watch laut Forumsbericht unzuverlässig, nicht offiziell belegt |
| KI: Ramble (Diktat), Todoist Assist; Wear-OS-Beta | <https://todoist.com/help/articles/21532676695580> | siehe Tabelle oben |
| Integrationen: Kategorien AI-Agents (u. a. Claude, ChatGPT), Automation, Kalender, E-Mail, Messaging, Zeiterfassung u. a.; Google Calendar, Outlook, Slack, Teams, Trello, Jira, Reclaim.ai, Sunsama | <https://www.todoist.com/integrations> | Planbindung nicht angegeben; Gmail/Zapier auf der Seite nicht genannt (aus Allgemeinwissen vorhanden, hier **nicht belegt**) |
| Aktivitätsverlauf 1 Woche (Beginner) bzw. vollständig | Pricing-Seite | Details der Aktivitätsfunktion nicht abgerufen (Seite lieferte nur die Hilfe-Startseite) |

Nicht belegt, bewusst nicht behauptet: Widgets, Siri-Shortcuts, Zeitblockierung als eigene Funktion, Kommentar-/Dateilimits über die Upload-Größe hinaus, Rollenmodell im Detail, Gmail/Outlook-Add-ins, Aufgabenvorlagen im Detail, Offline-Verhalten. Hierzu sind weitere Hilfeseiten zu lesen, bevor man darauf aufbaut.

## 3. Todolino: Ist-Stand (nach Code- und Dokuprüfung, 31.10.2026)

Grundlage: `docs/STATUS.md`, `docs/PRODUKT.md`, `contracts/`, `web/src/lib/components`, Apple-Repository `App/Shared` per Stichwortsuche. Dokumentierte Planung gilt nicht als vorhanden.

- Vorhanden: frei verschachtelte Projekte mit projektspezifischen Spalten und Board, Aufgaben mit Priorität (0–3), Fälligkeit/geplanter Zeit, Unteraufgaben-Struktur, Kriterien, Abhängigkeiten, Meilensteine, Labels (konto-privat), gespeicherte Kriterien und Suche, Kommentare, Aktivität, Anhänge (Standard 10 MiB, bis 128 MiB konfigurierbar, DB oder S3), Teams/Freigaben mit Rollenvererbung, Passkey, OAuth/MCP (29 Tools), Agentenaufträge, Steuerzentrale, Runner, Claude-Code-Plugin, Sync mit Cursor und Aufbewahrung, Darstellung (Hell/Dunkel/Akzent), PWA, iOS/macOS-App, TestFlight.
- Teilweise: Wiederholung (daily/weekly/monthly mit Intervall, Zeitzone, Ende; Vertrag `planning-ext.yaml`), Erinnerungen (Liste absoluter Zeitpunkte je Aufgabe, aber laut STATUS keine Zustellung/kein Push), Schnellerfassung (vorhanden, aber ohne natürliche Sprachanalyse), Watch (laut Apple-Status nur Platzhalter, Stand dort 26./27.10.), Offline (Sync-Engine vorhanden; Offline-Erfassung laut Apple-Status früher nicht vorhanden, aktueller Stand nicht neu geprüft), Vorlagen (nur Spaltenvorlagen), Datensicherung (Server-Backup/Restore im Betrieb, kein Nutzerexport geprüft).
- Fehlt: Filter-Abfragesprache, Kalenderansicht, Kalenderfeed/-Sync, ortsbasierte Erinnerungen, Push-Benachrichtigungen, E-Mail-an-Aufgabe, Widgets/App Intents/Siri, Karma/Produktivitätsansicht, Spracheingabe, Zeitblockierung, Aufgabenvorlagen, Deadline als eigenes Feld (Fälligkeit und geplante Bearbeitung sind getrennt, das deckt Deadline teilweise ab), Selbstbedienungs-Kontolöschung.

## 4. Vergleichstabelle

Aufwand: S = Tage, M = 1–2 Wochen, L = mehrere Wochen oder externe Abhängigkeit.

| Feature | Todoist (Free/Pro/Business) | Todolino | Aufwand | Empfehlung |
| --- | --- | --- | --- | --- |
| Projekte, Unterprojekte | 5 / 300 / 300 je Mitglied | vorhanden, unbegrenzt | – | Alleinstellungsmerkmal betonen |
| Abschnitte/Spalten je Projekt | Abschnitte; Board in allen Plänen | vorhanden, projektspezifische Spalten | – | Kern, weiter ausbauen |
| Board | Free (eingeschränkt auf Pro für Filter/Label) | vorhanden | – | – |
| Kalenderansicht | Pro | fehlt | M | Mittel: Monats-/Wochenansicht aus `plannedAt`/`dueAt` |
| Filtersprache | alle Pläne, 3/150 Filter | teilweise (gespeicherte Kriterien, Suche) | M | Hoch: kleine eigene Syntax (Projekt, Label, Priorität, Datum, Zuweisung) |
| Labels | alle | vorhanden | – | – |
| Erinnerungen (zeitbasiert) | Free einfach, Pro mehrere | teilweise (Daten ja, Zustellung nein) | M–L | Hoch: Zustellung über Web Push/APNs |
| Ortsbasierte Erinnerungen | nur iOS/Android, Plan unsicher | fehlt | L | Niedrig; braucht Standortfreigabe und APNs |
| Wiederkehrende Aufgaben | alle | teilweise (3 Frequenzen) | S–M | Hoch: Wochentage, „ab Erledigung“, Monatsregeln |
| Natürliche Spracheingabe | alle | fehlt | M | Hoch: deutsche Datums-/Wiederholungserkennung im Schnellerfassen, eigener Parser |
| Kommentare | alle | vorhanden | – | – |
| Dateien, Upload-Limit | 5 MB / 100 MB | vorhanden, 10 MiB Standard, konfigurierbar | – | Kein Handlungsbedarf |
| Aktivitätsverlauf | 1 Woche / voll | vorhanden | – | – |
| Vorlagen | alle, geteilt in Business | teilweise (Spalten) | M | Mittel: Projekt-/Aufgabenvorlagen auch für Agenten-Workflows |
| Kalenderfeed (ics) | je Projekt, einseitig | fehlt | S–M | Hoch: Lese-Feed mit Token, kein OAuth nötig |
| Zweiseitiger Kalender-Sync | Google/Outlook | fehlt | L | Niedrig; externes OAuth, Datenschutz |
| Zeitblockierung | Kalender + Dauer (Pro) | fehlt | M | Mittel, nach Kalenderansicht und Dauerfeld |
| E-Mail an Todoist | Weiterleitung | fehlt | L | Niedrig; braucht Mailserver/Domain |
| Integrationen (Slack, Gmail, Zapier …) | 90+ | fehlt (dafür MCP/OAuth) | L | Niedrig; Webhooks als Ersatz |
| Widgets | vorhanden | fehlt | M | Hoch für Apple (Heute, Schnellerfassung, Fragen) |
| Apple Watch | vorhanden | teilweise (Platzhalter) | M | Hoch: Erfassen/Abhaken |
| Siri/Kurzbefehle | Watch unsicher | fehlt | M | Hoch via App Intents |
| Karma/Produktivität | alle, Pro mehr Diagramme | fehlt | M | Niedrig; später „erledigt je Woche“ |
| Themes | 4 / 8 | vorhanden (Hell/Dunkel/Akzent) | – | – |
| Offline | vorhanden | teilweise | M–L | Hoch: Offline-Erfassung nativ und PWA |
| Zuweisen, Teamrollen | Business | vorhanden (Teams, Rollen, Vererbung) | – | Vorteil gegenüber Free/Pro |
| KI-Assistent | Pro/Business | stärker: Claude Code, MCP, Runner | – | Kernvorteil |
| Archivierung/Backups | Pro: Auto-Backups | Betrieb: Backup/Restore, Nutzerexport offen | S–M | Mittel: Export (JSON/CSV) für Nutzer |
| Kontolöschung/DSGVO | – | Lücke (STATUS) | S | Hoch, Pflicht vor Produktivbetrieb |

## 5. Priorisierte Roadmap (Top 10)

Leitlinie: Nutzerkern zuerst (Projekte mit eigenen Spalten, Steuerzentrale, Passkey, MCP), danach das, was Alltagsnutzung gegenüber Todoist bremst.

1. Erinnerungszustellung (Web Push plus APNs): ohne sie ist das vorhandene Feld wertlos; zugleich Grundlage für Push bei Agentenfragen und Reviews (laut STATUS offene Lücke).
2. Push für Agentenfragen/Reviews (gleiche Infrastruktur): stärkt die Steuerzentrale direkt.
3. Wiederholungsregeln erweitern (Wochentage, „ab Erledigung“, monatlicher Stichtag): kleine Vertragsänderung, hoher Alltagsnutzen.
4. Filtersprache mit gespeichertem Filter: macht „gespeicherte Kriterien“ mächtig; auch für Agenten/MCP nutzbar.
5. Schnellerfassung mit deutscher Datumserkennung („morgen 9 Uhr“, „jeden Montag“): eigener Parser, kein Fremdcode.
6. Apple: Widgets und App Intents (Heute, Schnellerfassung, Fragen beantworten) plus Watch-Erfassung: bereits als Empfehlung im STATUS, spricht Mobilnutzung an.
7. Kalenderansicht (Woche/Monat) mit Drag-and-drop und Dauerfeld: danach Zeitblockierung.
8. Lese-Kalenderfeed (ics) pro Konto/Projekt mit Token: günstig, ohne externes OAuth.
9. Nutzerexport und Selbstbedienungs-Kontolöschung: Voraussetzung für verantwortbaren Betrieb.
10. Projekt- und Aufgabenvorlagen (inkl. Agenten-Workflow-Spalten, Abnahmekriterien): Verbindung von Todoist-Komfort und Todolino-Kern.

Bewusst zurückgestellt: ortsbasierte Erinnerungen, zweiseitiger Kalender-Sync, E-Mail-Eingang, Karma, Drittintegrationen (Webhooks/MCP decken den Bedarf eher ab).

## 6. Risiken

- Ortsbasierte Erinnerungen: native Geofencing-Berechtigungen, Hintergrundstandort, App-Store-Datenschutzangaben; ohne APNs nicht zustellbar.
- Push allgemein: APNs-Schlüssel/Team-Konfiguration, Web-Push-VAPID-Schlüssel, Zustellung bei mehreren Replikaten ohne Doppelversand (Idempotenz, Leasing).
- Zweiseitiger Kalender-Sync: externes OAuth (Google/Microsoft), App-Verifizierung, Token-Speicherung, Konfliktregeln; deshalb zuerst nur ics-Lesefeed (Feed-URL ist ein Geheimnis, widerrufbar machen).
- E-Mail-Eingang: eigener Mailserver, Spam, Missbrauch; hoher Betriebsaufwand für Selbsthoster.
- Natürliche Sprache: Locale/Zeitzonen, Sommerzeit, Mehrdeutigkeit; viele Tests nötig, Vorschau vor dem Speichern.
- Wiederholungen mit Zeitzonen und „ab Erledigung“ berühren Sync-Idempotenz und Offline-Konflikte.
- Rechtliches: Todoist-Name, Texte und Grafiken nicht verwenden; Funktionen sind nicht schutzfähig, konkrete Gestaltung schon. Eigene Begriffe und eigenes Design beibehalten.
- Dieses Dokument beruht auf Hilfeseiten, die teils nur über Suchzusammenfassungen vorlagen; Todoist ändert Pläne und Limits häufig.

## 7. Quellen und Qualität

| Quelle | Güte |
| --- | --- |
| <https://www.todoist.com/pricing> | primär, Abruf per Zusammenfassung; hoch |
| <https://www.todoist.com/help/articles/introduction-to-filters-V98wIH> | primär, abgerufen; hoch |
| <https://www.todoist.com/help/articles/introduction-to-recurring-dates-YUYVJJAV> | primär, abgerufen; hoch |
| <https://www.todoist.com/help/articles/introduction-to-reminders-9PezfU> | primär, abgerufen; hoch (Ortserinnerungen ohne Plan) |
| <https://www.todoist.com/help/articles/use-the-calendar-layout-in-todoist> | primär, abgerufen; hoch |
| <https://www.todoist.com/help/articles/OgWkWy> (Karma) | primär über Suchzusammenfassung; mittel |
| <https://todoist.com/help/articles/360000249160> (E-Mail), Apple-Watch-, Ramble-Artikel | primär über Suchzusammenfassung; mittel |
| <https://www.todoist.com/integrations> | primär, abgerufen; mittel (keine Planangaben) |
| Kalenderfeed- und Google-Calendar-Seiten | nur Suchtreffer; niedrig bis mittel |
| Forumsbeitrag zu Siri/Watch | sekundär; niedrig |

Offene Nachprüfungen: Planbindung von Ortserinnerungen, Kalenderfeed und Kalender-Sync, Kommentar-/Dateilimits, Rollenmodell, Vorlagen, Offline, Widgets, Siri.
