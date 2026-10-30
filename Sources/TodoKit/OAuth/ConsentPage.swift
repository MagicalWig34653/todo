import Crypto
import Foundation

/// Minimal browser consent page for the OAuth authorization endpoint.
/// It renders everything with textContent (no HTML injection) and talks to the JSON contract
/// (GET /oauth/authorize with Accept: application/json, POST /oauth/consent) using the session cookie.
enum ConsentPage {
    static let script = """
    const q = location.search;
    const root = document.getElementById('root');
    const el = (tag, text, parent) => { const e = document.createElement(tag); if (text !== undefined) e.textContent = text; (parent || root).appendChild(e); return e; };
    async function main() {
      const r = await fetch('/oauth/authorize' + q, { headers: { Accept: 'application/json' }, credentials: 'same-origin' });
      if (r.status === 401) {
        el('h1', 'Anmeldung erforderlich');
        el('p', 'Bitte zuerst in der Todo-App anmelden (Passkey) und diese Seite danach neu laden.');
        return;
      }
      if (!r.ok) { el('h1', 'Anfrage ungültig'); el('p', 'Die Autorisierungsanfrage ist ungültig oder abgelaufen.'); return; }
      const d = await r.json();
      el('h1', 'Zugriff erlauben?');
      el('p', 'Die Anwendung „' + d.client_name + '“ möchte im Namen deines Kontos auf Todolino zugreifen.');
      el('p', 'Rückkehr nach: ' + d.redirect_uri);
      el('h2', 'Berechtigungen');
      const ul = el('ul'); d.scopes.forEach(s => el('li', s, ul));
      el('h2', 'Projekte (nur ausdrücklich gewählte werden freigegeben)');
      const boxes = [];
      if (d.projects.length === 0) el('p', 'Keine eigenen Projekte vorhanden.');
      d.projects.forEach(p => {
        const label = el('label'); label.style.display = 'block';
        const cb = document.createElement('input'); cb.type = 'checkbox'; cb.value = p.id; label.appendChild(cb);
        label.appendChild(document.createTextNode(' ' + p.name)); boxes.push(cb);
      });
      const msg = el('p');
      async function send(approve) {
        const ids = boxes.filter(b => b.checked).map(b => b.value);
        if (approve && ids.length === 0) { msg.textContent = 'Bitte mindestens ein Projekt wählen.'; return; }
        const res = await fetch('/oauth/consent', { method: 'POST', credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ consent_token: d.consent_token, approve: approve, project_ids: approve ? ids : [] }) });
        if (!res.ok) { msg.textContent = 'Fehlgeschlagen (' + res.status + ').'; return; }
        const out = await res.json();
        location.href = out.redirect_uri;
      }
      const ok = el('button', 'Erlauben'); ok.onclick = () => send(true);
      const no = el('button', 'Ablehnen'); no.onclick = () => send(false);
    }
    main().catch(() => { el('p', 'Fehler beim Laden.'); });
    """

    static var csp: String {
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        return "default-src 'none'; script-src 'sha256-\(hash)'; connect-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    static var html: String {
        """
        <!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Zugriff erlauben</title>
        <style>body{font:16px system-ui,sans-serif;max-width:34rem;margin:2rem auto;padding:0 1rem}button{font:inherit;margin:.5rem .5rem 0 0;padding:.5rem 1rem}</style></head>
        <body><main id="root"></main><script>\(script)</script></body></html>
        """
    }
}
