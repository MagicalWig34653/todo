import Crypto
import Foundation

/// Browser consent page for the OAuth authorization endpoint.
/// It renders everything with textContent (no HTML injection) and talks to the JSON contract
/// (GET /oauth/authorize with Accept: application/json, POST /oauth/consent) using the session cookie.
enum ConsentPage {
    struct Group { let id: String; let title: String }
    struct Entry { let scope: String; let group: String; let label: String; let write: Bool; let critical: Bool }

    static let groups: [Group] = [
        Group(id: "projects", title: "Projekte & Aufgaben"), Group(id: "comments", title: "Kommentare & Anhänge"),
        Group(id: "labels", title: "Labels & Filter"), Group(id: "sharing", title: "Freigaben & Teams"),
        Group(id: "runs", title: "Agentenläufe"), Group(id: "account", title: "Konto"), Group(id: "admin", title: "Administration")]

    static let catalog: [Entry] = [
        Entry(scope: "projects:read", group: "projects", label: "Deine Projekte lesen", write: false, critical: false),
        Entry(scope: "projects:write", group: "projects", label: "Projekte anlegen und ändern (neue Projekte sind automatisch freigegeben)", write: true, critical: false),
        Entry(scope: "tasks:read", group: "projects", label: "Aufgaben, Spalten und Planung lesen", write: false, critical: false),
        Entry(scope: "tasks:write", group: "projects", label: "Aufgaben anlegen, ändern und verschieben", write: true, critical: false),
        Entry(scope: "comments:write", group: "comments", label: "Kommentare und Rückfragen schreiben", write: true, critical: false),
        Entry(scope: "attachments:read", group: "comments", label: "Anhänge lesen", write: false, critical: false),
        Entry(scope: "attachments:write", group: "comments", label: "Anhänge hinzufügen und entfernen", write: true, critical: false),
        Entry(scope: "labels:read", group: "labels", label: "Eigene private Labels lesen", write: false, critical: false),
        Entry(scope: "labels:write", group: "labels", label: "Eigene private Labels verwalten und Aufgaben zuordnen", write: true, critical: false),
        Entry(scope: "filters:read", group: "labels", label: "Eigene gespeicherte Filter lesen und ausführen", write: false, critical: false),
        Entry(scope: "filters:write", group: "labels", label: "Eigene gespeicherte Filter verwalten", write: true, critical: false),
        Entry(scope: "sharing:read", group: "sharing", label: "Freigaben und Sichtbarkeit der freigegebenen Projekte lesen", write: false, critical: false),
        Entry(scope: "sharing:write", group: "sharing", label: "Freigaben für die freigegebenen Projekte setzen (Entzug nur nach Bestätigung)", write: true, critical: true),
        Entry(scope: "teams:read", group: "sharing", label: "Eigene Teams und deren Mitglieder lesen", write: false, critical: false),
        Entry(scope: "teams:write", group: "sharing", label: "Teams anlegen und Personen einladen", write: true, critical: true),
        Entry(scope: "agents:read", group: "runs", label: "Agentenstatus, Fortschritt und Rückfragen lesen", write: false, critical: false),
        Entry(scope: "runs:read", group: "runs", label: "Lokale Agentenläufe und Mac-Geräte lesen", write: false, critical: false),
        Entry(scope: "runs:write", group: "runs", label: "Agentenläufe auf deinen Macs starten und stoppen", write: true, critical: true),
        Entry(scope: "account:read", group: "account", label: "Eigene Darstellungs- und Benachrichtigungseinstellungen lesen", write: false, critical: false),
        Entry(scope: "account:write", group: "account", label: "Eigene Darstellungs- und Benachrichtigungseinstellungen ändern", write: true, critical: false),
        Entry(scope: "admin:read", group: "admin", label: "Als Administrator Konten und Einladungen lesen (nur lesend)", write: false, critical: true)]

    /// Static catalog as JSON for the page script (only constants from this file, so the script hash stays stable).
    static var catalogJSON: String {
        let g = groups.map { ["id": $0.id, "title": $0.title] }
        let c = catalog.map { ["scope": $0.scope, "group": $0.group, "label": $0.label, "write": $0.write, "critical": $0.critical] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: ["groups": g, "scopes": c], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static var script: String { scriptTemplate.replacingOccurrences(of: "__CATALOG__", with: catalogJSON) }

    static let scriptTemplate = """
    const CATALOG = __CATALOG__;
    const q = location.search;
    const root = document.getElementById('root');
    const el = (tag, text, parent, cls) => { const e = document.createElement(tag); if (text) e.textContent = text; if (cls) e.className = cls; (parent || root).appendChild(e); return e; };
    const card = (parent) => el('section', '', parent, 'card');
    async function main() {
      const r = await fetch('/oauth/authorize' + q, { headers: { Accept: 'application/json' }, credentials: 'same-origin' });
      if (r.status === 401) {
        const c = card();
        el('h1', 'Anmeldung erforderlich', c);
        el('p', 'Bitte zuerst in der Todo-App anmelden (Passkey) und diese Seite danach neu laden.', c, 'muted');
        return;
      }
      if (!r.ok) { const c = card(); el('h1', 'Anfrage ungültig', c); el('p', 'Die Autorisierungsanfrage ist ungültig oder abgelaufen.', c, 'muted'); return; }
      const d = await r.json();

      const head = card();
      head.classList.add('head');
      const name = String(d.client_name || 'Anwendung');
      el('div', Array.from(name)[0].toUpperCase(), head, 'avatar').setAttribute('aria-hidden', 'true');
      el('h1', name + ' möchte auf dein Todolino zugreifen', head);
      el('p', 'Prüfe die Berechtigungen und wähle, welche Projekte freigegeben werden. Du kannst den Zugriff jederzeit widerrufen.', head, 'muted');
      const back = el('p', 'Danach geht es zurück zu: ', head, 'back');
      el('span', d.redirect_uri, back, 'uri');

      const perms = card();
      el('h2', 'Berechtigungen', perms);
      const byScope = {}; CATALOG.scopes.forEach(s => { byScope[s.scope] = s; });
      const known = new Set(CATALOG.scopes.map(s => s.scope));
      const unknown = d.scopes.filter(s => !known.has(s));
      let anyCritical = false;
      CATALOG.groups.forEach(g => {
        const items = CATALOG.scopes.filter(s => s.group === g.id && d.scopes.includes(s.scope));
        if (!items.length) return;
        const sec = el('section', '', perms, 'group');
        const h = el('h3', g.title, sec); h.id = 'g-' + g.id; sec.setAttribute('aria-labelledby', h.id);
        const ul = el('ul', '', sec, 'scopes');
        items.forEach(s => {
          const li = el('li', '', ul, s.critical ? 'scope critical' : 'scope');
          const kind = s.critical ? 'Kritisch' : (s.write ? 'Schreiben' : 'Lesen');
          if (s.critical) anyCritical = true;
          el('span', kind, li, 'badge ' + (s.critical ? 'crit' : (s.write ? 'write' : 'read')));
          el('span', s.label, li, 'label');
        });
      });
      if (unknown.length) {
        const sec = el('section', '', perms, 'group'); el('h3', 'Weitere', sec);
        const ul = el('ul', '', sec, 'scopes');
        unknown.forEach(s => { const li = el('li', '', ul, 'scope'); el('span', s, li, 'label'); });
      }
      el('p', (anyCritical ? 'Kritisch markierte Berechtigungen können Zugriff und Freigaben verändern. ' : '') + 'Größere Aktionen, zum Beispiel Löschen oder der Entzug von Freigaben, musst du weiterhin in der Todolino-App bestätigen.', perms, 'notice');

      const pc = el('fieldset', '', root, 'card');
      el('legend', 'Projekte freigeben', pc);
      el('p', 'Nur ausdrücklich gewählte Projekte (samt ihren Unterprojekten in der Liste) werden freigegeben.', pc, 'muted');
      if (d.scopes.includes('projects:write')) el('p', 'Projekte, die über diese Verbindung neu angelegt werden, sind automatisch freigegeben.', pc, 'muted');
      const boxes = [];
      const count = el('p', '', pc, 'count'); count.setAttribute('aria-live', 'polite');
      const msg = el('p', '', root, 'msg'); msg.setAttribute('role', 'alert');
      if (d.projects.length === 0) {
        el('p', 'Keine eigenen Projekte vorhanden.', pc, 'muted');
      } else {
        const tools = el('div', '', pc, 'tools');
        const sl = el('label', 'Projekte suchen', tools, 'sr'); sl.htmlFor = 'psearch';
        const search = el('input', '', tools, 'search'); search.type = 'search'; search.id = 'psearch'; search.placeholder = 'Projekte suchen …'; search.autocomplete = 'off';
        const all = el('button', 'Alle', tools, 'btn small'); all.type = 'button';
        const none = el('button', 'Keine', tools, 'btn small'); none.type = 'button';
        const list = el('div', '', pc, 'plist');
        const ids = new Set(d.projects.map(p => p.id));
        const kids = {};
        d.projects.forEach(p => { const k = (p.parentID && ids.has(p.parentID)) ? p.parentID : ''; (kids[k] = kids[k] || []).push(p); });
        const seen = new Set();
        const walk = (key, depth) => (kids[key] || []).slice().sort((a, b) => a.name.localeCompare(b.name, 'de')).forEach(p => {
          if (seen.has(p.id)) return; seen.add(p.id);
          const row = el('label', '', list, 'prow');
          row.style.paddingLeft = (0.75 + Math.min(depth, 6) * 1.25) + 'rem';
          const cb = el('input', '', row); cb.type = 'checkbox'; cb.value = p.id;
          el('span', p.name, row, 'pname');
          row.dataset.name = p.name.toLowerCase();
          cb.addEventListener('change', update);
          boxes.push(cb);
          walk(p.id, depth + 1);
        });
        walk('', 0);
        const rows = () => Array.from(list.children);
        const none0 = el('p', 'Kein Projekt gefunden.', pc, 'muted'); none0.hidden = true;
        search.addEventListener('input', () => {
          const t = search.value.trim().toLowerCase(); let n = 0;
          rows().forEach(row => { const hit = !t || row.dataset.name.includes(t); row.hidden = !hit; if (hit) n++; });
          none0.hidden = n > 0;
        });
        const setVisible = (v) => { rows().forEach(row => { if (!row.hidden) row.querySelector('input').checked = v; }); update(); };
        all.onclick = () => setVisible(true);
        none.onclick = () => setVisible(false);
      }
      function update() { count.textContent = boxes.filter(b => b.checked).length + ' von ' + boxes.length + ' Projekten ausgewählt'; }
      update();

      const bar = el('div', '', root, 'bar');
      const no = el('button', 'Ablehnen', bar, 'btn secondary'); no.type = 'button';
      const ok = el('button', 'Erlauben', bar, 'btn primary'); ok.type = 'button';
      async function send(approve) {
        const ids = boxes.filter(b => b.checked).map(b => b.value);
        if (approve && ids.length === 0 && !d.scopes.includes('projects:write')) { msg.textContent = 'Bitte mindestens ein Projekt wählen.'; return; }
        msg.textContent = ''; ok.disabled = true; no.disabled = true;
        const res = await fetch('/oauth/consent', { method: 'POST', credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ consent_token: d.consent_token, approve: approve, project_ids: approve ? ids : [] }) });
        if (!res.ok) { msg.textContent = 'Fehlgeschlagen (' + res.status + ').'; ok.disabled = false; no.disabled = false; return; }
        const out = await res.json();
        location.href = out.redirect_uri;
      }
      ok.onclick = () => send(true);
      no.onclick = () => send(false);
    }
    main().catch(() => { el('p', 'Fehler beim Laden.'); });
    """

    static var csp: String {
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        return "default-src 'none'; script-src 'sha256-\(hash)'; connect-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    static let style = """
    :root{color-scheme:light dark;--bg:oklch(.985 0 0);--fg:oklch(.141 .005 285.8);--card:oklch(1 0 0);--muted:oklch(.47 .016 285.9);--border:oklch(.92 .004 286.3);--input:oklch(.88 .004 286.3);--secondary:oklch(.967 .001 286.4);--accent:oklch(.546 .215 262.9);--accent-fg:oklch(1 0 0);--accent-ink:oklch(.488 .215 264);--accent-soft:oklch(.96 .02 262);--ring:oklch(.62 .17 262);--warn:oklch(.55 .13 70);--warn-soft:oklch(.97 .05 85);--shadow:0 1px 2px oklch(0 0 0/5%);--radius:.625rem}
    @media (prefers-color-scheme: dark){:root{--bg:oklch(.141 .005 285.8);--fg:oklch(.985 0 0);--card:oklch(.18 .006 285.9);--muted:oklch(.72 .015 286.1);--border:oklch(1 0 0/10%);--input:oklch(1 0 0/16%);--secondary:oklch(.274 .006 286);--accent:oklch(.62 .19 262);--accent-fg:oklch(.141 .005 285.8);--accent-ink:oklch(.75 .14 262);--accent-soft:oklch(.27 .06 262);--ring:oklch(.65 .17 262);--warn:oklch(.8 .14 80);--warn-soft:oklch(.29 .05 80);--shadow:0 1px 2px oklch(0 0 0/30%)}}
    *{box-sizing:border-box}
    html{-webkit-text-size-adjust:100%}
    body{margin:0;background:var(--bg);color:var(--fg);font:1rem/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
    main{max-width:36rem;margin:0 auto;padding:1rem 1rem 0;display:flex;flex-direction:column;gap:1rem}
    .card{background:var(--card);border:1px solid var(--border);border-radius:calc(var(--radius) * 1.4);box-shadow:var(--shadow);padding:1.25rem;margin:0;min-width:0}
    h1{font-size:1.4rem;line-height:1.25;margin:0 0 .5rem;overflow-wrap:anywhere}
    h2,legend{font-size:1.1rem;font-weight:600;margin:0 0 .5rem;padding:0}
    h3{font-size:.8rem;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);margin:1rem 0 .25rem}
    p{margin:.25rem 0}
    .muted{color:var(--muted);font-size:.95rem}
    .head{text-align:left}
    .avatar{width:3rem;height:3rem;border-radius:.9rem;background:var(--accent);color:var(--accent-fg);display:grid;place-items:center;font-size:1.5rem;font-weight:700;margin-bottom:.75rem}
    .back{font-size:.85rem;color:var(--muted);margin-top:.75rem}
    .uri{overflow-wrap:anywhere;word-break:break-all;font-family:ui-monospace,monospace;color:var(--fg)}
    .scopes{list-style:none;margin:0;padding:0}
    .scope{display:flex;gap:.75rem;align-items:flex-start;padding:.5rem .5rem;border-radius:var(--radius)}
    .scope+.scope{margin-top:.125rem}
    .scope.critical{background:var(--warn-soft);border:1px solid var(--warn)}
    .label{flex:1;min-width:0;overflow-wrap:anywhere}
    .badge{flex:none;min-width:5.5rem;text-align:center;font-size:.75rem;font-weight:600;border-radius:999px;padding:.125rem .6rem;border:1px solid var(--border);background:var(--secondary);color:var(--muted)}
    .badge.write{background:var(--accent-soft);color:var(--accent-ink);border-color:transparent}
    .badge.crit{background:var(--warn);color:var(--card);border-color:transparent}
    .notice{margin-top:1rem;padding:.75rem;border-radius:var(--radius);background:var(--accent-soft);color:var(--accent-ink);font-size:.95rem}
    .tools{display:flex;gap:.5rem;flex-wrap:wrap;margin:.75rem 0 .5rem}
    .search{flex:1 1 10rem;min-width:0;min-height:2.75rem;font:inherit;color:var(--fg);background:var(--card);border:1px solid var(--input);border-radius:var(--radius);padding:.25rem .75rem}
    .sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
    .plist{border:1px solid var(--border);border-radius:var(--radius);max-height:18rem;overflow:auto}
    .prow{display:flex;align-items:center;gap:.75rem;min-height:2.75rem;padding:.25rem .75rem;cursor:pointer}
    .prow[hidden]{display:none}
    .prow+.prow{border-top:1px solid var(--border)}
    .prow:hover{background:var(--secondary)}
    .prow input{flex:none;width:1.25rem;height:1.25rem;accent-color:var(--accent)}
    .pname{min-width:0;overflow-wrap:anywhere}
    .count{font-size:.9rem;font-weight:600;color:var(--accent-ink)}
    .msg{color:var(--warn);font-weight:600;margin:0}
    .msg:empty{display:none}
    .bar{position:sticky;bottom:0;display:flex;gap:.75rem;justify-content:flex-end;padding:.75rem 1rem calc(.75rem + env(safe-area-inset-bottom));margin:0 -1rem;background:var(--bg);border-top:1px solid var(--border)}
    .btn{font:inherit;font-weight:600;min-height:2.75rem;min-width:2rem;padding:.5rem 1.25rem;border-radius:var(--radius);border:1px solid var(--input);background:var(--card);color:var(--fg);cursor:pointer}
    .btn.small{padding:.25rem .9rem;font-weight:500}
    .btn.primary{background:var(--accent);color:var(--accent-fg);border-color:transparent;flex:1 1 auto}
    .btn.secondary{flex:0 1 auto}
    .btn:disabled{opacity:.6;cursor:default}
    .btn:hover:not(:disabled){filter:brightness(.96)}
    :focus-visible{outline:3px solid var(--ring);outline-offset:2px}
    @media (max-width:30rem){.bar .btn{flex:1 1 0}.scope{flex-wrap:wrap;gap:.25rem}}
    @media (prefers-reduced-motion: no-preference){.btn{transition:filter .15s}}
    """

    static var html: String {
        """
        <!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Zugriff erlauben</title>
        <style>\(style)</style></head>
        <body><main id="root"></main><script>\(script)</script></body></html>
        """
    }
}
