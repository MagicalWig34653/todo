import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/ui-nav.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const inNav = () => page.evaluate(() => !!document.activeElement?.closest('#main-nav'));

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 390, height: 800 } })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Nav Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

test('mobile drawer: focus moves in, is trapped, Escape closes and focus returns', async () => {
	const opener = page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('button', { name: 'Menü' });
	await opener.focus();
	await page.keyboard.press('Enter');
	const nav = page.locator('#main-nav');
	await expect(nav).toHaveAttribute('role', 'dialog');
	await expect(nav).toHaveAttribute('aria-modal', 'true');
	await expect.poll(inNav).toBe(true);
	for (let i = 0; i < 40; i++) {
		await page.keyboard.press('Tab');
		expect(await inNav()).toBe(true);
	}
	await page.keyboard.press('Shift+Tab');
	expect(await inNav()).toBe(true);
	expect(await page.evaluate(() => !!document.querySelector('main')?.closest('[inert]'))).toBe(true);
	await page.keyboard.press('Escape');
	await expect(nav).toBeHidden();
	await expect(opener).toBeFocused();
});

test('error from a sharing action is visible inside the open dialog', async () => {
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Fehlerprojekt' } })).json();
	await page.goto(`/project/${project.id}`);
	await page.getByTestId('share-open').click();
	const dialog = page.getByTestId('share-dialog');
	await expect(dialog).toBeVisible();
	await dialog.getByLabel('Konto-ID der Person').fill('00000000-0000-4000-8000-000000000001');
	await dialog.getByRole('button', { name: 'Hinzufügen', exact: true }).click();
	const alert = dialog.getByRole('alert');
	await expect(alert).toBeVisible();
	const box = (await alert.boundingBox())!;
	const dbox = (await dialog.boundingBox())!;
	expect(box.y).toBeGreaterThanOrEqual(dbox.y);
	expect(box.y + box.height).toBeLessThanOrEqual(dbox.y + dbox.height + 1);
	// Only one banner exists (the page banner is suppressed while a dialog is open).
	await expect(page.getByTestId('notice')).toHaveCount(1);
});

test('reloading a project page shows a skeleton, never "nicht gefunden"', async () => {
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Ladeprojekt' } })).json();
	// The project list itself is delayed (the old glob `projects?*` matched nothing, the test only saw the skeleton by timing luck).
	await page.route(/\/v1\/projects(\?.*)?$/, async (route) => {
		await new Promise((r) => setTimeout(r, 1200));
		await route.continue();
	});
	await page.goto(`/project/${project.id}`);
	await expect(page.getByTestId('project-loading')).toBeVisible();
	await expect(page.getByTestId('not-found')).toHaveCount(0);
	await expect(page.getByTestId('project-loading')).toHaveCount(0);
	await expect(page.getByTestId('not-found')).toHaveCount(0);
	await page.unroute(/\/v1\/projects(\?.*)?$/);
});

test('"Mehr" can be closed on its own pages', async () => {
	await page.setViewportSize({ width: 1200, height: 800 });
	await page.goto('/agents');
	const more = page.getByRole('navigation', { name: 'Seitenleiste' }).getByRole('button', { name: 'Mehr' });
	await expect(more).toHaveAttribute('aria-expanded', 'true');
	await more.click();
	await expect(more).toHaveAttribute('aria-expanded', 'false');
});

test('overview tabs: arrow keys, Home and End move between sections', async () => {
	await page.goto('/overview');
	const tabs = page.getByRole('tab');
	await tabs.first().focus();
	await page.keyboard.press('ArrowRight');
	await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true');
	await expect(tabs.nth(1)).toBeFocused();
	await page.keyboard.press('End');
	await expect(tabs.nth(3)).toHaveAttribute('aria-selected', 'true');
	await page.keyboard.press('Home');
	await expect(tabs.first()).toHaveAttribute('aria-selected', 'true');
	await expect(page.getByRole('tabpanel')).toBeVisible();
});

test('board check control has at least a 32 px hit area', async () => {
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Trefferprojekt' } })).json();
	await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'Treffer' } });
	await page.goto(`/project/${project.id}/board`);
	const check = page.getByTestId('board-card-check').first();
	await expect(check).toBeVisible();
	const size = await check.evaluate((el) => {
		const s = getComputedStyle(el, '::after');
		return { w: parseFloat(s.width), h: parseFloat(s.height) };
	});
	expect(size.w).toBeGreaterThanOrEqual(32);
	expect(size.h).toBeGreaterThanOrEqual(32);
});
