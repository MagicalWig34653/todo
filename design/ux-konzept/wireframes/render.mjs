// Renders wireframes/png/<view>-<desktop|handy>-<hell|dunkel>.png and reports layout and contrast problems.
// Run from web/ (uses its Playwright): node ../design/ux-konzept/wireframes/render.mjs
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const { chromium } = createRequire(join(process.cwd(), 'x.js'))('@playwright/test');
const dir = fileURLToPath(new URL('.', import.meta.url));
mkdirSync(join(dir, 'png'), { recursive: true });
const VIEWS = ['fuer-dich', 'aufgaben', 'projekte', 'projekt', 'karte', 'zeitleiste', 'zeitleiste-detail', 'einstellungen'];
const browser = await chromium.launch();
let problems = 0;
for (const [device, viewport] of [['desktop', { width: 1280, height: 800 }], ['handy', { width: 390, height: 844 }]]) {
	const page = await browser.newPage({ viewport, deviceScaleFactor: device === 'handy' ? 2 : 1 });
	page.on('pageerror', (e) => { problems++; console.log('error', e.message); });
	for (const view of VIEWS)
		for (const theme of ['hell', 'dunkel']) {
			await page.goto(`${pathToFileURL(join(dir, 'index.html'))}?view=${view}&theme=${theme}`);
			await page.screenshot({ path: join(dir, 'png', `${view}-${device}-${theme}.png`) });
			const found = await page.evaluate(({ view, device }) => {
				const out = [];
				const rgb = (s) => s.match(/[\d.]+/g).map(Number);
				const lum = ([r, g, b]) => [r, g, b].map((c) => ((c /= 255) <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)).reduce((a, c, i) => a + c * [0.2126, 0.7152, 0.0722][i], 0);
				const bgOf = (e) => { for (; e; e = e.parentElement) { const c = rgb(getComputedStyle(e).backgroundColor); if (c.length < 4 || c[3] > 0) return c; } return rgb(getComputedStyle(document.body).backgroundColor); };
				for (const e of document.querySelectorAll('#app *')) {
					const own = [...e.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim()).map((n) => n.textContent.trim()).join(' ');
					// A bottom sheet covers the tab bar on purpose.
					if (!own || !e.getClientRects().length || e.closest('.dim') || (e.closest('.tabs') && view === 'zeitleiste-detail' && device === 'handy')) continue;
					const r = e.getBoundingClientRect();
					if (!r.width) continue;
					const s = getComputedStyle(e);
					const a = lum(rgb(s.color)), b = lum(bgOf(e)), ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
					if (ratio < 4.5) out.push(`contrast ${ratio.toFixed(2)} "${own}"`);
					// Phone board: the second lane is intentionally cut (horizontal swipe).
					if (device === 'handy' && view === 'projekt' && e.closest('.board')) continue;
					if (r.right > innerWidth + 1 || r.bottom > innerHeight + 1) out.push(`offscreen "${own}" ${Math.round(r.right)}/${Math.round(r.bottom)}`);
					if (e.scrollWidth > e.clientWidth + 1 && s.display !== 'inline') out.push(`clipped "${own}"`);
					for (let p = e.parentElement; p && p.id !== 'app'; p = p.parentElement) {
						if (getComputedStyle(p).overflow !== 'hidden') continue;
						const q = p.getBoundingClientRect();
						if (r.right > q.right + 1 || r.bottom > q.bottom + 1) { out.push(`cut by parent "${own}"`); break; }
					}
					// Covered by something that is not an ancestor or child (the sheet over the dimmed list is excluded above).
					const hit = document.elementFromPoint(r.left + Math.min(r.width - 1, 4), r.top + r.height / 2);
					if (hit && hit !== e && !e.contains(hit) && !hit.contains(e) && !hit.closest('.today') && r.bottom <= innerHeight) out.push(`covered "${own}" by ${hit.className || hit.tagName}`);
				}
				return out;
			}, { view, device });
			if (found.length) { problems += found.length; console.log(`${view} ${device} ${theme}:\n  ${found.slice(0, 8).join('\n  ')}`); }
		}
	await page.close();
}
await browser.close();
console.log(`problems: ${problems}`);
process.exitCode = problems ? 1 : 0;
