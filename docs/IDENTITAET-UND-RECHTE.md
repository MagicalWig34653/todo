# Identität und Berechtigungen

## Login

Bestätigt: Passkeys sind der primäre Weg. Benutzername und Passwort sind nachrangig und serverseitig abschaltbar.

Vorgeschlagene Oberfläche: Hauptaktion „Mit Passkey anmelden“; „Andere Anmeldemethode“ zeigt Passwort nur, wenn der Server es erlaubt. Ein Capability-Endpunkt liefert die aktuell verfügbaren Wege. Der Server prüft die Einstellung selbst bei jedem betreffenden Vorgang; Ausblenden allein genügt nicht.

Mehrere benannte Passkeys pro Konto, einzelner Widerruf, Sitzungsverwaltung und klarer Wiederherstellungsweg. Registrierung, erste Servereinrichtung und Einladung müssen vor Implementierung festgelegt werden. Arbeitsannahme: einmaliger Bootstrap für die erste Administration, danach Einladungen; öffentliche Selbstregistrierung bleibt optional.

Normale Passwortanmeldung und Recovery sind getrennte Funktionen. Timetracks Rückfallpasswort erzeugt nur eine eingeschränkte Recovery-Sitzung und darf nicht als fertige normale Passwortanmeldung ausgegeben werden.

Passwortanlage/-änderung und Recovery benötigen passende serverseitige Regeln. Sichere Hashfunktion, Limits und Widerruf berücksichtigen. Konfigurationsänderungen definieren auch das Verhalten vorhandener Passwörter und offener Anmeldeversuche. Abschalten des Passwort-Logins soll nicht versehentlich sämtliche Recovery-Wege abschalten.

Native Passkeys und PWA sollen zur gleichen Identität gehören. RP-ID, Origins, Associated Domains und AASA früh festlegen und auf echten Geräten prüfen. Watch-Anmeldung und Sitzungsübernahme separat entwerfen.

## Projekte und Teams

Keine fachliche Pflichttrennung nach Privat/Arbeit. Ein Projekt gehört als Arbeitsannahme einer Person oder einem Team. Teams bestehen aus Mitgliedern und können gezielt Projektzugriff erhalten. Persönliche Projekte werden durch Teammitgliedschaft nicht automatisch sichtbar.

Teams sind keine zwingende zusätzliche Ebene über jeder Projektstruktur. Teamadministration und Projektzugriff sind unterschiedliche Rechte.

Vorgeschlagene Projektrollen:

| Rolle | Rechte |
| --- | --- |
| Lesen | Projekt, Aufgaben, Kommentare und erlaubte Anhänge lesen |
| Kommentieren | Zusätzlich Kommentare und Antworten verfassen |
| Bearbeiten | Aufgaben und Inhalte bearbeiten |
| Verwalten | Projekteinstellungen und Freigaben verwalten |

Eigentümerwechsel, Löschen, Teamverwaltung und Agentenstart als eigene Fähigkeiten spezifizieren, statt alles aus einem Rollenrang abzuleiten.

## Vererbung – vorgeschlagene Regel

Unterprojekte übernehmen standardmäßig Freigaben. Ein explizit eingeschränktes Projekt unterbricht die Vererbung; direkt berechtigte Personen/Teams bleiben gemäß klar definierter Regel zugelassen. Diese Regel vor Implementierung in einer ADR und einer Zugriffsmatrix festschreiben.

Beim Teilen, Verschieben oder Ändern der Vererbung die resultierende Sichtbarkeit zeigen. Ein Zugang nur zu einem Unterprojekt gibt keinen Zugriff auf private Geschwister oder Inhalte der Eltern. Die Navigation muss solche isolierten Freigaben unterstützen.

Rechte auf Kommentare, Suche, Benachrichtigungen, Dateivorschauen, Exporte und MCP-Antworten folgen den Fachobjekten. Auch Zähler und verknüpfte Objektnamen dürfen keine versteckten Inhalte verraten.

## Agenten und OAuth

Menschlicher Login, MCP-OAuth und die Anmeldung bei einem KI-Anbieter sind getrennte Rollen. OAuth erlaubt Zugriff auf diese Anwendung und stellt keinen Claude-Zugang bereit.

Wirksamer Agentenzugriff ist die Schnittmenge aus Benutzerrechten, OAuth-Scopes, explizit zugelassenen Projekten und Runner-Freigaben. OAuth-Projektfreigaben dürfen nicht allein durch einen projektübergreifenden Scope ersetzt werden.

„Aufgabe bearbeiten“ erlaubt nicht automatisch die Ausführung von Code auf einem Mac. Projekt-/Runner-Einstellungen steuern Start, zulässige Aktionen und notwendige Bestätigungen. Erste lokale Ordnerfreigabe erfolgt am Mac. Ein Agent darf seine eigenen Rechte nicht erweitern.

OAuth-Consent zeigt Client, Aktionen und Projekte; Grants und Runner sind einzeln widerrufbar. PKCE, Discovery, Token-Bindung an die Resource, Rotation und Wiederverwendungserkennung gegen die dann aktuelle MCP-Spezifikation prüfen. Timetracks Implementierung ist eine Referenz, kein ungeprüft aktueller Standard.

Bei Rechteentzug werden neue Zugriffe und Aufträge verhindert. Bereits laufende lokale Arbeit muss ein definiertes Stop-/Abgleichverhalten haben; ein Serverwiderruf kann bereits erfolgte lokale Änderungen nicht rückgängig machen.
