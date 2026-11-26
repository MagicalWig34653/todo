# Noch auf Todolino nachzutragen

Die Todolino-Verbindung war in der Umsetzungssitzung (26.11.2026) nicht angemeldet. Die Texte unten sind noch **nicht** auf dem Board.

## post_progress auf `8B820AA8`

- Schritt 1 „Lesbarkeit“ fertig: rot `7141539`, grün `381784c` auf `main`, kein Deploy.
- GitHub `381784c`: CI 45903847940, E2E 45904018992 (95 Läufe ok), Docker publish 45903847945, Pages 45903848034, alle grün.
- Bilder vorher/nachher hell+dunkel, Handy+Computer: `design/ux-konzept/schritt-1/`.
- Klickwege neu gemessen: 1) 3→3, 2) 1→1, 4) Desktop 1→1 / Handy 2→2, 5) 3→3, 5b) 2→2. Erste Review-Karte y: Desktop 865→887, Handy 710→692. 2b/3 scheitern im Messskript wie in der Ist-Messung (nicht neu gemessen).
- Lehre: Ein neuer Knopf in der Handy-Kopfzeile lief bei 320 px und 200 % Schrift über, erst die Gesamtsuite zeigte das. Drei Specs haben Port 25173 fest, E2E gleich auf diesem Port starten.

## record_decision (Commit `381784c`)

- Handy: „Hilfe“ nur noch im Kontomenü, damit die Kopfzeile mit „+“ nicht überläuft (wie Konzept §3).
- Brain-Vollmacht beginnt mit einem neuen Kurzsatz; der bisherige volle Text steht unverändert hinter „Mehr erfahren“.
- Änderungen/Tests-Reiter sind ausgeblendet; ein Link mit `&tab=` zeigt seinen Reiter weiterhin.

## post_progress auf `0E5CCA05` (Weckruf zu Review `74A1862B`)

- Geprüft: `da95daf` ist in `0d2bb78` enthalten (`git merge-base --is-ancestor`), `Sources/` und Paketdateien dazwischen unverändert. Laut Lino ist `sha-0d2bb78` deployt, die Projektgruppen-Fixes sind damit live. Keine neue Deploy-Review.
- Hinweis aus der Review: Brain-Vollmacht einmal neu erteilen, falls noch nicht geschehen.
