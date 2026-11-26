// Before/after pictures of UX step 1 "Lesbarkeit" (card 8B820AA8). Not part of the test suite.
// Run: copy to web/e2e/zz-schritt1-bilder.spec.ts, start a throwaway backend (fresh SQLite, BOOTSTRAP_TOKEN=dev-bootstrap-only,
// RP_ORIGIN=http://localhost:$E2E_PORT) and the dev server, then (from web/)
//   PHASE=vorher|nachher E2E_PORT=25391 BACKEND_URL=http://127.0.0.1:28391 npx playwright test zz-schritt1-bilder --project=chromium
import { test } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { signedInPage } from './support/session';
import { seedNow } from './support/nowSeed';

const OUT = `../design/ux-konzept/schritt-1/${process.env.PHASE ?? 'nachher'}`;
const SIZES = { desktop: { width: 1280, height: 800 }, handy: { width: 390, height: 844 } } as const;

test('Schritt 1 Bilder', async ({ browser, playwright }) => {
	test.setTimeout(600_000);
	mkdirSync(OUT, { recursive: true });
	const page = await signedInPage(browser, 'Demo Person');
	const ids = await seedNow(page, await playwright.request.newContext());
	const p = ids.projects.todolino;
	await page.request.post('/v1/tasks/' + ids.tasks.question + '/progress-notes', { headers: { 'Content-Type': 'application/json' }, data: { note: '## Zwischenstand\n\n- **Tests** grün\n- `npm run build` ok', percent: 40 } });
	const views: [string, string][] = [
		['fuer-dich', '/for-you'],
		['karte', `/for-you?card=task:${ids.tasks.question}`],
		['vollmacht', '/settings/brain-mandate'],
		['projekt-graph', `/project/${p}/graph`],
		['kalender', '/calendar'],
		['projekt-liste', `/project/${p}/list`]
	];
	for (const [device, viewport] of Object.entries(SIZES)) {
		await page.setViewportSize(viewport);
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			for (const [name, path] of views) {
				await page.goto(path);
				await page.waitForTimeout(1800);
				if (name === 'projekt-liste' && device === 'handy') await page.evaluate(() => window.scrollTo(0, 250));
				await page.screenshot({ path: `${OUT}/${name}-${device}-${scheme === 'light' ? 'hell' : 'dunkel'}.jpg`, type: 'jpeg', quality: 60 });
			}
		}
	}
});
