# Push an Claude Code: Ereignisse in eine laufende Sitzung zustellen

Stand: 31.10.2026. Recherche, keine Produktänderung. Anlass (Todolino-Eintrag): „Wenn möglich Push von Backend an Claude Code, damit Nachrichten nicht auf Poll warten müssen.“

Kennzeichnung: **[Belegt]** = in der offiziellen Doku oder Spezifikation gelesen (URL unten) oder im Repository gesehen. **[Lokal]** = im installierten `claude` 2.1.316 nur lesend nachgesehen (Zeichenketten im Binary, kein Funktionstest). **[Annahme]** = Schlussfolgerung, nicht geprüft.

## Kurzantwort

1. Ein **reiner Remote-HTTP-MCP-Server** (wie unser `/mcp`) kann einer laufenden Sitzung **nach heutigem Beleg keine Ereignisse zustellen, die den Agenten wecken**. Die Doku nennt für Server-zu-Client nur `list_changed` (aktualisiert Tool-/Prompt-/Resource-Listen). Resource-Subscriptions (`resources/subscribe`, `notifications/resources/updated`) und `notifications/message` sind in der Claude-Code-Doku **nicht** als Weck-Mechanismus beschrieben. **[Belegt: Abwesenheit in Doku]**, Verhalten ungetestet.
2. Der offizielle Push-Weg heißt **Channels** (Research Preview): ein MCP-Server mit Capability `experimental['claude/channel']` sendet `notifications/claude/channel` (`content`, `meta`), Claude Code stellt es als `<channel source="...">`-Ereignis in die Sitzung und der Agent wird wach. Voraussetzungen: Server als **stdio-Subprozess** (lokal), Sitzung gestartet mit `--channels` bzw. `--dangerously-load-development-channels`, claude.ai-/Console-Anmeldung, bei Team/Enterprise Admin-Freigabe, eigene Plugins stehen **nicht** auf der Allowlist. **[Belegt]**
3. Ohne Channels gibt es belegte Weck-Muster **ohne Polling-Token im Modell**: Hintergrundprozess über das **Monitor-Tool** (jede Ausgabezeile weckt den Agenten, Stille kostet nichts), **Plugin-Monitors** (starten automatisch mit dem Plugin), **asyncRewake-Hook** (Exit 2 weckt auch eine leerlaufende Sitzung), **Stop-Hook mit `decision: block`** (Sitzung endet nicht, höchstens 8 aufeinanderfolgende Fortsetzungen), `/loop` bzw. `ScheduleWakeup` (Polling, 1 min bis 1 h).
4. **Empfehlung:** (a) Long-Poll-Tool `wait_for_events` im MCP **plus** (b) Plugin-Monitor bzw. Monitor-Skript als Wecker; Channels als spätere Stufe (stdio-Brücke), sobald Allowlist/Stabilität es zulassen. Details und Reihenfolge unten.

## 1. Was belegt ist

### 1.1 MCP-Spezifikation (2025-11-25)

- Streamable HTTP: Der Client **darf** per `GET` auf den MCP-Endpunkt einen SSE-Strom öffnen; der Server **muss** `text/event-stream` liefern **oder 405**. Auf diesem Strom **darf** der Server Requests und Notifications senden; Resumability über `Last-Event-ID`, Sitzung über `MCP-Session-Id`. **[Belegt]** (modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- Resources: Capability `resources.subscribe` / `listChanged`; `resources/subscribe` {uri}, danach `notifications/resources/updated` {uri} **ohne Inhalt**, der Client muss `resources/read` nachziehen. **[Belegt]** (…/server/resources)
- Die Spezifikation schreibt nicht vor, **wie ein Client ein Ereignis dem Modell zeigt**. Ob ein Host eine Notification an das LLM weitergibt, ist Host-Entscheidung. **[Belegt: Abschnitt „User Interaction Model“ nennt Resources „application-driven“]**

### 1.2 Claude Code: MCP-Client

- `list_changed`: im interaktiven Terminal holt Claude Code die neue Liste; mit `-p`/Agent SDK nur die Tool-Liste. **[Belegt]** (code.claude.com/docs/en/mcp)
- HTTP ist die empfohlene Remote-Transportart, SSE ist **deprecated**; Wiederverbindung bis zu fünfmal mit Backoff (1 s, verdoppelnd); OAuth 2.0 mit automatischer Erneuerung. **[Belegt]**
- Resource-Subscriptions / `notifications/message`: **keine Erwähnung** in der MCP-Seite. **[Belegt: Abwesenheit]** **[Lokal]**: Im Binary stehen die Zeichenketten `resources/subscribe`, `resources/updated`, `notifications/message`; sie stammen erkennbar aus dem mitgelieferten MCP-SDK (Server-Methoden `sendResourceUpdated`, `sendLoggingMessage`), das ist **kein** Beleg, dass der Client sie verarbeitet und dem Modell zeigt. **[Annahme]**: nicht als Weg einplanen.
- Elicitation (Server fragt den Nutzer) existiert, nur interaktiv; sie ist eine Anfrage **während** eines Tool-Aufrufs, kein Push in den Leerlauf. **[Belegt]**

### 1.3 Channels

Quelle: code.claude.com/docs/en/channels und /channels-reference.

- Capability `experimental['claude/channel']: {}`, Ereignis `notifications/claude/channel` mit `content: string` und `meta: Record<string,string>` (Schlüssel nur Buchstaben, Ziffern, `_`). Erscheint als `<channel source="..." k="v">…</channel>`. **[Belegt]**
- „Connect over stdio transport“; Claude Code startet den Server als Subprozess; „A channel is an MCP server that runs on the same machine as Claude Code.“ Remote-HTTP-Server als Channel sind **nicht beschrieben**. **[Belegt]** **[Lokal]**: Der Empfangs-Handler ist im Binary generisch an der MCP-Client-Verbindung registriert (inkl. erneute Registrierung nach Reconnect); ob er für HTTP-Verbindungen aktiv ist, ist **ungeprüft** (**[Annahme]**: nicht belastbar).
- Aktivierung: nur wenn der Server in `--channels` (nur Allowlist) oder `--dangerously-load-development-channels plugin:<n>@<m> | server:<n>` (interaktiv, mit Warnhinweis; im `-p`-Modus wirkungslos) genannt ist. `.mcp.json` allein genügt nicht. **[Belegt]** Die Flags stehen laut Doku **nicht** in `claude --help` (Preview). **[Lokal]** bestätigt: `claude --help` listet weder `--channels` noch den Dev-Schalter.
- Allowlist: nur `claude-plugins-official`; eigene Plugins brauchen den Dev-Schalter oder `allowedChannelPlugins` in Managed Settings (Team/Enterprise). Pro/Max ohne Organisation: keine Org-Prüfung. **[Belegt]**
- Ereignisse werden gequeued, bei beschäftigtem Agenten gesammelt zugestellt; keine Bestätigung an den Server; ohne Registrierung werden Ereignisse **stumm verworfen**. **[Belegt]**
- Sicherheit: ungesicherte Channels sind ein Prompt-Injection-Pfad; Sender-Allowlist ist Pflicht. Permission-Relay (`claude/channel/permission`) erlaubt Freigaben von außen, nur mit authentifiziertem Absender. **[Belegt]**
- Das Plugin-Manifest kennt `channels` (Bindung an einen MCP-Server des Plugins, `userConfig` mit `sensitive: true`, Substitution `${user_config.KEY}` in `env` des stdio-Servers). **[Belegt]** (plugins-reference)
- Status: „research preview“; Flag-Syntax und Protokollvertrag können sich ändern. Auf dem v2-MCP-Runtime wird ein Channel-Server, der die Protokollrevision 2026-07-28 aushandelt, nicht als Channel registriert (`MCP_PROTOCOL_NEGOTIATION=legacy` als Ausweg für stdio). **[Belegt]**

### 1.4 Hooks (code.claude.com/docs/en/hooks)

- **Stop** (feuert, wenn Claude eine Antwort beendet): `{"decision":"block","reason":"…"}` oder Exit 2 hält die Sitzung am Laufen; `reason` wird als Nächstes an Claude gegeben. Neu: `hookSpecificOutput.additionalContext` als „Feedback ohne Fehler“. Eingabe enthält `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`. Schutz: `stop_hook_active` und **Obergrenze 8 aufeinanderfolgende Fortsetzungen**. **[Belegt]**
- Zeitlimits: `command`/`http`/`mcp_tool` Standard 600 s (nicht 30 s; 30 s nur bei UserPromptSubmit). Ein Stop-Hook darf also lange warten; ein hängender Hook blockiert aber das Sitzungsende und die Eingabe. **[Belegt]**
- **asyncRewake**: Hook läuft im Hintergrund; bei Exit 2 wird Claude **sofort** geweckt, auch bei leerlaufender Sitzung, Ausgabe (stderr) kommt als System-Reminder. `timeout` gilt dort weiter. Ohne Rewake wird Hook-Ausgabe erst beim nächsten Nutzerzug geliefert. **[Belegt]** **[Lokal]**: `asyncRewake` steht im Binary (18 Treffer).
- Hook-Typen: `command`, `http`, `mcp_tool` (ruft ein Tool eines konfigurierten MCP-Servers, mit dessen bestehender Authentifizierung), `prompt`, `agent`. **[Belegt]** Ob `mcp_tool` an Stop/asyncRewake erlaubt ist, wurde in der gelesenen Doku-Passage nicht bestätigt. **[Annahme]**: prüfen.
- `Notification`-Hook (`idle_prompt`, `permission_prompt` …) hat **keine Entscheidungsgewalt**, taugt nur für Nebenwirkungen. **[Belegt]**
- `UserPromptSubmit` reagiert nur, wenn der Nutzer etwas sendet; kein Weckmechanismus. **[Belegt]**

### 1.5 Monitor-Tool, /loop, ScheduleWakeup

- **Monitor** (code.claude.com/docs/en/tools-reference): startet einen Befehl im Hintergrund, **jede Ausgabezeile** wird als Ereignis an Claude geliefert; alternativ WebSocket-Quelle (`ws://`/`wss://`, jede Textnachricht = Ereignis; private/Link-Local-Adressen werden abgelehnt). Frist je Beobachtung: Standard 5 min, höchstens 30 min (10 min bei `-p`); danach ein Hinweis, Claude kann neu starten. Gleiche Berechtigungsregeln wie Bash. Läuft nicht nach `--resume` weiter. **[Belegt]**
- **Plugin-Monitors**: `monitors/monitors.json` (`name`, `command`, `description`, `when: always | on-skill-invoke:<skill>`), starten automatisch mit dem Plugin, „don't start with `-p`“, **experimental**; der Befehl darf `${user_config.*}` nicht enthalten und bekommt **keine** `CLAUDE_PLUGIN_OPTION_*`-Variablen. **[Belegt]** (plugins-reference)
- Dritte Quellen beschreiben Monitor als „Stille kostet keine Tokens“ und Bündelung enger Zeilen; nur Blogs, nicht offiziell. **[Annahme]**
- `/loop` (Cron, mind. 1 min; selbst-getaktet 1 min bis 1 h über `ScheduleWakeup`), Wiederholungen laufen nach 7 Tagen ab, feuern nur zwischen Zügen bei leerlaufender Sitzung. Das ist Polling. **[Belegt]** (…/scheduled-tasks) Die Doku empfiehlt für „auf Ereignisse reagieren statt pollen“ ausdrücklich Channels und für dynamische Schleifen, wenn verfügbar, Monitor.
- **Remote Control**: der Nutzer steuert eine lokale Sitzung von claude.ai/Mobil aus; das ist Steuerung durch den Nutzer, kein Ereignis-Eingang für Dritte. **[Belegt]** (channels, Vergleichstabelle)

### 1.6 Unser Backend (Repository, gesehen)

- `GET /mcp` liefert **405** (kein SSE-Strom); `initialize` meldet `tools.listChanged=false`, `resources.subscribe=false`, `resources.listChanged=false`. Das ist spezifikationskonform und passt zu Clients, die den Strom nicht nutzen. **[Belegt]** (`Sources/TodoKit/MCP/MCPController.swift`)
- ADR 0022 (gebaut): `GET /v1/sync/head` (cursor + Token, ETag/304) und `GET /v1/sync/wait?since&timeout` (Long-Poll, 1..120 s, Standard 25 s, Limits 8/Konto, 500/Replika, Sitzungsprüfung, Shutdown `retryAfter`), Token über `live_events` (Kommentare, Fragen, Reviews, Fortschritt, Agentenaufträge …). Bewusst **kein SSE**. Der Token enthält keine Daten. Auth dort: Cookie-Sitzung (PWA) bzw. Bearer (Apple). **[Belegt]**
- Plugin: `claude-plugin/hooks/hooks.json` hat SessionStart, PostToolUse(git commit) und Stop; Hooks sind netzwerkfrei und tokenfrei (Designregel in `docs/CLAUDE-CODE-EINRICHTUNG.md`). Der Stop-Hook blockt einmal je Sitzung (Marke + `stop_hook_active`). **[Belegt]**
- **Offen/ungeprüft:** ob das MCP-OAuth-Zugriffstoken auch `/v1/sync/*` akzeptiert (Scope/Audience, „Token-Bindung an die Resource“ laut IDENTITAET-UND-RECHTE). **[Annahme]**: eher nein; deshalb ist ein MCP-Tool die saubere Lösung (siehe Option a).

## 2. Muster „externes Ereignis weckt Agenten“

| Muster | Mechanik | Belegt |
| --- | --- | --- |
| Channel (stdio-Brücke) | Brücke lauscht/long-pollt, sendet `notifications/claude/channel` | ja (Preview) |
| Monitor + Wartebefehl | Hintergrundskript wartet, gibt bei Ereignis eine Zeile aus | ja |
| Plugin-Monitor | wie oben, startet automatisch | ja (experimental) |
| asyncRewake-Hook | Hintergrund-Hook, Exit 2 weckt | ja |
| Stop-Hook block | Hook wartet kurz, blockt mit Grund statt zu enden | ja, Obergrenze 8 |
| Hintergrund-Bash (`run_in_background`) | Exit des Prozesses meldet sich beim Agenten | Verhalten bekannt aus Werkzeugbeschreibung, in dieser Recherche nicht in der Doku nachgelesen **[Annahme]** |
| `/loop` / ScheduleWakeup | zyklisches Wiederaufnehmen | ja, Polling |
| Resource-Subscription | `notifications/resources/updated` | Spezifikation ja, Claude-Code-Verarbeitung **nicht belegt** |

Gemeinsamer Haken: Ereignisse erreichen nur **laufende, offene** Sitzungen. Ist die Sitzung beendet, bleibt nur der Runner-Pfad (Option d).

## 3. Bewertung der Optionen für Todolino

Vorab: Alle Wecker dürfen nur einen **Hinweis** („es gibt Neues“) liefern. Daten holt der Agent danach mit den bestehenden MCP-Tools (`list_open_questions`, `get_question`, `list_pending_reviews`, `get_command_center`, `list_tasks`). So bleiben Rechteprüfung, Token und Inhalte im bestehenden Pfad, und ein Wecker kann nichts preisgeben.

### (a) MCP-Tool `wait_for_events {since, timeoutSeconds ≤ 25}`

- **Idee:** Tool nutzt intern `LiveToken`/`LiveHub` (ADR 0022) mit dem **Konto aus der MCP-Sitzung**; Antwort `{changed, token, hints:[{kind, taskID?, projectID?}]}`. Kein Datenpayload.
- **Aufwand:** klein bis mittel. Bestehende Hub-Logik wiederverwenden; im `MCPController` eine Tool-Definition und ein Aufruf des Hubs; Hinweise (`kind`) liefert `live_events` bereits (Art des Ereignisses, nicht der Inhalt). Rechte: Hinweise auf sichtbare Projekte filtern, sonst nur „es gibt Änderungen“. Tests wie `LiveRefreshTests`.
- **Robustheit:** hoch, weil gewöhnlicher Tool-Aufruf über die bestehende OAuth-Verbindung; Obergrenze 25 s liegt unter üblichen Tool-/Proxy-Zeitlimits **[Annahme]**: Claude-Codes Tool-Timeout für MCP nicht nachgelesen (Umgebungsvariable `MCP_TOOL_TIMEOUT` ist mir als Einstellung bekannt, hier nicht geprüft).
- **Grenzen:** Der Agent muss das Tool selbst aufrufen; es **weckt nicht** von allein. Jeder Aufruf kostet Tokens (Aufruf + Antwort, grob einige hundert), und der Agent ist währenddessen blockiert (kein paralleles Arbeiten, außer in einem Unteragenten).
- **Kosten:** im Leerlauf nahe null, solange es nur vor dem Beenden (statt Dauerschleife) benutzt wird; als Dauerschleife teuer (jeder 25-s-Zyklus ein Turn).
- **Sicherheit:** gut; keine neuen Geheimnisse, Rechte wie jedes MCP-Tool; Hinweise ohne Inhalt.
- **Nutzen:** Baustein für (b) und für Skills („nach `ask_question` warten“). Eigenständig der kleinste sinnvolle Schritt.

### (b) Stop-Hook im Plugin: bei offener blockierender Frage kurz warten statt enden

- **Idee:** Stop-Hook prüft, ob der Agent in dieser Sitzung eine **blockierende** Frage gestellt hat, auf die noch keine Antwort kam; wenn ja, wartet er bis zu N Sekunden auf Antwort und blockt dann mit `reason: "Antwort liegt vor: get_question …"`, sonst mit `reason: "Frage noch offen, rufe wait_for_events auf …"`. Dadurch endet die Sitzung nicht.
- **Grundproblem:** Der Hook darf laut Plugin-Designregel **kein Token und kein Netzwerk** benutzen. Optionen: (1) Hook-Typ `mcp_tool` ruft `wait_for_events` über die vorhandene, bereits autorisierte MCP-Verbindung auf **[Annahme]**: für Stop erlaubt und mit Plugin-Server nutzbar, **prüfen**; (2) Hook blockt nur mit Anweisung, der **Agent** ruft dann `wait_for_events` auf (kein Hook-Netzwerk, aber ein Turn je Warteschleife); (3) Hook mit eigenem Token: **abzulehnen**.
- **Aufwand:** klein für Variante 2 (Marke „offene Frage“ aus dem Transcript wie in `stop.sh`, Regex auf `ask_question` ohne `answer`/`get_question`), mittel für Variante 1.
- **Robustheit:** mittel. Obergrenze **8 aufeinanderfolgende Fortsetzungen** durch Claude Code, danach endet die Sitzung trotzdem; mit 25 s je Runde ≈ 3,5 min Wartezeit, mit 120 s ≈ 16 min. Für „der Nutzer antwortet in Minuten“ reicht das teilweise, für Stunden nicht. Hängende Hooks halten die Sitzung offen; `timeout` setzen (Standard 600 s).
- **Kosten:** je Runde ein Modell-Turn (Variante 2) bzw. keiner (Variante 1, aber der Hook wartet dann untätig). Leerlauf ohne offene Frage: keine.
- **Sicherheit:** in Variante 1 und 2 kein Token im Hook; `reason` darf nur feste Texte plus IDs enthalten, **keine Nutzertexte** (Prompt-Injection, weil `reason` direkt als Anweisung bei Claude ankommt).
- **Wichtig:** Das ist Erzwingen von Warten, nicht echtes Push; es passt nur zum Fall „Agent hat eine blockierende Frage gestellt und soll auf Antwort warten“.

### (c) MCP-Resource-Subscriptions

- **Spezifikation:** ja. **Claude Code:** keine Doku, kein Beleg für Auswertung; Weck-Wirkung unbelegt. Zusätzlich müsste `/mcp` den GET-SSE-Strom liefern (heute 405), `resources.subscribe=true` melden und einen sitzungsgebundenen Zustand über 3 Replikate halten (Routing Mesh; Sitzung/Strom klebt an einer Replika). **[Annahme]** zum Mehraufwand.
- **Bewertung:** Aufwand hoch, Nutzen unbelegt, Robustheit unbekannt. **Nicht jetzt.** Wiedervorlage, wenn die Claude-Code-Doku Subscriptions oder Server-Notifications als Eingabe erwähnt (Changelog beobachten). Der billige Teil (Capability ehrlich auf `false` lassen) ist bereits so.
- **Zwischenlösung ohne Risiko:** `tools.listChanged` bleibt `false`; Dynamik über Tools, nicht über Listenänderungen.

### (d) Runner und Fernwecken (ohne laufende Sitzung)

- Die Produktidee „lokale Mac-Runner für Claude Code“ löst genau die Fälle, in denen keine Sitzung offen ist: Der Runner erhält über Long-Poll/Push den Auftrag und startet eine **neue** Sitzung (Cloud-/Desktop-Routinen sind dafür ebenfalls belegt: cloud scheduled tasks mit API-Trigger, Desktop scheduled tasks). **[Belegt]** (Existenz laut scheduled-tasks-Seite), Todolino-Verdrahtung ist Produktplanung.
- **Aufwand:** hoch, aber ohnehin Teil des Runner-Plans; Weckreaktion = Auftrag `queued` mit `claim_task`.
- **Grenze:** startet eine neue Sitzung, weckt keine bestehende; Kontext muss aus dem Board kommen (Prinzip „Sessions sind wegwerfbar“, damit ohnehin Designziel).
- **Kosten:** pro Auftrag eine Sitzung, im Leerlauf keine (Runner pollt/wartet ohne Modell).
- **Sicherheit:** Runner-Token liegt beim Runner (eigener Prozess, nicht im Modellkontext), einzeln widerrufbar (IDENTITAET-UND-RECHTE).

### (e) Zusätzlich: Wecker-Prozess per Monitor / Plugin-Monitor / asyncRewake

- **Idee:** ein kleines Skript (z. B. `todolino-wait`) im Plugin (`bin/` ist im Bash-PATH, **[Belegt]**) wartet per Long-Poll und gibt bei Änderung **eine Zeile** aus („Todolino: neue Antwort/Entscheidung, rufe list_open_questions“). Monitor startet es; die Zeile weckt den Agenten, Stille kostet nichts.
- **Hürde Token:** das Skript braucht Zugriff auf unser Backend. Das Plugin-Monitor-Kommando bekommt weder `${user_config.*}` noch `CLAUDE_PLUGIN_OPTION_*`; der MCP-OAuth-Token steht Prozessen nicht zur Verfügung **[Annahme]**. Saubere Wege: (1) das Skript ruft `claude`-fremdes Kommando nicht, sondern nutzt einen **eigenen, schmalen, nur lesenden „Wecker-Token“** (kann nur `sync/wait`, keine Daten), im Schlüsselbund/`chmod 600`-Datei des Nutzers, nicht im Repository und nicht in Hook-Konfigurationen; (2) oder Agent startet `wait_for_events`-Schleife in einem Unteragenten (Option a). Variante (1) widerspricht der aktuellen Regel „Hooks ohne Netzwerk/Token“ nur formal, weil es kein Hook ist; sie braucht dennoch einen neuen Tokentyp (Backend-Arbeit, Scope „nur Live-Hinweis“).
- **Aufwand:** mittel (Skript klein; Wecker-Token = neues Backend-Konzept). **Robustheit:** mittel; Frist 5/30 min je Beobachtung, Neustart nötig; Plugin-Monitors experimentell. **Kosten:** nur bei Ereignis ein Turn. **Sicherheit:** akzeptabel, wenn Token minimal ist und die Ausgabezeile nur feste Texte enthält (Ausgabe ist Eingabe für das Modell: **keine Titel/Kommentartexte** ausgeben, Injection).
- Das ist der Weg, der der Nutzererwartung („kein Poll im Agenten“) am nächsten kommt, ohne Channels.

### (f) Channel-Brücke (stdio) im Plugin

- **Idee:** Plugin liefert zusätzlich einen kleinen stdio-MCP-Server (Node/Bun) mit `claude/channel`, der `sync/wait` per Long-Poll nutzt und `notifications/claude/channel` mit `meta: {kind, project_id, task_id}` sendet; `instructions` erklärt dem Agenten die Reaktion (Daten über den Haupt-MCP holen). Token über `userConfig` `sensitive: true` und `${user_config.KEY}` in `env` (**[Belegt]** für stdio-Server).
- **Aufwand:** mittel (Skript + Plugin-Manifest `channels`), aber braucht ebenfalls einen schmalen Token wie (e).
- **Robustheit/Grenzen:** Research Preview, Flag nicht in `--help`, nur Dev-Schalter für eigene Plugins (Warndialog bei jedem Start), im `-p`-Modus nicht nutzbar, Team/Enterprise brauchen Admin-Freigabe, Protokoll kann sich ändern; nur mit dem Nutzer-Opt-in je Sitzung. Echter Push-Komfort (Agent wacht ohne eigenes Tool auf, Ereignisse werden gebündelt), aber fragil bis die Preview endet oder Todolino auf die Allowlist kommt (Partnerkontakt nötig).
- **Kosten:** nur bei Ereignis ein Turn. **Sicherheit:** Sender-Gating nicht nötig (kein eingehender Fremdkanal; Quelle ist unser Backend mit Nutzerkonto), aber `content` darf keine freien Nutzertexte enthalten; Permission-Relay **nicht** deklarieren.

## 4. Vergleich auf einen Blick

| Option | Weckt von allein | Aufwand | Robustheit | Leerlaufkosten | Token im Hook/Skript | Reife |
| --- | --- | --- | --- | --- | --- | --- |
| a Tool `wait_for_events` | nein (Agent ruft auf) | klein | hoch | niedrig, Dauerschleife teuer | keiner | stabil |
| b Stop-Hook wartet | nein, hält Sitzung offen | klein/mittel | mittel (max. 8 Runden) | niedrig | keiner (Variante 1/2) | stabil, `mcp_tool` prüfen |
| c Resource-Subscription | unbelegt | hoch | unbekannt | unbekannt | keiner | nicht belegt |
| d Runner | startet neue Sitzung | hoch | hoch (eigener Prozess) | keine | Runner-Token beim Runner | Plan |
| e Monitor/asyncRewake-Wecker | ja | mittel | mittel (Fristen, experimentell) | sehr niedrig | schmaler Wecker-Token | Monitor stabil, Plugin-Monitor experimentell |
| f Channel-Brücke | ja | mittel | niedrig bis mittel (Preview) | sehr niedrig | schmaler Token im Plugin-Secret | Preview |

## 5. Empfehlung und Reihenfolge

1. **Jetzt (klein, sicher): Option (a)** `wait_for_events` als MCP-Tool auf Basis von `LiveHub`/`live_events`, Antwort nur Hinweise (`kind`, IDs sichtbarer Objekte), `timeoutSeconds` 1..25 (Standard 20). Im Agentenhandbuch und im Skill: „Nach `ask_question` mit Blockierung zuerst `wait_for_events` (höchstens wenige Runden), danach regulär beenden; Antwort holen mit `get_question`.“ Prüfen: Tool-Zeitlimit von Claude Code für MCP-Aufrufe (Doku/Versuch), Verhalten hinter Zoraxy/Mesh.
2. **Direkt danach: Option (b), Variante 2** (Stop-Hook blockt mit fester Begründung, wenn eine eigene blockierende Frage offen ist, höchstens mit `stop_hook_active`-Schutz und Sitzungsmarke wie in `stop.sh`; der Agent ruft dann `wait_for_events` auf). Variante 1 (`mcp_tool`-Hook) nach Klärung in einem Spike. Erwartung klar kommunizieren: trägt nur wenige Minuten (8 Fortsetzungen).
3. **Spike statt Entscheidung:** (e) und (f) mit einem **Wecker-Token** (Scope „nur Hinweise“, kein Datenzugriff, einzeln widerrufbar, Ablauf). Erst Entscheidung in einem ADR, ob Todolino einen solchen Tokentyp einführt; ohne ihn bleibt es bei (a)+(b). Reihenfolge innerhalb des Spikes: erst Monitor-Skript (stabile Funktion, Doku belegt), dann Channel (Preview) als optionale „Komfortstufe“.
4. **Parallel zur Runner-Planung: Option (d)** für „keine Sitzung offen“. Das ist der einzige Weg, der auch beendete Sitzungen abdeckt.
5. **Nicht bauen: Option (c)**, bis die Claude-Code-Doku Subscriptions als Eingabe beschreibt; `GET /mcp` bleibt 405.

Ehrliche Erwartung: Ein „echter“ Push in eine bestehende Claude-Code-Sitzung ist heute nur über Channels (lokal, Preview, Opt-in) oder über selbst gestartete Monitor-Prozesse möglich. Ein Remote-MCP-Server allein reicht nicht.

## 6. Offene Prüfpunkte (Spikes, jeweils klein)

1. Verarbeitet Claude Code `notifications/resources/updated` oder `notifications/message` von einem HTTP-Server sichtbar im Modell? Test: Testserver mit SSE auf `GET /mcp`, Ausgabe im Debug-Log (`claude --debug`). Bis dahin: nicht belegt.
2. Wird `notifications/claude/channel` auch von einem **HTTP**-MCP-Server akzeptiert, wenn der Dev-Schalter `server:<name>` genutzt wird? Doku sagt stdio; Binary-Handler wirkt generisch.
3. Darf ein `mcp_tool`-Hook an Stop und mit `asyncRewake` hängen, und nutzt er die OAuth-Verbindung des Plugin-Servers?
4. Tool-Zeitlimit für MCP-Aufrufe und Verhalten bei 25-s-Antworten über Zoraxy.
5. Akzeptiert `/v1/sync/wait` den MCP-OAuth-Token? Sonst bleibt es beim Tool (a) oder beim Wecker-Token.
6. Bleibt Monitor/Plugin-Monitor im Hintergrund stabil über Kontext-Kompaktierung (`compact`)? Unbekannt.
7. Verhalten von `run_in_background` bei Prozessende als Weckmechanismus in der Doku nachlesen.

## Quellen

Offiziell (gelesen am 31.10.2026):

- https://code.claude.com/docs/en/channels
- https://code.claude.com/docs/en/channels-reference
- https://code.claude.com/docs/en/mcp
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/tools-reference (Monitor, ScheduleWakeup)
- https://code.claude.com/docs/en/scheduled-tasks
- https://code.claude.com/docs/en/plugins-reference (channels, monitors, userConfig, bin/)
- https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- https://modelcontextprotocol.io/specification/2025-11-25/server/resources

Weitere (nicht offiziell, nur Hinweis): Blogbeiträge zum Monitor-Tool (u. a. agentpatterns.ai, claudefa.st, paulund.co.uk), Version „v2.1.98“ und Verhalten wie Zeilenbündelung/Abschaltung bei Zeilenflut nur dort genannt, **nicht übernommen**.

Lokal (nur lesend): `claude --version` = 2.1.316, `claude --help` (keine Channel-Flags gelistet), Zeichenkettenabgleich im Binary (kein Funktionstest). Repository: `Sources/TodoKit/MCP/MCPController.swift`, `Sources/TodoKit/Live/LiveController.swift`, `docs/adr/0022-live-refresh.md`, `claude-plugin/hooks/hooks.json`, `claude-plugin/scripts/stop.sh`, `docs/CLAUDE-CODE-EINRICHTUNG.md`.
