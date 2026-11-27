# ADR 0040: Anmeldungen enden nicht mehr von selbst

Status: angenommen (27.11.2026, Karte FFF3C6AB). Ändert ADR 0036, Entscheidung 1 (Frist 300 s, höchstens 5 Wiederholungen) und die
Laufzeiten aus ADR 0007. Befund und Belege: `docs/belege/befund-anmeldungen-fff3c6ab.md`.

## Kontext

Vorgabe von Lino (Frage 60B0F4E7): „Sorge dafür dass die Anmeldungen nicht immer ablaufen. Das soll nicht. Das ist keine Bank oder
Militär oder so“. Alle Claude-Code-Sitzungen teilen sich eine gespeicherte Anmeldung. Endet die Verbindung, verlieren alle Projekte
gleichzeitig das Board. PWA- und App-Sitzungen endeten fest 30 Tage nach der Anmeldung, auch bei täglicher Nutzung.

## Entscheidung

1. **Verlorene Rotation, ohne Zeitgrenze.** Ein verbrauchtes Refresh-Token wird wieder angenommen, solange **keiner seiner Nachfolger
   benutzt wurde** (außerdem wie bisher: gleicher Client und gleiche Resource, Verbindung aktiv, Token nicht abgelaufen). Das Alter der
   ersten Benutzung zählt nicht mehr. Höchstens **50** Wiederholungen je Token (vorher 5): Jede parallele Sitzung, die denselben
   gespeicherten Stand findet, schickt ihn einmal.
2. **Refresh-Token 90 Tage** (vorher 30) ab der Rotation, die es ausgestellt hat. Access-Token bleibt 15 Minuten.
3. **PWA- und App-Sitzungen gleiten:** Ende nach 90 Tagen **ohne Nutzung**. Eine Anfrage verschiebt das Ende, höchstens einmal je Tag
   (ein Schreibzugriff je Sitzung und Tag); beim Cookie wird das Cookie mit denselben Merkmalen neu gesetzt. Keine absolute Obergrenze.
   Sitzungen von vor der Umstellung werden bei der nächsten Nutzung verlängert, ohne Neuanmeldung. Die Live-Abfrage (`/v1/sync/wait`)
   verlängert nicht: Ihre späte Antwort könnte das Cookie einer neueren Anmeldung überschreiben. Scheitert das Speichern, läuft die
   Anfrage normal weiter.

## Abwägung

**Was bleibt:** Benutzen zwei Parteien dieselbe Anmeldung und machen beide weiter, wird das erkannt und die ganze Verbindung widerrufen
(RFC 9700 §4.14.2): Sobald ein Nachfolger benutzt wurde, ist das alte Token ein Replay, egal wie spät. Von zwei Zweigen gewinnt der erste
benutzte; der andere ist beim nächsten Vorlegen ein Replay. Widerruf von Hand (Verbindungen, Sitzungsliste, „andere Sitzungen beenden“),
Abmelden und Kontosperre wirken sofort wie bisher; MCP prüft die Verbindung bei jeder Anfrage.

**Was wir bewusst in Kauf nehmen:**

- Eine Kopie eines **um eine Rotation alten** Refresh-Tokens ist nutzbar, solange der rechtmäßige Client seinen Nachfolger nicht benutzt
  (vorher 300 s). Das trifft nur ruhende oder verlorene Stände. Wer so ein Token hat, kann bis zu 50 Wiederholungen zeitlich verteilen
  und jeweils nur das 15-Minuten-Access-Token nutzen (zusammen rund 12,5 Stunden), ohne dass ein Widerruf ausgelöst wird, falls der
  Client nie wiederkommt. Die frühere Obergrenze von 1200 s aus ADR 0036 gilt nicht mehr. Wer stattdessen das **aktuelle** Token eines
  ruhenden Clients stiehlt, hatte schon bisher Zugriff bis zum Widerruf.
- Eine gestohlene, aktiv genutzte Sitzung endet nicht mehr nach 30 Tagen von selbst. Sie steht in der Sitzungsliste und lässt sich dort
  beenden.
- Verbrauchte Refresh-Zeilen bleiben rund 90 statt 30 Tage in `oauth_secrets`, bis `cleanup-expired` sie entfernt.

**Grenzen (Abmeldung bleibt möglich):**

- `successor_used`: Überschreibt ein Client seinen neueren Stand mit einem älteren (zwei Prozesse mit getrennten Ständen), ist das vom
  Diebstahl nicht zu unterscheiden und widerruft weiterhin. Der Grund steht im Server-Log (`oauth.replay_revoked`, `reason`).
- Mehr als 50 Wiederholungen desselben Tokens (Client, der nie speichern kann, grob ein halber Tag) widerrufen wie ein Replay.
- Länger als 90 Tage ohne Nutzung.
- Eine laufende oder nicht interaktive Claude-Code-Sitzung übernimmt eine neue Anmeldung nicht immer; dann `/mcp` neu verbinden oder
  neue Sitzung (Client-Verhalten, nicht änderbar durch den Server).
- Passwortwechsel und Passkey-Widerruf beenden bestehende Sitzungen nicht (unverändert; durch das Gleiten gewichtiger, siehe Karte).

## Verworfen

- Fenster nur verlängern (Stunden): Der Mac schläft über Nacht oder Wochenenden; jede feste Frist erzeugt dieselbe Abmeldung später.
- Keine Rotation für MCP-Clients: verliert die Erkennung zweier Parteien ganz.
- Längeres Access-Token: ändert am verlorenen Speichern nichts, verlängert nur die Zeit, in der ein gestohlenes Token wirkt.
- Absolute Obergrenze für Sitzungen: wäre wieder ein Ablauf bei laufender Nutzung.
- „Wiederholung 51 nur ablehnen statt widerrufen“: Der Client löscht bei `invalid_grant` ohnehin seine Tokens.
