import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Needs a fresh backend database. Run on its own: npx playwright test e2e/system-status.spec.ts --project=chromium
// Set SCREENSHOT_DIR to keep a screenshot of the situation lights.
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const report = {
	zeit: '2026-11-12T10:18:18Z', claude_ampel: 'rot', claude_frei_fuer_brain: 0, claude_nutzbare_konten: [4, 7],
	codex: { verbraucht_pct: 5, erlaubt_bis_jetzt_pct: 19.2, ziel_pct: 75, freigabe: true },
	platte_frei_gb: 104.9, platte_ampel: 'gruen'
};

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Lage Tester');
});
test.afterAll(async () => {
	await page?.context().close();
});

test('situation lights appear in the overview, update live and show the age', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/overview');
	await expect(page.getByTestId('system-status-empty')).toBeVisible();

	expect((await page.request.put('/v1/system-status', { ...json, data: report })).status()).toBe(200);
	await expect(page.getByTestId('lage-claude')).toContainText('rot');
	await expect(page.getByTestId('lage-claude')).toContainText('4, 7 nutzbar');
	await expect(page.getByTestId('lage-codex')).toContainText('5 % von 19,2 % erlaubt');
	await expect(page.getByTestId('lage-disk')).toContainText('104,9 GB frei');
	await expect(page.getByTestId('lage-age')).toContainText('Stand');
	await expect(page.getByTestId('system-status-row')).toHaveAttribute('data-stale', 'false');
	if (process.env.SCREENSHOT_DIR) await page.screenshot({ path: `${process.env.SCREENSHOT_DIR}/lage-ampel.png` });

	expect((await page.request.put('/v1/system-status', { ...json, data: { ...report, claude_ampel: 'gruen', platte_ampel: 'gelb' } })).status()).toBe(200);
	await expect(page.getByTestId('lage-claude')).toContainText('grün');
});
