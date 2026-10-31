// Static site generator for GitHub Pages. docs/ and contracts/ stay the single source;
// this script only renders them into docs-site/dist. Run: npm ci && node build.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';
import YAML from 'yaml';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..');
const out = path.join(here, 'dist');
const GH = 'https://github.com/MagicalWig34653/todo';
const REDOC = 'https://cdn.jsdelivr.net/npm/redoc@2.1.5/bundles/redoc.standalone.js';

const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const read = (p) => fs.readFileSync(p, 'utf8');
const write = (rel, data) => {
  const p = path.join(out, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, data);
};
const slugify = (s) =>
  s.toLowerCase().replace(/ä/g, 'ae').replace(/ö/g, 'oe').replace(/ü/g, 'ue').replace(/ß/g, 'ss')
    .replace(/<[^>]+>/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'abschnitt';

// ---------- page registry ----------
const pages = []; // {slug (output path), title, group, kind}
const groups = ['Einstieg', 'Agenten', 'Technik', 'Entscheidungen', 'API', 'Apple', 'Projekt'];
const mdBySource = new Map(); // basename -> slug for link rewriting

function addMd({ slug, src, group, title, text, nav = true }) {
  const raw = text ?? read(path.join(repo, src));
  const m = raw.match(/^#\s+(.+)$/m);
  const t = title ?? (m ? m[1].trim() : slug);
  pages.push({ slug, title: t, group, kind: 'md', raw, src, nav });
  if (src) mdBySource.set(path.basename(src), slug);
}

// README extract for the quickstart page
const readme = read(path.join(repo, 'README.md'));
const sect = (name) => {
  const re = new RegExp(`^## ${name}.*?$([\\s\\S]*?)(?=^## |(?![\\s\\S]))`, 'm');
  const m = readme.match(re);
  return m ? m[0] : '';
};
addMd({
  slug: 'schnellstart.html', group: 'Einstieg', title: 'Schnellstart',
  text: `# Schnellstart\n\nDieser Abschnitt stammt aus der README des Repositorys.\n\n${sect('Schnellstart')}\n${sect('Tests')}\n${sect('CI und Veröffentlichung')}\n${sect('Repository-Struktur')}`,
});
addMd({ slug: 'installation.html', src: 'docs-site/content/installation.md', group: 'Einstieg' });
addMd({ slug: 'produkt.html', src: 'docs/PRODUKT.md', group: 'Einstieg' });
addMd({ slug: 'steuerzentrale.html', src: 'docs-site/content/steuerzentrale.md', group: 'Agenten' });
addMd({ slug: 'projekt-onboarding.html', src: 'docs-site/content/projekt-onboarding.md', group: 'Agenten' });
addMd({ slug: 'claude-code-einrichtung.html', src: 'docs/CLAUDE-CODE-EINRICHTUNG.md', group: 'Agenten' });
addMd({ slug: 'runner.html', src: 'docs-site/content/runner.md', group: 'Agenten' });
addMd({ slug: 'agenten-und-mcp.html', src: 'docs/AGENTEN-UND-MCP.md', group: 'Agenten' });
addMd({ slug: 'agent-manual.html', src: 'docs/agent-manual.md', group: 'Agenten', title: 'Agentenhandbuch (englisch)' });
addMd({ slug: 'sync-aufbewahrung.html', src: 'docs-site/content/sync-aufbewahrung.md', group: 'Technik' });
addMd({ slug: 'architektur.html', src: 'docs/ARCHITEKTUR.md', group: 'Technik' });
addMd({ slug: 'identitaet-und-rechte.html', src: 'docs/IDENTITAET-UND-RECHTE.md', group: 'Technik' });
addMd({ slug: 'push-an-claude-code.html', src: 'docs/PUSH-AN-CLAUDE-CODE.md', group: 'Agenten', title: 'Push an Claude Code (Recherche)' });
addMd({ slug: 'push-einrichtung.html', src: 'docs/PUSH-EINRICHTUNG.md', group: 'Technik' });
addMd({ slug: 'betrieb.html', src: 'docs/BETRIEB.md', group: 'Technik', title: 'Betrieb und Swarm' });
addMd({ slug: 'entscheidungen.html', src: 'docs/ENTSCHEIDUNGEN.md', group: 'Entscheidungen', title: 'Entscheidungen' });
const adrFiles = fs.readdirSync(path.join(repo, 'docs/adr')).filter((f) => f.endsWith('.md')).sort();
pages.push({ slug: 'adr/index.html', title: 'Architekturentscheidungen (ADRs)', group: 'Entscheidungen', kind: 'adr-index' });
for (const f of adrFiles) {
  addMd({ slug: `adr/${f.replace(/\.md$/, '.html')}`, src: `docs/adr/${f}`, group: 'Entscheidungen', nav: false });
}
addMd({ slug: 'apple.html', src: 'docs-site/content/apple.md', group: 'Apple', title: 'iOS, macOS, TestFlight' });
addMd({ slug: 'todoist-vergleich.html', src: 'docs/TODOIST-VERGLEICH.md', group: 'Projekt', title: 'Todoist-Vergleich' });
addMd({ slug: 'status.html', src: 'docs/STATUS.md', group: 'Projekt' });
addMd({ slug: 'arbeitsplan.html', src: 'docs/ARBEITSPLAN.md', group: 'Projekt' });
addMd({ slug: 'umsetzungsplan.html', src: 'docs/UMSETZUNGSPLAN.md', group: 'Projekt' });

// contracts
const contractFiles = fs.readdirSync(path.join(repo, 'contracts')).filter((f) => f.endsWith('.yaml')).sort((a, b) => (a === 'openapi.yaml' ? -1 : b === 'openapi.yaml' ? 1 : a.localeCompare(b)));
const contracts = contractFiles.map((f) => {
  const text = read(path.join(repo, 'contracts', f));
  let doc;
  try { doc = YAML.parse(text); } catch (e) { console.warn(`WARN contracts/${f} is not valid YAML (${e.message.split('\n')[0]}); rendered as raw text`); doc = { info: { title: f.replace(/\.yaml$/, ''), description: 'Dieser Vertrag ist (noch) kein gültiges YAML und wird nur als Rohtext angezeigt.' }, invalid: true }; }
  return { file: f, name: f.replace(/\.yaml$/, ''), text, doc };
});
pages.push({ slug: 'api/index.html', title: 'API-Verträge', group: 'API', kind: 'api-index' });
for (const c of contracts) pages.push({ slug: `api/${c.name}.html`, title: c.doc?.info?.title ?? c.name, group: 'API', kind: 'contract', c, nav: false });
pages.push({ slug: 'api/redoc.html', title: 'API-Referenz (Redoc)', group: 'API', kind: 'redoc', nav: false });
pages.push({ slug: 'screenshots.html', title: 'Screenshots', group: 'Einstieg', kind: 'shots', nav: false });

const bySlug = new Map(pages.map((p) => [p.slug, p]));

// ---------- markdown ----------
function makeMarked(page) {
  const dir = page.src ? path.posix.dirname(page.src) : '.';
  const toc = [];
  const used = new Map();
  const marked = new Marked({ gfm: true });
  marked.use({
    renderer: {
      heading({ tokens, depth }) {
        const html = this.parser.parseInline(tokens);
        let id = slugify(html);
        const n = used.get(id) ?? 0;
        used.set(id, n + 1);
        if (n) id += `-${n}`;
        if (depth === 2 || depth === 3) toc.push({ depth, id, text: html.replace(/<[^>]+>/g, '') });
        return `<h${depth} id="${id}">${html}</h${depth}>\n`;
      },
      table(token) {
        const head = token.header.map((c) => `<th${c.align ? ` align="${c.align}"` : ''}>${this.parser.parseInline(c.tokens)}</th>`).join('');
        const rows = token.rows.map((r) => `<tr>${r.map((c) => `<td${c.align ? ` align="${c.align}"` : ''}>${this.parser.parseInline(c.tokens)}</td>`).join('')}</tr>`).join('\n');
        return `<div class="tablewrap"><table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table></div>\n`;
      },
      link({ href, title, tokens }) {
        const text = this.parser.parseInline(tokens);
        const t = title ? ` title="${esc(title)}"` : '';
        return `<a href="${esc(resolveHref(href, dir, page))}"${t}${/^https?:/.test(href) ? ' rel="noopener"' : ''}>${text}</a>`;
      },
      html({ text }) {
        return esc(text); // docs are plain Markdown; never pass raw HTML through
      },
    },
  });
  return { marked, toc };
}

function relTo(from, to) {
  const r = path.posix.relative(path.posix.dirname(from), to);
  return r || path.posix.basename(to);
}

function resolveHref(href, dir, page) {
  if (!href || /^(https?:|mailto:|#)/.test(href)) return href;
  const [file, hash] = href.split('#');
  if (page.src?.startsWith('docs-site/content/') && file.endsWith('.html')) return href; // site-internal page link
  const base = path.posix.basename(file);
  if (file.endsWith('.md') && mdBySource.has(base)) return relTo(page.slug, mdBySource.get(base)) + (hash ? `#${hash}` : '');
  const c = file.match(/contracts\/([\w-]+)\.yaml$/);
  if (c) return relTo(page.slug, `api/${c[1]}.html`);
  if (/docs-site\/screenshots\/?$/.test(file)) return relTo(page.slug, 'screenshots.html');
  const norm = path.posix.normalize(path.posix.join(dir, file));
  const isDir = !path.posix.extname(norm);
  return `${GH}/${isDir ? 'tree' : 'blob'}/main/${norm}`;
}

// ---------- layout ----------
const topNav = [
  ['schnellstart.html', 'Schnellstart'],
  ['architektur.html', 'Architektur'],
  ['steuerzentrale.html', 'Agenten'],
  ['betrieb.html', 'Betrieb'],
  ['adr/index.html', 'ADRs'],
  ['api/index.html', 'API'],
  ['apple.html', 'Apple'],
  ['status.html', 'Status'],
];

const themeScript = `(function(){try{var t=localStorage.getItem('theme');if(t)document.documentElement.dataset.theme=t}catch(e){}})()`;
const uiScript = `
(function(){
  var r=document.documentElement,b=document.getElementById('theme');
  function cur(){return r.dataset.theme||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light')}
  function label(){b.textContent=cur()==='dark'?'Hell':'Dunkel';b.setAttribute('aria-label',cur()==='dark'?'Zum hellen Design wechseln':'Zum dunklen Design wechseln')}
  b.addEventListener('click',function(){var n=cur()==='dark'?'light':'dark';r.dataset.theme=n;try{localStorage.setItem('theme',n)}catch(e){}label()});
  label();
  var sd=document.querySelector('.sided');if(sd&&matchMedia('(max-width:820px)').matches)sd.open=false;
  var m=document.getElementById('menu'),n=document.getElementById('nav');
  m.addEventListener('click',function(){var o=n.classList.toggle('open');m.setAttribute('aria-expanded',o)});
})();`;

function layout(page, body, { toc = [], sidebar = true, wide = false } = {}) {
  const root = '../'.repeat(page.slug.split('/').length - 1);
  const a = (slug, text) => `<a href="${root}${slug}"${page.slug === slug || (page.slug.startsWith('adr/') && slug === 'adr/index.html') || (page.slug.startsWith('api/') && slug === 'api/index.html') ? ' aria-current="page"' : ''}>${text}</a>`;
  const nav = topNav.map(([s, t]) => a(s, t)).join('');
  const side = sidebar
    ? `<details class="sided" open><summary>Dokumentation</summary><nav class="side" aria-label="Dokumentation">${groups
        .map((g) => {
          const items = pages.filter((p) => p.group === g && p.nav !== false);
          if (!items.length) return '';
          return `<h2>${esc(g)}</h2><ul>${items.map((p) => `<li>${a(p.slug, esc(p.title))}</li>`).join('')}</ul>`;
        })
        .join('')}</nav></details>`
    : '';
  const tocHtml = toc.length > 2
    ? `<details class="toc" open><summary>Auf dieser Seite</summary><ul>${toc.map((t) => `<li class="d${t.depth}"><a href="#${t.id}">${esc(t.text)}</a></li>`).join('')}</ul></details>`
    : '';
  const title = page.slug === 'index.html' ? 'Todolino – Projektplanung für Menschen und Agenten' : `${page.title} – Todolino`;
  return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="Todolino: intuitive Todo- und Projektplanung mit verschachtelten Projekten, Teams, Passkeys, PWA, SwiftUI, MCP und lokalen Claude-Code-Runnern.">
<meta name="color-scheme" content="light dark">
<script>${themeScript}</script>
<link rel="stylesheet" href="${root}style.css">
</head>
<body>
<a class="skip" href="#inhalt">Zum Inhalt</a>
<header class="top"><div class="bar">
<a class="brand" href="${root}index.html"><span class="logo" aria-hidden="true">&#10003;</span> Todolino</a>
<nav id="nav" class="nav" aria-label="Hauptnavigation">${nav}<a href="${GH}" rel="noopener">GitHub</a></nav>
<button id="theme" class="btn" type="button">Dunkel</button>
<button id="menu" class="btn menu" type="button" aria-expanded="false" aria-controls="nav">Menü</button>
</div></header>
<div class="page${sidebar ? ' with-side' : ''}${wide ? ' wide' : ''}">
${side}
<main id="inhalt">
${tocHtml}
${body}
</main>
</div>
<footer class="foot"><div class="bar">Todolino – Projekt im Aufbau. Diese Seite wird beim Build aus <code>docs/</code> und <code>contracts/</code> erzeugt und enthält keine Zugangsdaten und keine Laufzeitdaten. <a href="${GH}" rel="noopener">Quellcode</a></div></footer>
<script>${uiScript}</script>
</body>
</html>
`;
}

// ---------- renderers ----------
function renderMd(page) {
  const { marked, toc } = makeMarked(page);
  let html = marked.parse(page.raw);
  const edit = page.src && page.src.startsWith('docs/') ? `<p class="srclink">Quelle: <a href="${GH}/blob/main/${page.src}" rel="noopener"><code>${page.src}</code></a></p>` : '';
  html = `<article class="doc">${html}${edit}</article>`;
  return layout(page, html, { toc });
}

function renderAdrIndex(page) {
  const items = pages.filter((p) => p.slug.startsWith('adr/') && p.kind === 'md');
  const li = items.map((p) => {
    const status = (p.raw.match(/^Status:\s*(.+)$/m) || [])[1] ?? '';
    return `<li><a href="${path.posix.basename(p.slug)}">${esc(p.title)}</a>${status ? `<br><span class="muted">${esc(status.slice(0, 140))}</span>` : ''}</li>`;
  }).join('');
  return layout(page, `<article class="doc"><h1>${esc(page.title)}</h1><p>Wesentliche Architekturentscheidungen mit Begründung und Folgen. Die übergreifende Liste steht unter <a href="../entscheidungen.html">Entscheidungen</a>.</p><ul class="list">${li}</ul></article>`);
}

function typeStr(s) {
  if (!s) return '';
  if (s.$ref) return `<a href="#schema-${slugify(s.$ref.split('/').pop())}">${esc(s.$ref.split('/').pop())}</a>`;
  if (s.allOf) return s.allOf.map(typeStr).join(' + ');
  if (s.oneOf || s.anyOf) return (s.oneOf || s.anyOf).map(typeStr).join(' | ');
  if (s.enum) return `${esc(s.type ?? 'enum')}: ${s.enum.map((e) => `<code>${esc(e)}</code>`).join(', ')}`;
  if (s.type === 'array') return `Array&lt;${typeStr(s.items)}&gt;`;
  return esc(s.type ?? 'object') + (s.format ? ` (${esc(s.format)})` : '') + (s.nullable ? ', nullable' : '');
}

function resolveRef(doc, obj) {
  if (obj?.$ref && obj.$ref.startsWith('#/')) {
    return obj.$ref.slice(2).split('/').reduce((a, k) => a?.[k], doc) ?? obj;
  }
  return obj;
}

function renderContract(page) {
  const { c } = page;
  const doc = c.doc;
  const info = doc.info ?? {};
  const { marked } = makeMarked({ slug: page.slug, src: 'contracts/x' });
  let h = `<article class="doc"><h1>${esc(info.title ?? c.name)}</h1>`;
  h += `<p class="muted">Datei <code>contracts/${esc(c.file)}</code> · OpenAPI ${esc(doc.openapi ?? '')} · Version ${esc(info.version ?? '')} · <a href="${esc(c.file)}">YAML herunterladen</a> · <a href="redoc.html?spec=${esc(c.file)}">In Redoc öffnen</a></p>`;
  if (info.description) h += marked.parse(String(info.description));
  const paths = doc.paths ?? {};
  const ops = [];
  for (const [p, item] of Object.entries(paths)) {
    for (const m of ['get', 'post', 'put', 'patch', 'delete', 'head']) if (item[m]) ops.push({ p, m, op: item[m], item });
  }
  if (ops.length) {
    h += `<h2 id="endpunkte">Endpunkte (${ops.length})</h2><div class="tablewrap"><table><thead><tr><th>Methode</th><th>Pfad</th><th>Beschreibung</th></tr></thead><tbody>`;
    for (const { p, m, op } of ops) h += `<tr><td><span class="m ${m}">${m.toUpperCase()}</span></td><td><code>${esc(p)}</code></td><td>${esc(op.summary ?? op.operationId ?? '')}</td></tr>`;
    h += `</tbody></table></div><h2 id="details">Details</h2>`;
    for (const { p, m, op, item } of ops) {
      h += `<details class="op"><summary><span class="m ${m}">${m.toUpperCase()}</span> <code>${esc(p)}</code> <span class="muted">${esc(op.summary ?? '')}</span></summary><div class="opbody">`;
      if (op.description) h += `<div>${marked.parse(String(op.description))}</div>`;
      const params = [...(item.parameters ?? []), ...(op.parameters ?? [])].map((x) => resolveRef(doc, x));
      if (params.length) {
        h += `<h4>Parameter</h4><div class="tablewrap"><table><thead><tr><th>Name</th><th>Ort</th><th>Typ</th><th>Pflicht</th><th>Beschreibung</th></tr></thead><tbody>`;
        for (const q of params) h += `<tr><td><code>${esc(q.name)}</code></td><td>${esc(q.in)}</td><td>${typeStr(q.schema)}</td><td>${q.required ? 'ja' : 'nein'}</td><td>${esc(q.description ?? '')}</td></tr>`;
        h += `</tbody></table></div>`;
      }
      const rb = resolveRef(doc, op.requestBody);
      if (rb?.content) {
        const [mt, v] = Object.entries(rb.content)[0] ?? [];
        h += `<h4>Request-Body</h4><p>${esc(mt ?? '')}: ${typeStr(v?.schema)}${rb.required ? ' (Pflicht)' : ''}</p>`;
      }
      const rs = Object.entries(op.responses ?? {});
      if (rs.length) {
        h += `<h4>Antworten</h4><div class="tablewrap"><table><thead><tr><th>Status</th><th>Inhalt</th><th>Beschreibung</th></tr></thead><tbody>`;
        for (const [code, r0] of rs) {
          const r = resolveRef(doc, r0);
          const v = r?.content ? Object.values(r.content)[0] : null;
          h += `<tr><td><code>${esc(code)}</code></td><td>${v ? typeStr(v.schema) : ''}</td><td>${esc(r?.description ?? '')}</td></tr>`;
        }
        h += `</tbody></table></div>`;
      }
      if (op.security) h += `<p class="muted">Sicherheit: ${esc(JSON.stringify(op.security.map((s) => Object.keys(s).join('+'))))}</p>`;
      h += `</div></details>`;
    }
  }
  const schemas = doc.components?.schemas ?? {};
  const sn = Object.keys(schemas);
  if (sn.length) {
    h += `<h2 id="schemas">Schemas (${sn.length})</h2>`;
    for (const n of sn) {
      const s = schemas[n];
      h += `<details class="op" id="schema-${slugify(n)}"><summary><code>${esc(n)}</code> <span class="muted">${typeStr({ ...s, $ref: undefined })}</span></summary><div class="opbody">`;
      if (s.description) h += `<p>${esc(s.description)}</p>`;
      const props = s.properties ?? {};
      if (Object.keys(props).length) {
        h += `<div class="tablewrap"><table><thead><tr><th>Feld</th><th>Typ</th><th>Pflicht</th><th>Beschreibung</th></tr></thead><tbody>`;
        for (const [k, v] of Object.entries(props)) h += `<tr><td><code>${esc(k)}</code></td><td>${typeStr(v)}</td><td>${(s.required ?? []).includes(k) ? 'ja' : ''}</td><td>${esc(v.description ?? '')}</td></tr>`;
        h += `</tbody></table></div>`;
      }
      h += `</div></details>`;
    }
  }
  h += `<h2 id="yaml">Rohdatei</h2><details class="op"><summary>YAML anzeigen</summary><pre><code>${esc(c.text)}</code></pre></details></article>`;
  return layout(page, h, { toc: [] });
}

function renderApiIndex(page) {
  const rows = contracts.map((c) => {
    const n = Object.values(c.doc.paths ?? {}).reduce((a, it) => a + ['get', 'post', 'put', 'patch', 'delete'].filter((m) => it[m]).length, 0);
    const desc = String(c.doc.info?.description ?? '').split('\n')[0].slice(0, 220);
    return `<tr><td><a href="${c.name}.html">${esc(c.doc.info?.title ?? c.name)}</a><br><code>${esc(c.file)}</code></td><td>${esc(c.doc.info?.version ?? '')}</td><td>${n}</td><td>${esc(desc)}</td><td><a href="redoc.html?spec=${c.file}">Redoc</a> · <a href="${c.file}">YAML</a></td></tr>`;
  }).join('');
  const body = `<article class="doc"><h1>API-Verträge</h1><p>Die OpenAPI-Verträge liegen im Repository unter <code>contracts/</code> und sind die gemeinsame Grundlage von Backend, PWA, Apple-Apps, MCP und Runnern. Jeder Vertrag ist hier lesbar aufbereitet; zusätzlich gibt es eine interaktive Referenz mit <a href="redoc.html">Redoc</a>.</p><div class="tablewrap"><table><thead><tr><th>Vertrag</th><th>Version</th><th>Operationen</th><th>Beschreibung</th><th>Ansichten</th></tr></thead><tbody>${rows}</tbody></table></div></article>`;
  return layout(page, body);
}

function renderRedoc(page) {
  const opts = contracts.map((c) => `<option value="${c.file}">${esc(c.doc.info?.title ?? c.name)} (${c.file})</option>`).join('');
  const body = `<div class="redocbar"><label>Vertrag: <select id="spec">${opts}</select></label> <span class="muted">Die Referenz lädt Redoc 2.1.5 von cdn.jsdelivr.net.</span></div><div id="redoc" class="redoc"><p>Referenz wird geladen ...</p></div>
<script src="${REDOC}"></script>
<script>
(function(){
  var sel=document.getElementById('spec'),q=new URLSearchParams(location.search).get('spec')||'openapi.yaml';
  if(![].some.call(sel.options,function(o){return o.value===q}))q='openapi.yaml';
  sel.value=q;
  function dark(){var t=document.documentElement.dataset.theme;return t?t==='dark':matchMedia('(prefers-color-scheme:dark)').matches}
  function init(){
    var el=document.getElementById('redoc');el.innerHTML='';
    if(!window.Redoc){el.innerHTML='<p>Redoc konnte nicht geladen werden. Die Verträge sind weiterhin als <a href="index.html">lesbare Seiten</a> verfügbar.</p>';return}
    var d=dark();
    Redoc.init(sel.value,{hideDownloadButton:false,theme:{colors:{primary:{main:d?'#7b9cff':'#2f5bea'},text:{primary:d?'#e8eaf0':'#1c1f26'},http:{}},rightPanel:{backgroundColor:'#1b1e27'},sidebar:{backgroundColor:d?'#1b1e27':'#f4f6fb',textColor:d?'#e8eaf0':'#1c1f26'}}},el);
  }
  sel.addEventListener('change',function(){history.replaceState(null,'','?spec='+sel.value);init()});
  document.getElementById('theme').addEventListener('click',function(){setTimeout(init,0)});
  init();
})();
</script>`;
  return layout(page, body, { sidebar: false, wide: true });
}

const shots = {
  desktop: [
    ['projekte-aufgaben', 'Projektbaum mit frei verschachtelten Projekten und Aufgabenliste'],
    ['aufgabendetail', 'Aufgabendetail mit Planung, Labels, Abnahmekriterien und Kommentaren'],
    ['board', 'Board-Ansicht mit Statusspalten'],
    ['heute', 'Ansicht „Heute“ mit fälligen Aufgaben'],
    ['suche', 'Suche mit gespeicherten Filtern'],
    ['teams', 'Teams'],
    ['freigaben', 'Projektfreigaben an ein Team'],
    ['zustimmung', 'OAuth-Zustimmung für einen KI-Assistenten (MCP)'],
    ['konto', 'Konto und Sicherheit: Passkeys, Sitzungen, verbundene Anwendungen'],
    ['darstellung-hell', 'Darstellung (hell): Farbschema, Akzentfarbe, Leuchteffekt, Transparenz'],
    ['darstellung-dunkel', 'Darstellung (dunkel)'],
    ['login', 'Anmeldung per Passkey'],
  ],
  agents: [
    ['ueberblick-kanban', 'Steuerzentrale: Kanban mit Läuft, Frage offen, Review fällig'],
    ['ueberblick-fragen', 'Offene Fragen der Agenten direkt beantworten (dunkles Design)'],
    ['ueberblick-liste', 'Steuerzentrale als Liste mit Filtern'],
    ['ueberblick-updates', 'Updates: Fortschritt und Builds'],
    ['ueberblick-projekt', 'Überblick eines Projekts mit Unterprojekten'],
    ['ueberblick-briefing', 'Projekt-Briefing und Standard-Spalten für Agenten'],
    ['agenten', 'Agenten: Runner koppeln, Geräte, Aufträge'],
    ['aktivitaet', 'Aktivitätsfeed aller Projekte'],
    ['projektkommentare', 'Projektkommentare'],
  ],
  mobil: [
    ['ueberblick-mobil', 'Steuerzentrale'], ['aufgaben-mobil', 'Aufgabenliste'], ['board-mobil', 'Board'], ['aufgabendetail-mobil', 'Aufgabendetail'],
    ['heute-mobil', 'Heute'], ['projekte-mobil', 'Projektnavigation'], ['suche-mobil', 'Suche'],
    ['teams-mobil', 'Teams'], ['konto-mobil', 'Konto'], ['login-mobil', 'Anmeldung'],
  ],
  ios: [
    ['ios-heute', 'Heute'], ['ios-anstehend', 'Anstehend'], ['ios-projekt', 'Projekt'],
    ['ios-aufgabe', 'Aufgabe'], ['ios-suche', 'Suche'], ['ios-teams', 'Teams'],
  ],
  ipad: [
    ['ipad-heute', 'Heute'], ['ipad-projekt', 'Projekt'], ['ipad-aufgabe', 'Aufgabe'], ['ipad-teams', 'Teams'],
  ],
};
const fig = (root, [f, cap], cls = '') =>
  `<figure class="${cls}"><a href="${root}screenshots/${f}.png"><img src="${root}screenshots/${f}.png" alt="${esc(cap)}" loading="lazy"></a><figcaption>${esc(cap)}</figcaption></figure>`;

function renderShots(page) {
  const g = (list, cls) => `<div class="shots ${cls}">${list.map((s) => fig('', s)).join('')}</div>`;
  const body = `<article class="doc"><h1>Screenshots</h1><p>Echte Aufnahmen mit Demo-Daten: PWA (Chromium mit virtuellem Passkey) und native Apps (Simulator).</p>
<h2 id="pwa-desktop">PWA am Desktop</h2>${g(shots.desktop, 'wideshots')}
<h2 id="steuerzentrale">Steuerzentrale und Agenten (PWA)</h2><p>Mehr dazu unter <a href="steuerzentrale.html">Steuerzentrale und Agenten-Kanban</a>.</p>${g(shots.agents, 'wideshots')}
<h2 id="pwa-mobil">PWA auf dem Smartphone</h2>${g(shots.mobil, 'phone')}
<h2 id="iphone">iPhone (SwiftUI)</h2>${g(shots.ios, 'phone')}
<h2 id="ipad">iPad (SwiftUI)</h2>${g(shots.ipad, 'tablet')}</article>`;
  return layout(page, body);
}

function renderHome(page) {
  const cards = [
    ['Projekte beliebig tief', 'Unbegrenzt verschachtelte Projekte, jedes mit eigenen Kanban-Spalten. Sie gehören Personen oder Teams; Rechte werden vererbt und lassen sich je Projekt freigeben.'],
    ['Steuerzentrale für Agenten', 'Laufende Features, offene Fragen, Reviews und Build-Screenshots der Agenten an einem Ort, als Kanban oder Liste. Entscheiden statt im Chat nachfragen.'],
    ['Passkey zuerst', 'Anmeldung per WebAuthn, mehrere benannte Passkeys, einsehbare Sitzungen, getrennte Wiederherstellung.'],
    ['PWA und SwiftUI', 'Web-App (SvelteKit) und native Apps für iOS, iPadOS, macOS und watchOS teilen sich eine API und dieselben Fachregeln.'],
    ['MCP und OAuth', 'Externe Agenten sprechen über einen MCP-Endpunkt mit OAuth 2.1 (PKCE, Resource Indicators) mit der App.'],
    ['Lokale Mac-Runner', 'Ein Runner startet Claude Code im lokalen Projektordner. Aufträge und Checkpoints liegen in der App, nicht in einer Chat-Sitzung.'],
    ['Claude-Code-Plugin', 'Einmal installieren, dann „Richte das Projekt in Todolino ein“: Aufgaben werden importiert und das Board bleibt aktuell.'],
    ['Rückfragen an der Aufgabe', 'Fragen, Fortschritt, Abnahmekriterien, Screenshots und Anhänge hängen direkt an der Aufgabe.'],
    ['Teams und Freigaben', 'Lesen, kommentieren, bearbeiten, verwalten: Rechte pro Projekt, vererbt über den Projektbaum.'],
    ['Planung', 'Fälligkeit und geplante Bearbeitung getrennt, Erinnerungen, Wiederholungen, Meilensteine, Abhängigkeiten, Board.'],
    ['Sync und Offline', 'Änderungsfeed mit Cursor und idempotenten Client-Mutationen für Web und native Clients.'],
  ].map(([t, d]) => `<div class="card"><h3>${esc(t)}</h3><p>${esc(d)}</p></div>`).join('');
  const docs = [
    ['schnellstart.html', 'Schnellstart', 'Entwicklungsumgebung, Ports, Tests, CI'],
    ['installation.html', 'Installation ohne Quellcode', 'Branch deploy, setup.sh, update.sh'],
    ['steuerzentrale.html', 'Steuerzentrale', 'Agenten-Kanban, Fragen, Reviews, Builds'],
    ['projekt-onboarding.html', 'Projekt-Onboarding', 'Claude-Code-Plugin, Hooks, Aktualität'],
    ['runner.html', 'Runner', 'Claude Code auf dem eigenen Mac'],
    ['sync-aufbewahrung.html', 'Sync-Aufbewahrung', 'Retention, 410, Cleanup-Scheduler'],
    ['architektur.html', 'Architektur', 'Modularer Monolith, Swarm, Konsistenz'],
    ['betrieb.html', 'Betrieb und Swarm', 'Stack, Secrets, Updates, Prüfungen'],
    ['push-einrichtung.html', 'Push einrichten (APNs)', 'Schlüssel, Secret, Test, Fehlersuche'],
    ['adr/index.html', 'ADRs', 'Architekturentscheidungen mit Begründung'],
    ['api/index.html', 'API-Verträge', 'OpenAPI lesbar und mit Redoc'],
    ['apple.html', 'Apple und TestFlight', 'iOS, macOS, Passkey-Domain'],
    ['status.html', 'Status', 'Tatsächlicher Stand und Checkpoints'],
    ['agenten-und-mcp.html', 'Agenten und MCP', 'Aufträge, Runner, OAuth'],
    ['claude-code-einrichtung.html', 'Claude Code einrichten', 'Plugin oder globaler MCP-Server'],
  ].map(([s, t, d]) => `<a class="card link" href="${s}"><h3>${esc(t)}</h3><p>${esc(d)}</p></a>`).join('');
  const body = `<section class="hero"><div class="in">
<p class="eyebrow">In aktiver Entwicklung</p>
<h1>Projektplanung für Menschen und Agenten</h1>
<p class="lead">Intuitive Todo- und Projektplanung mit frei verschachtelten Projekten, Teams und Freigaben. Aufgaben, Rückfragen, Fortschritt und Screenshots bleiben an einem Ort, auch wenn ein KI-Agent daran arbeitet.</p>
<p class="cta"><a class="btn primary" href="schnellstart.html">Schnellstart</a> <a class="btn" href="screenshots.html">Screenshots</a> <a class="btn" href="${GH}" rel="noopener">GitHub</a></p>
</div><div class="heroimg"><a href="screenshots/projekte-aufgaben.png"><img src="screenshots/projekte-aufgaben.png" alt="Projektbaum mit frei verschachtelten Projekten und Aufgabenliste (Desktop)"></a></div></section>
<section class="sec"><h2>Funktionen im Überblick</h2><div class="grid">${cards}</div></section>
<section class="sec"><h2>Screenshots</h2><div class="shots wideshots">${[shots.agents[0], shots.desktop[2], shots.desktop[1], shots.agents[1], shots.desktop[10], shots.desktop[0]].map((s) => fig('', s)).join('')}</div>
<div class="shots phone small">${shots.mobil.slice(0, 4).map((s) => fig('', s)).join('')}</div>
<p><a href="screenshots.html">Alle Screenshots: PWA, iPhone, iPad</a></p></section>
<section class="sec"><h2>Architektur in Kürze</h2>
<pre>PWA / SwiftUI / MCP-Clients / Mac-Runner
              | HTTPS
      API-Replikate (Swift, Vapor)
  gemeinsame Fachlogik und Rechteprüfung
              |
   MariaDB (Dateien darin; S3 optional)</pre>
<p>Modularer Monolith in Swift (Vapor, Fluent), MariaDB, SvelteKit-PWA mit statischer Auslieferung. Deployment als Docker-Image, Betrieb im Swarm. Mehr unter <a href="architektur.html">Architektur</a>.</p></section>
<section class="sec"><h2>Dokumentation</h2><p>Alle Seiten entstehen beim Build aus <code>docs/</code> und <code>contracts/</code> des Repositorys.</p><div class="grid">${docs}</div></section>
<section class="sec"><h2>Status (31.10.2026)</h2><p>Backend (Identität, verschachtelte Projekte mit eigenen Spalten, Aufgaben, Teams und Freigaben, Anhänge, Kommentare, Planung, OAuth/MCP, Agentenaufträge, Steuerzentrale, Sync mit Aufbewahrung), PWA, Claude-Code-Plugin und Deploy-Branch sind vorhanden und getestet; die Apple-Apps und der Mac-Runner liegen in einem eigenen Repository. Noch nicht belegt: Playwright-Läufe und der MariaDB-Volllauf der jüngsten Änderungen (Docker-VM voll), Firefox und WebKit, das Plugin in einer echten Claude-Code-Sitzung und ein produktiver Mehrknotenbetrieb. Das Produkt ist noch nicht für den Produktivbetrieb freigegeben. Der genaue Stand steht unter <a href="status.html">Status</a>.</p></section>`;
  return layout(page, body, { sidebar: false, wide: true });
}

// ---------- build ----------
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
fs.copyFileSync(path.join(here, 'style.css'), path.join(out, 'style.css'));
fs.cpSync(path.join(here, 'screenshots'), path.join(out, 'screenshots'), { recursive: true });
for (const c of contracts) write(`api/${c.file}`, c.text);
write('.nojekyll', '');

const home = { slug: 'index.html', title: 'Start', group: 'Einstieg', kind: 'home', nav: false };
pages.unshift(home);
for (const p of pages) {
  const html = { md: renderMd, home: renderHome, 'adr-index': renderAdrIndex, 'api-index': renderApiIndex, contract: renderContract, redoc: renderRedoc, shots: renderShots }[p.kind](p);
  write(p.slug, html);
}
write('404.html', layout({ slug: '404.html', title: 'Nicht gefunden' }, '<article class="doc"><h1>Seite nicht gefunden</h1><p><a href="/todo/index.html">Zur Startseite</a></p></article>', { sidebar: false }));
console.log(`Built ${pages.length} pages, ${contracts.length} contracts -> ${path.relative(process.cwd(), out) || out}`);
