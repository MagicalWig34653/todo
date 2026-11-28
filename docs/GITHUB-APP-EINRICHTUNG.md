# GitHub für Pull Requests einrichten

Todolino kann die Änderungen, die jemand direkt auf einem Deploy-Ziel gemacht hat, selbst als Branch `server/<ziel>-JJJJ-MM-TT`
mit einem Commit anlegen und dafür einen Pull Request öffnen (ADR 0042 und Nachtrag). Ohne Einrichtung bleibt der Schreibweg
abgeschaltet; Holen (`pull_server_changes`) geht weiter wie bisher.

**Zwei Rollen, zwei Anleitungen.** Der **Betreiber** (wer den Server betreibt) legt **einmal** eine GitHub-App an. Danach muss
**kein Nutzer** selbst eine App anlegen: jede Person installiert die App der Instanz auf dem eigenen Konto oder der eigenen
Organisation, wählt dort die Repositorys und ordnet sie in der PWA ihren Projekten zu.

- [Für Betreiber](#für-betreiber-einmalig-etwa-15-minuten)
- [Für Nutzer](#für-nutzer-ein-klick-auf-installieren)

**Der private Schlüssel und das Client-Secret gehören nie in Chat, Board, Repository oder Env-Datei.**

---

## Für Betreiber (einmalig, etwa 15 Minuten)

Du brauchst ein GitHub-Konto (oder eine Organisation) als Besitzer der App, Zugriff auf einen Swarm-Manager und eine
Todolino-Version mit diesem Nachtrag.

### 1. App anlegen

GitHub → Profilbild → **Settings** → **Developer settings** → **GitHub Apps** → **New GitHub App**.

| Feld | Wert |
|---|---|
| GitHub App name | frei, GitHub-weit eindeutig, z. B. `todolino-deploy-<dein Kürzel>`; er steht später in der Adresse (`github.com/apps/<Name>`) und ist die **Slug** |
| Homepage URL | die Adresse deines Todolino (`https://…`) |
| Callback URL | `<Adresse deines Todolino>/github/callback` |
| Expire user authorization tokens | an (Vorgabe; Todolino nutzt das Nutzer-Token nur sofort und speichert es nicht) |
| Request user authorization (OAuth) during installation | **an** |
| Setup URL | leer lassen: bei eingeschalteter Nutzer-Autorisierung benutzt GitHub nur die Callback URL (Todolino versteht den Rückweg auch über `/github/setup`) |
| Webhook → **Active** | **abwählen** |
| Repository permissions → **Contents** | **Read and write** |
| Repository permissions → **Pull requests** | **Read and write** |
| Repository permissions → Metadata | Read-only (setzt GitHub selbst) |
| alle anderen Rechte | **No access**, auch **Workflows** |
| Subscribe to events | nichts |
| Where can this GitHub App be installed? | **Any account** |

**Create GitHub App.** Oben auf der Seite: **App ID** und **Client ID** notieren.

*Per App-Manifest (schneller, gegen das echte GitHub nicht geprüft):* ein Manifest mit denselben Werten, mit dem GitHub die App
in einem Schritt anlegt, steht unten im Abschnitt „App-Manifest“.

### 2. Schlüssel und Client-Secret erzeugen

Auf der Seite der App unten **Private keys** → **Generate a private key** (die `.pem`-Datei), oben **Client secrets** →
**Generate a new client secret** (der Wert wird nur einmal angezeigt). Beides wandert in Swarm-Secrets (Schritt 3); lösche die
Datei danach aus den Downloads.

### 3. Am Server hinterlegen (Docker Swarm)

Auf dem Manager (die `.pem` dorthin kopieren, danach löschen):

```bash
docker secret create todo_github_app_key ./todolino-deploy.private-key.pem
rm ./todolino-deploy.private-key.pem
printf '%s' '<Client-Secret>' | docker secret create todo_github_app_client_secret -

deploy/swarm/settings.sh \
  --set GITHUB_APP_ENABLED=true \
  --set GITHUB_APP_ID=<App-ID> \
  --set GITHUB_APP_SLUG=<Name aus der Adresse der App> \
  --set GITHUB_APP_CLIENT_ID=<Client-ID>
```

- Pro Nutzer ist **nichts** einzutragen. Danach wie gewohnt ausrollen (`deploy/swarm/update.sh`, siehe [BETRIEB.md](BETRIEB.md)).
  Die Programmdateien auf dem Manager müssen aktuell sein (`stack.github.yaml` hat sich geändert). Läuft `setup.sh` später noch
  einmal, die Werte erneut setzen.
- Andere Secret-Namen: zusätzlich `--set GITHUB_APP_KEY_SECRET=<Name>` und `--set GITHUB_APP_CLIENT_SECRET_SECRET=<Name>`.
- Ohne Swarm: dieselben Variablen als Umgebung, Schlüssel und Client-Secret als Dateien über `GITHUB_APP_PRIVATE_KEY_FILE` und
  `GITHUB_APP_CLIENT_SECRET_FILE`. GitHub Enterprise: `GITHUB_API_URL` (`https://<host>/api/v3`) und `GITHUB_WEB_URL`
  (`https://<host>`).
- **Übergang:** Wer die bisherigen Variablen `GITHUB_APP_INSTALLATION_ID` und `GITHUB_APP_REPOSITORIES` (`<Projekt-ID>=owner/repo`)
  gesetzt hat, behält sie: diese Zuordnungen gelten weiter, in der PWA stehen sie als „vom Betreiber vorgegeben“. Beide gehören
  zusammen. Eine App „Only on this account“ ohne die neuen Variablen läuft ebenfalls weiter (ohne „Mit GitHub verbinden“); für
  alle Nutzer muss die App auf **Any account** stehen.

### 4. Prüfen

- Im Server-Log darf nach dem Start **nicht** stehen: `deploy github app configuration invalid` (die Zeile nennt die falschen
  Variablen, nie Werte).
- In der PWA: **Einstellungen → GitHub** zeigt „Mit GitHub verbinden“. Steht dort „noch nicht eingerichtet“, fehlt eine der
  Variablen.
- Verbinden und Zuordnen wie unten, dann ein Pull Request: MCP `open_server_changes_pr` mit dem Manifest des Repo-Stands und
  `baseCommit` = aktueller Stand des Standard-Branches (`git rev-parse origin/main`). Erwartet: `ok: true`, ein Branch `server/…`,
  ein Link zum Pull Request; `main` ist unverändert.

### 5. Was der Betreiber nicht sieht und nicht kann

- Die Installationen der Nutzer stehen nur mit ID, Konto und GitHub-Login in der Datenbank; kein Nutzer-Token, kein Code, kein
  `state` wird gespeichert. Der Betreiber kann über die App aber **technisch** auf alle Repositorys zugreifen, die Nutzer
  installieren (so funktioniert jede GitHub-App): der Schlüssel ist der Zugang zu allem. Deshalb: Schlüssel nur im Swarm-Secret,
  kein Zugriff Dritter auf den Manager, und die App fragt nur `contents` und `pull_requests` ab.
- Todolino begrenzt das selbst: nur **private** Repositorys, nur neue Branches `server/*`, nie `main`, keine Pipeline-Dateien
  (`.github`, `Jenkinsfile`, …), nichts wird gemergt, verschoben oder gelöscht.

### 6. Schlüssel tauschen oder abschalten

- **Tauschen:** auf der App-Seite neuen Schlüssel (oder neues Client-Secret) erzeugen, unter neuem Namen als Secret anlegen,
  `settings.sh --set GITHUB_APP_KEY_SECRET=<neuer Name>` (bzw. `GITHUB_APP_CLIENT_SECRET_SECRET`), ausrollen, den alten auf der
  App-Seite und das alte Secret löschen.
- **Abschalten:** `settings.sh --set GITHUB_APP_ENABLED=false` und ausrollen. Sofort ohne Rollout: die App bei GitHub
  **suspendieren** (Seite der App → Advanced) oder löschen; dann scheitert jede Nutzung mit `deploy_github_auth_failed`.

### App-Manifest (optional)

GitHub legt eine App aus einem Manifest an (Seite `https://github.com/settings/apps/new`, Formularfeld `manifest`; bei einer
Organisation `https://github.com/organizations/<org>/settings/apps/new`). Ersetze `<URL>` durch die Adresse deines Todolino:

```json
{
  "name": "todolino-deploy-<Kürzel>",
  "url": "<URL>",
  "redirect_url": "<URL>/",
  "callback_urls": ["<URL>/github/callback"],
  "request_oauth_on_install": true,
  "public": true,
  "hook_attributes": { "url": "<URL>/github/webhook", "active": false },
  "default_permissions": { "contents": "write", "pull_requests": "write" },
  "default_events": []
}
```

GitHub leitet danach auf die Startseite von Todolino mit `?code=…` weiter (Todolino wertet das nicht aus); den Code kopiert der
Betreiber aus der Adresszeile und tauscht ihn **einmal innerhalb einer Stunde** selbst gegen App-ID, Client-ID, Client-Secret und
Schlüssel (der Webhook ist ausgeschaltet, seine Adresse nur ein Platzhalter):

```bash
curl -s -X POST -H 'Accept: application/vnd.github+json' https://api.github.com/app-manifests/<code>/conversions > app.json
```

Aus `app.json` nur `id`, `slug`, `client_id` ablesen; `client_secret` und `pem` direkt in die Swarm-Secrets von Schritt 3 legen
(`jq -r .pem app.json | docker secret create todo_github_app_key -`, `jq -j .client_secret app.json | docker secret create
todo_github_app_client_secret -`) und `app.json` sofort löschen. Dieser Weg ist **nicht gegen das echte GitHub geprüft**.

---

## Für Nutzer (ein Klick auf Installieren)

Du brauchst nichts anzulegen: die GitHub-App gehört der Instanz. Du entscheidest selbst, welche deiner Repositorys sie erreicht.

### 1. Verbinden

**Einstellungen → GitHub → Mit GitHub verbinden.** Du kommst zu GitHub:

1. Konto oder Organisation wählen, **Install**.
2. **Only select repositories** und nur die Repositorys wählen, in die Todolino schreiben soll. Sie müssen **privat** sein.
3. Bei der Frage nach der Anmeldung (User authorization) **Authorize**: damit weist GitHub Todolino nach, dass die Installation dir
   gehört. Todolino merkt sich dein Nutzer-Token nicht.

Danach bist du zurück in Todolino, die Verbindung steht in der Liste. Eine Organisation, in der du nicht Inhaber bist, kann die
Installation nur anfragen; ist sie genehmigt, nutze **Schon installiert? Übernehmen**.

### 2. Projekt einem Repository zuordnen

Beim Projekt: **… → Deploy-Ziele**, unten **GitHub-Repository für Pull Requests**: Verbindung und Repository wählen, **Zuordnen**.
Angeboten werden nur Repositorys, in die **dein** GitHub-Konto schreiben darf. Du brauchst am Projekt die Rolle *Verwalten*.

- Wer das Projekt bearbeiten darf, kann danach (und seine Agenten über `open_server_changes_pr`) Pull Requests in diesem Repository
  öffnen. Agenten sehen nie Verbindungen oder Installationen, nur die Codes im Fehlerfall.
- **Bei jedem Zugriff** prüft Todolino neu: ob die Installation noch besteht und nicht ausgesetzt ist, ob das Repository noch
  ausgewählt ist, ob es noch dasselbe ist, ob **du** bei GitHub noch dort schreiben darfst und ob du das Projekt noch verwalten
  darfst. Fällt etwas weg, schreibt nichts mehr; die Antwort nennt den Grund (Tabelle unten). Ein Webhook ist dafür nicht nötig.

### 3. Ändern, entfernen, deinstallieren

- **Repository-Auswahl ändern:** bei GitHub (**Bei GitHub verwalten** in der Verbindung).
- **Verbindung entfernen** (Einstellungen → GitHub → Entfernen): Todolino vergisst sie samt allen Zuordnungen. Die Installation
  bei GitHub bleibt; dort lässt sie sich deinstallieren.
- **Konto löschen** entfernt Verbindungen und alle Zuordnungen, die über sie liefen.

### Wenn etwas nicht klappt

| Antwort `code` (bzw. Hinweis in der PWA) | Bedeutung |
|---|---|
| `deploy_github_not_configured` | der Betreiber hat die App nicht eingerichtet |
| `deploy_github_repository_not_allowed` | dem Projekt ist kein (oder ein anderes) Repository zugeordnet; mehrere: `repository` angeben (`_required`) |
| `deploy_github_assignment_revoked` | wer das Repository zugeordnet hat, darf das Projekt nicht mehr verwalten (oder ist gesperrt): neu zuordnen |
| `deploy_github_repository_access_lost` | das GitHub-Konto der zuordnenden Person darf dort nicht mehr schreiben (Rolle geändert, anderes Konto unter demselben Namen) |
| `deploy_github_repository_removed` | das Repository ist in der Installation nicht mehr ausgewählt |
| `deploy_github_repository_changed` | unter dem Namen liegt jetzt ein anderes Repository (gelöscht und neu angelegt): neu zuordnen |
| `deploy_github_installation_removed` | die App wurde bei GitHub deinstalliert: Verbindung entfernen und neu verbinden |
| `deploy_github_installation_suspended` | die Installation ist bei GitHub ausgesetzt |
| `deploy_github_repository_public` | das Repository ist öffentlich; nur private sind möglich |
| `deploy_github_auth_failed` | Schlüssel, App-ID oder Uhrzeit des Servers falsch: der Betreiber muss prüfen |
| `deploy_github_forbidden` | GitHub verweigert (Recht fehlt, Ruleset oder Limit) |
| `deploy_github_base_unknown` | `baseCommit` liegt nicht auf dem Standard-Branch (erst pushen) |
| `deploy_pull_nothing` | nichts weicht vom `baseCommit` ab |
| `deploy_github_pr_failed` | Branch und Commit stehen, der Pull Request nicht: von Hand öffnen |

---

## Repository absichern (vor dem ersten Einsatz, jeder Repository-Besitzer)

**Branches.** GitHub kann das Recht `contents: write` nicht auf `server/*` beschränken. Todolino erzwingt das selbst (nur neue
Refs unter `server/`, kein Verschieben, Löschen oder Mergen). Als zweite Schranke im Repository unter **Settings → Rules →
Rulesets** (bei privaten Repositorys je nach GitHub-Tarif):

1. Regel für den Standard-Branch: *Require a pull request before merging* und *Block force pushes*; die App steht **nicht** in der
   Bypass-Liste.
2. Optional, strenger: Regel für *All branches* mit Ausnahme `server/**`: *Restrict creations*, *Restrict updates*,
   *Restrict deletions*; Bypass nur für dich (Rolle *Repository admin*). Dann kann die App wirklich nur `server/**` anlegen.

**CI.** Die Dateien in einem Branch `server/*` kommen von einem Server, den andere bearbeiten, und noch niemand hat sie gesehen. Ein
Push der App und der Pull Request starten GitHub Actions, bei Branches im selben Repository **mit Secrets**. Todolino schreibt zwar
nie `.github`, `.gitlab*`, `Jenkinsfile`, `.circleci` und ähnliche Pipeline-Dateien, aber `package.json`, `Makefile`, `composer.json`
oder Testcode können beim Bauen ausgeführt werden. Deshalb in jedem Workflow mit Secrets, Deploy oder eigenem Runner:

```yaml
on:
  push:
    branches-ignore: ['server/**']
jobs:
  build:
    # pull_request: keine Läufe für Server-Änderungen, bevor jemand sie gesehen hat
    if: ${{ !startsWith(github.head_ref, 'server/') }}
```

## Grenzen

- Je Lauf höchstens 500 Dateien, davon 50 Binärdateien; der Rest steht in `remaining` und kommt mit dem nächsten Lauf als eigener
  Pull Request. Jeder Aufruf öffnet einen neuen Pull Request (`-2`, `-3` …).
- `baseCommit` möglichst aktuell halten: weichen dort die Workflow-Dateien vom Standard-Branch ab, kann GitHub den Branch ablehnen,
  weil die App kein Recht *Workflows* hat.
- Commit-Autor ist die App; die Person als Autor, der Knopf „Pull Request öffnen“ in der PWA und die tägliche Drift-Karte fehlen noch.
- Die Rechte am Repository wirken über das **GitHub-Konto der Person, die zugeordnet hat**: Wer eine Organisations-Installation
  verbunden hat, trägt die Verantwortung dafür; verlässt die Person die Organisation, stoppt die Nutzung (`…_access_lost`).
- Nur gegen nachgestellte GitHub-APIs geprüft, nie gegen github.com: Antwortformen von `/user/installations`, das Verhalten der
  „User authorization during installation“ und der Rückkehr-Adressen sind erst mit der echten App belegt.
