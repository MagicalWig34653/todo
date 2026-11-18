// Renders entwurf.html to the PNGs next to it (headless Chromium).
// Usage: WEB_DIR=<path to web/ with node_modules> node rendern.mjs
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const webDir = process.env.WEB_DIR ?? join(here, '../../../../web');
const { chromium } = createRequire(join(webDir, 'package.json'))('playwright');
const url = (s, theme) => `${pathToFileURL(join(here, 'entwurf.html'))}?s=${s}${theme ? `&theme=${theme}` : ''}`;

const desktop = { width: 1280, height: 900 };
const mobile = { width: 390, height: 844 };
const shots = [
	{ file: '01-ueberblick-2-varianten-hell.png', s: 1, theme: 'light', viewport: desktop },
	{ file: '01-ueberblick-2-varianten-dunkel.png', s: 1, theme: 'dark', viewport: desktop },
	// Keyboard focus on the "Wählen" button of variant B (real Tab navigation, so :focus-visible applies).
	{ file: '02-kartendetail-3-varianten-fokus-hell.png', s: 2, theme: 'light', viewport: desktop, tabs: 2, fullPage: true },
	{ file: '03-mobil-varianten-untereinander-hell.png', s: 3, theme: 'light', viewport: mobile, fullPage: true },
	{ file: '04-nach-wahl-rueckgaengig-verlauf-hell.png', s: 4, theme: 'light', viewport: desktop, fullPage: true },
	{ file: '05-sammelfreigabe-hinweis-hell.png', s: 5, theme: 'light', viewport: desktop }
];

const browser = await chromium.launch();
for (const shot of shots) {
	const context = await browser.newContext({ viewport: shot.viewport, deviceScaleFactor: 1, colorScheme: shot.theme === 'dark' ? 'dark' : 'light' });
	const page = await context.newPage();
	await page.goto(url(shot.s, shot.theme));
	await page.evaluate(() => document.fonts.ready);
	for (let i = 0; i < (shot.tabs ?? 0); i++) await page.keyboard.press('Tab');
	await page.screenshot({ path: join(here, shot.file), fullPage: shot.fullPage ?? false });
	await context.close();
	console.log('ok', shot.file);
}
await browser.close();
