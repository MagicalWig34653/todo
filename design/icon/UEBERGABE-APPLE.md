# Übergabe: Icon D „Bausteine“ ins Apple-Repository

Karte `75EAE344`, behebt Bug `950D1506`. Stand 26.11.2026: Quelle liegt hier fertig, **im Apple-Repository ist noch nichts geändert**.

## Welche Dateien wohin

| Von (Hauptrepo `design/icon/`) | Nach (Apple-Repo) |
| --- | --- |
| `Todo.icon/icon.json` | `App/Icon/AppIcon.icon/icon.json` (ersetzen) |
| `Todo.icon/Assets/block-next.svg`, `blocks-done.svg` | `App/Icon/AppIcon.icon/Assets/` |
| entfällt | `Assets/{checkmark,project-root,project-child,project-task}.png` löschen |
| entfällt | `App/Icon/source/` (alte Petrol-Quelle samt Render-Skript) löschen; Quelle ist nur noch das Hauptrepo |

Der Paketname bleibt `AppIcon.icon` (`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`, `scripts/testflight-archive.sh`).

```sh
# im Apple-Repo; $MAIN = Pfad zum Hauptrepo
rm -rf App/Icon/AppIcon.icon App/Icon/source
cp -R "$MAIN/design/icon/Todo.icon" App/Icon/AppIcon.icon
```

## Zu prüfen

1. `ictool` auf das kopierte Paket (Default und Dark): roter Block rechts oben, drei Blöcke sichtbar, dunkel gelbe Blöcke
   auf fast Schwarz. Vergleich: `design/icon/png/`.
2. In Icon Composer öffnen (Hell, Dunkel, Mono, getönt, Watch-Kreis). Beim Speichern darf die Reihenfolge der Gruppen
   nicht kippen (erste Gruppe = vorn) und kein `fill` neben `fill-specializations` entstehen.
3. `project.yml` (Stand `7f478be`, nur gelesen): iOS und macOS binden das Paket ein; **`Todo-watchOS` hat weder
   die Quelle noch den Icon-Namen**. Für die Watch beides ergänzen und `xcodegen generate`.
4. iOS, macOS und watchOS bauen (`actool`), Warnungen prüfen, Icon auf Simulator oder Gerät in den Erscheinungsarten ansehen.
5. Deployment-Ziele iOS 17 / macOS: prüfen, dass `actool` die Ersatzbilder für Systeme vor 26 erzeugt.

## Hier nicht geprüft

`actool`-Build, Xcode-Import, Öffnen und Speichern in der Icon-Composer-Oberfläche, echte Geräte, Systeme vor 26.
