# ADR 0044: Upload auf Test-Ziele mit Antrag, Drift-Sperre, Sicherung und Rückweg (Phase 3)

Status: angenommen (28.11.2026, Karte 354ADE12, Konzept Orchestrator `docs/konzept-deploy-sftp.md`, Abschnitt 8 vor 1–7)

## Kontext

Bis Phase 2 liest Todolino die Zielserver nur. Phase 3 schreibt zum ersten Mal, vorerst nur auf Test-Ziele. Auf demselben Server
ändern Personen Dateien direkt; nichts davon darf unbemerkt verloren gehen. Agenten bereiten Uploads vor, entscheiden aber nicht.

## Entscheidung

1. **Plan, Antrag, Freigabe.** Ein Plan liest den Server nur. Starten kann ihn ausschließlich eine Personen-Sitzung mit der Rolle
   `manage` (`POST /v1/deploy-plans/{id}/approve`), und nur nach einem Antrag. MCP hat `plan_deploy`, `request_deploy`, `get_deploy`,
   `plan_deploy_rollback`, aber kein Werkzeug, das freigibt oder hochlädt. Nur `stage = test` (geprüft beim Planen, beim Rückweg und
   unter der Sperre bei der Freigabe). Produktion ist Phase 4.
2. **Inhalte beim Planen.** Der Aufrufer sendet das Manifest und den Inhalt der Dateien, die der Plan hochlädt; Größe und SHA-256
   müssen passen. Inhalte und Sicherungen liegen verschlüsselt in der Datenbank (AES-256-GCM mit `SETTINGS_ENCRYPTION_KEY`, Zusatzdaten
   Plan, Rolle, Position, Serverpfad; Blöcke zu 1 MB). Inhalte werden nach Lauf, Ablehnung oder Ablauf gelöscht.
3. **Was nie hochgeht:** ausgeschlossene Dateien, Namen wie Geheimnisse, `.git`/`.github`, temporäre Namen und Dateien, deren Inhalt wie
   ein Geheimnis aussieht (`secret_content`, dieselbe Prüfung wie beim Holen, ADR 0041). Sie stehen als `findings` im Plan.
4. **Drift-Sperre.** Todolino kennt den Stand, den sein letzter Lauf an diesem Endpunkt hinterlassen hat. Weicht eine Datei davon ab,
   ist der Plan gesperrt: `unknown_server_state`, `server_changed`, `server_deleted` (eine Person darf sie ausdrücklich übergehen),
   `symlink` und `unverified` (nicht übergehbar). Steht auf dem Server schon der Inhalt des Repo-Stands, gilt die Datei als unverändert
   und wird bekannter Stand; das ist der gewollte Weg nach dem Holen. Ein Upload löscht nie.
5. **Lauf.** Voraussetzungen unter der Zielsperre: Antrag, Ziel unverändert, kein anderer Lauf, kein Lauf seit dem Plan, Plan nicht
   abgelaufen. Dann: Server erneut lesen (jede Abweichung vom Plan bricht mit `deploy_plan_stale` ab, auch mit Überschreiben), Links
   prüfen, **alles sichern, was sich ändert**, erst dann schreiben, danach nachlesen und festhalten, was wirklich dort steht. Der Lauf
   hält seine Frist (30 Minuten) selbst wach; nur ein Lauf ohne Prozess verfällt (`deploy_interrupted`). Vor dem ersten Schreiben prüft
   er unter der Sperre, dass er das Ziel noch hält. Nach einem abgebrochenen Upload entfernt er seine Reste mit temporärem Namen.
6. **Rückweg.** Nur für den letzten schreibenden Lauf, als eigener Plan mit eigener Freigabe. Überschriebene Dateien kommen aus der
   Sicherung; gelöscht wird nur, was der Lauf nachweislich angelegt hat. Sieht eine nicht nachgewiesene Datei genauso aus wie geplant,
   ist der Rückweg gesperrt, bis eine Person entscheidet; eine andere bleibt unberührt. Sicherungen der letzten 5 Läufe bleiben.
7. **Transport.** `rclone copy --files-from-raw` mit `--partial-suffix .todolino.tmp` (fertig hochladen, dann umbenennen). Dateinamen
   stehen nie auf der Kommandozeile oder direkt in Umgebungsvariablen, weil Foundation sie auf macOS in zerlegtes Unicode umschreibt:
   Listen über Dateien, das Zielverzeichnis liest eine kleine Shell aus einer Datei. Links auf dem Weg: SFTP durch Vergleich der
   Listings mit und ohne Verfolgen, FTP/FTPS durch `LIST -a` (versteckte Namen) im Unix-Format; ein anderes Format sperrt das Schreiben.
8. **Pfade** werden nach Bytes in Segmente geteilt. Ein `/`, das Unicode mit seinem Nachbarn zu einem Zeichen verbindet, wird abgelehnt:
   sonst ließe sich ein `..` verstecken (Befund H1 des Gegenlesens, betraf nur den neuen, nie veröffentlichten Schreibweg).

## Grenzen

| Wert | Grenze |
| --- | --- |
| Dateien je Plan | 500 |
| je Datei / Inhalt je Plan / Sicherung je Lauf | 8 MB / 16 MB / 64 MB |
| wartende Pläne je Ziel | 10 |
| behaltene Pläne ohne Lauf je Ziel | 20 |
| gleichzeitige Planungen je Prozess | 2 (`deploy_planning_busy`) |
| Gültigkeit eines Plans | 24 Stunden |
| Läufe mit Sicherung je Ziel | 5 |

## Restrisiko

- Zwischen dem letzten Lesen und dem Schreiben bleibt ein kurzes Fenster. Wer genau dann auf dem Server ändert, wird überschrieben,
  ohne dass diese Fassung in der Sicherung liegt.
- Zwei Planungen gegen sehr langsame Server belegen beide Plätze eines Prozesses; andere bekommen so lange `deploy_planning_busy`.
- Die Sperre gilt je Ziel. Zwei Ziele auf denselben Serverpfad sperren sich nicht gegenseitig (das spätere sieht aber Drift).
- Ein FTP-Server, der `LIST -a` nicht versteht und Punktnamen verbirgt, kann versteckte Links verbergen. Dort schützt nur seine chroot.
- Die Inhaltsprüfung ist eine Heuristik: ein Passwort in einer Datei ohne Konfigurationsnamen wird nicht erkannt.
- Stirbt der Todolino-Prozess während eines Uploads, können Dateien `*.todolino.tmp` auf dem Server bleiben.
- Pläne sehr großer Repositories (50 000 Dateien) speichern rund 10 MB JSON; MariaDB braucht dafür die übliche `max_allowed_packet`
  von mindestens 16 MB. Zeilen ausgeführter Läufe werden nicht gelöscht (jede braucht eine Freigabe).
