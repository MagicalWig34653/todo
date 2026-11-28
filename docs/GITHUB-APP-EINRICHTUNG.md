# GitHub-App einrichten (Pull Requests mit Server-Änderungen)

Mit dieser App darf Todolino die Änderungen, die jemand direkt auf einem Deploy-Ziel gemacht hat, selbst als Branch
`server/<ziel>-JJJJ-MM-TT` mit einem Commit anlegen und dafür einen Pull Request öffnen (ADR 0042). Ohne Einrichtung bleibt der
Schreibweg abgeschaltet; Holen (`pull_server_changes`) geht weiter wie bisher.

Dauer: etwa 10 Minuten. Du brauchst Admin-Rechte am Repository, Zugriff auf einen Swarm-Manager und eine Todolino-Version mit
Phase 2b. **Der private Schlüssel gehört nie in Chat, Board, Repository oder Env-Datei.**

## 1. App anlegen

GitHub → dein Profilbild → **Settings** → **Developer settings** → **GitHub Apps** → **New GitHub App** (bei einer Organisation: in
den Einstellungen der Organisation).

| Feld | Wert |
|---|---|
| GitHub App name | frei, GitHub-weit eindeutig, z. B. `Todolino Deploy <dein Kürzel>` |
| Homepage URL | die Adresse deines Todolino |
| Callback URL, Setup URL | leer |
| Webhook → **Active** | **abwählen** |
| Repository permissions → **Contents** | **Read and write** (`contents: write`) |
| Repository permissions → **Pull requests** | **Read and write** (`pull_requests: write`) |
| Repository permissions → Metadata | Read-only (setzt GitHub selbst) |
| alle anderen Rechte | **No access**, auch **Workflows** |
| Subscribe to events | nichts |
| Where can this GitHub App be installed? | **Only on this account** |

**Create GitHub App**. Oben auf der Seite steht die **App ID** (eine Zahl): notieren.

## 2. Privaten Schlüssel erzeugen

Auf derselben Seite unten: **Private keys** → **Generate a private key**. Der Browser lädt eine Datei
`<name>.<datum>.private-key.pem`. Diese Datei ist der Zugang; bewahre sie im Passwortmanager auf und lösche sie nach Schritt 5 aus
den Downloads.

## 3. App installieren und Installations-ID ablesen

Links **Install App** → dein Konto → **Install** → **Only select repositories** → nur die Repositorys wählen, in die Todolino
schreiben soll. Danach steht die **Installations-ID** am Ende der Adresse:

- eigenes Konto: `https://github.com/settings/installations/<Installations-ID>`
- Organisation: `https://github.com/organizations/<org>/settings/installations/<Installations-ID>`

Alle Repositorys müssen zu **dieser einen** Installation gehören (eine Todolino-Instanz kennt eine Installation). Sie müssen
**privat** sein; in öffentliche Repositorys schreibt Todolino nicht.

## 4. Repository absichern (vor dem ersten Einsatz)

**Branches.** GitHub kann das Recht `contents: write` nicht auf `server/*` beschränken. Todolino erzwingt das selbst (nur neue
Refs unter `server/`, kein Verschieben, Löschen oder Mergen). Als zweite Schranke im Repository unter **Settings → Rules →
Rulesets** (bei privaten Repositorys je nach GitHub-Tarif):

1. Regel für den Standard-Branch: *Require a pull request before merging* und *Block force pushes*; die App steht **nicht** in der
   Bypass-Liste.
2. Optional, strenger: Regel für *All branches* mit Ausnahme `server/**`: *Restrict creations*, *Restrict updates*,
   *Restrict deletions*; Bypass nur für dich (Rolle *Repository admin*). Dann kann die App wirklich nur `server/**` anlegen.
   Wer sonst noch Branches pusht, muss ebenfalls in die Bypass-Liste.

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

## 5. Am Server hinterlegen (Docker Swarm)

Auf dem Manager (die `.pem` dorthin kopieren, danach löschen):

```bash
docker secret create todo_github_app_key ./todolino-deploy.private-key.pem
rm ./todolino-deploy.private-key.pem

deploy/swarm/settings.sh \
  --set GITHUB_APP_ENABLED=true \
  --set GITHUB_APP_ID=<App-ID> \
  --set GITHUB_APP_INSTALLATION_ID=<Installations-ID> \
  --set GITHUB_APP_REPOSITORIES=<Todolino-Projekt-ID>=<owner>/<repo>
```

- **`GITHUB_APP_REPOSITORIES`** legt fest, welches Todolino-Projekt in welches Repository schreiben darf. Die Projekt-ID steht in der
  Adresse der PWA (`/project/<ID>`). Mehrere Einträge durch Komma trennen. Nur das Projekt, dem das **Deploy-Ziel** gehört, zählt
  (Unterprojekte einzeln eintragen). Wer in diesem Projekt bearbeiten darf, kann Pull Requests in dem Repository öffnen.
- Anderer Secret-Name: zusätzlich `--set GITHUB_APP_KEY_SECRET=<Name>`.
- Danach wie gewohnt ausrollen (`deploy/swarm/update.sh`, siehe [BETRIEB.md](BETRIEB.md)). Die Programmdateien auf dem Manager
  müssen aktuell sein (neu: `stack.github.yaml`). Läuft `setup.sh` später noch einmal, die vier Werte erneut setzen.
- Ohne Swarm: dieselben Variablen als Umgebung, den Schlüssel als Datei über `GITHUB_APP_PRIVATE_KEY_FILE=/pfad/zur/datei.pem`.

## 6. Prüfen

- Im Server-Log darf nach dem Start **nicht** stehen: `deploy github app configuration invalid` (die Zeile nennt die falschen
  Variablen, nie Werte).
- Erster Lauf durch einen Agenten (oder `POST /v1/deploy-targets/{id}/pull-request` als angemeldete Person): MCP
  `open_server_changes_pr` mit dem Manifest des Repo-Stands und `baseCommit` = aktueller Stand des Standard-Branches
  (`git rev-parse origin/main`). Erwartet: `ok: true`, ein Branch `server/…`, ein Link zum Pull Request; `main` ist unverändert.

| Antwort `code` | Bedeutung |
|---|---|
| `deploy_github_not_configured` | keine App-Variable gesetzt |
| `deploy_github_config_invalid` | Variable fehlt oder ist falsch (Server-Log) |
| `deploy_github_repository_not_allowed` / `_required` | Projekt hat keinen Eintrag bzw. mehrere (dann `repository` mitgeben) |
| `deploy_github_repository_public` | Repository ist öffentlich |
| `deploy_github_auth_failed` | Schlüssel, App-ID oder Uhrzeit des Servers falsch |
| `deploy_github_forbidden` | Recht fehlt, Ruleset verbietet den Branch oder GitHub-Limit |
| `deploy_github_not_found` | App im Repository nicht installiert oder Installations-ID falsch |
| `deploy_github_failed` | GitHub lehnt die Anfrage ab, z. B. weil der App ein Recht aus Schritt 1 fehlt (Server-Log: Schritt und Status) |
| `deploy_github_base_unknown` | `baseCommit` liegt nicht auf dem Standard-Branch (erst pushen) |
| `deploy_pull_nothing` | nichts weicht vom `baseCommit` ab |
| `deploy_github_pr_failed` | Branch und Commit stehen, der Pull Request nicht: von Hand öffnen |

## Grenzen

- Je Lauf höchstens 500 Dateien, davon 50 Binärdateien; der Rest steht in `remaining` und kommt mit dem nächsten Lauf als eigener
  Pull Request. Jeder Aufruf öffnet einen neuen Pull Request (`-2`, `-3` …).
- `baseCommit` möglichst aktuell halten: weichen dort die Workflow-Dateien vom Standard-Branch ab, kann GitHub den Branch ablehnen,
  weil die App kein Recht *Workflows* hat.
- Commit-Autor ist die App; die Person als Autor (verknüpftes GitHub-Konto), der Knopf in der PWA und die tägliche Drift-Karte fehlen
  noch.

## Schlüssel tauschen oder abschalten

- **Tauschen:** auf der App-Seite einen neuen Schlüssel erzeugen, unter neuem Namen als Secret anlegen,
  `settings.sh --set GITHUB_APP_KEY_SECRET=<neuer Name>`, ausrollen, alten Schlüssel auf der App-Seite und das alte Secret löschen.
- **Abschalten:** `settings.sh --set GITHUB_APP_ENABLED=false` und ausrollen. Sofort ohne Rollout: in GitHub die Installation
  *suspend* oder deinstallieren.
