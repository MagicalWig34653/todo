// Renders the three example graphics (sample data, not real weather) to PNG with headless Chromium.
// Usage: WEB_DIR=<path to web/ with node_modules> node bilder-erzeugen.mjs
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const webDir = process.env.WEB_DIR ?? join(here, '../../../../web');
const { chromium } = createRequire(join(webDir, 'package.json'))('playwright');

const W = 800;
const H = 500;
let seed = 7;
const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
// Rough, hand-made outline of a country-like landmass (sample shape).
const land = 'M330,40 L420,30 L520,70 L560,140 L600,200 L590,290 L560,350 L520,420 L450,470 L380,480 L330,440 L270,420 L240,350 L250,280 L220,220 L250,150 L300,100 Z';
const frame = (bg, body) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="${bg}"/>${body}</svg>`;
const font = 'font-family="Inter Variable, Inter, sans-serif" font-size="22" font-weight="600"';

function wind() {
	let a = `<defs><clipPath id="c"><path d="${land}"/></clipPath></defs>`;
	a += `<path d="${land}" fill="#dbeafe" stroke="#1e3a8a" stroke-width="3"/><g clip-path="url(#c)">`;
	for (let y = 50; y < H; y += 34)
		for (let x = 200; x < 640; x += 34) {
			const ang = 200 + Math.sin(x / 90) * 40 + Math.cos(y / 70) * 35;
			const len = 8 + 10 * (0.5 + 0.5 * Math.sin(x / 60 + y / 80));
			const col = len > 15 ? '#be123c' : len > 11 ? '#c2410c' : '#1d4ed8';
			a += `<g transform="translate(${x} ${y}) rotate(${ang.toFixed(0)})" stroke="${col}" stroke-width="3" stroke-linecap="round" fill="none"><path d="M${-len},0 L${len},0 M${len - 6},-5 L${len},0 L${len - 6},5"/></g>`;
		}
	a += '</g>';
	return frame('#eff6ff', a + `<text x="24" y="470" ${font} fill="#1e3a8a">Wind in 10 m, km/h</text>`);
}
function radar() {
	let a = `<defs><clipPath id="c"><path d="${land}"/></clipPath><radialGradient id="g"><stop offset="0" stop-color="#dc2626"/><stop offset="0.35" stop-color="#f59e0b"/><stop offset="0.7" stop-color="#22c55e" stop-opacity=".8"/><stop offset="1" stop-color="#22c55e" stop-opacity="0"/></radialGradient></defs>`;
	a += `<path d="${land}" fill="#1f2937" stroke="#94a3b8" stroke-width="3"/><g clip-path="url(#c)">`;
	for (let i = 0; i < 16; i++) a += `<ellipse cx="${(240 + rnd() * 360).toFixed(0)}" cy="${(60 + rnd() * 400).toFixed(0)}" rx="${(25 + rnd() * 70).toFixed(0)}" ry="${(18 + rnd() * 45).toFixed(0)}" fill="url(#g)"/>`;
	a += '</g>';
	return frame('#0f172a', a + `<text x="24" y="470" ${font} fill="#e2e8f0">Niederschlag, 5-Minuten-Raster</text>`);
}
function temperatur() {
	let a = `<defs><clipPath id="c"><path d="${land}"/></clipPath><linearGradient id="t" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#60a5fa"/><stop offset="0.5" stop-color="#fde047"/><stop offset="1" stop-color="#f97316"/></linearGradient></defs>`;
	a += `<path d="${land}" fill="url(#t)" stroke="#7c2d12" stroke-width="3"/><g clip-path="url(#c)" fill="none" stroke="#7c2d12" stroke-opacity=".55" stroke-width="2">`;
	for (let y = 90; y < 470; y += 48) a += `<path d="M200,${y} C300,${y - 30} 420,${y + 30} 640,${y - 10}"/>`;
	a += '</g>';
	return frame('#fffbeb', a + `<text x="24" y="470" ${font} fill="#7c2d12">Temperatur, 2 m, Grad Celsius</text>`);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: W, height: H } });
for (const [name, svg] of [['windkarte', wind()], ['radarkarte', radar()], ['temperaturkarte', temperatur()]]) {
	writeFileSync(join(here, 'bilder', `${name}.svg`), svg);
	await page.setContent(`<body style="margin:0">${svg}</body>`);
	await page.screenshot({ path: join(here, 'bilder', `${name}.png`) });
}
await browser.close();
