import { expect, test, type Locator, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   E2E_BASE_URL=... npx playwright test e2e/menus-and-modes.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

test.describe.configure({ mode: 'serial' });
let page: Page;

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext()).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Menü Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

/** The open popover (role dialog without aria-modal) must lie completely inside the viewport. */
async function expectInViewport(panel: Locator, label: string) {
	await expect(panel, label).toBeVisible();
	const vp = page.viewportSize()!;
	const box = (await panel.boundingBox())!;
	expect(box.x, `${label}: left`).toBeGreaterThanOrEqual(0);
	expect(box.y, `${label}: top`).toBeGreaterThanOrEqual(0);
	expect(box.x + box.width, `${label}: right`).toBeLessThanOrEqual(vp.width + 0.5);
	expect(box.y + box.height, `${label}: bottom`).toBeLessThanOrEqual(vp.height + 0.5);
}
const popover = () => page.locator('div[role="dialog"]:not([aria-modal])').last();

async function openDrawerIfNeeded() {
	const menu = page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('button', { name: 'Menü' });
	const nav = page.getByRole('navigation', { name: 'Seitenleiste' });
	await expect(nav.or(menu)).toBeVisible();
	if (!(await nav.isVisible())) await menu.click();
	await expect(nav).toBeVisible();
	return nav;
}

test('setup: project with a task and a board', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.getByTestId('add-project').click();
	await page.getByLabel('Neues Projekt').fill('Menüprojekt');
	await page.getByRole('button', { name: 'Projekt anlegen' }).click();
	await page.getByTestId('project-item').filter({ hasText: 'Menüprojekt' }).getByRole('button', { name: 'Menüprojekt', exact: true }).click();
	await expect(page.getByTestId('task-heading')).toHaveText('Menüprojekt');
	await page.getByLabel('Neue Aufgabe, Enter zum Anlegen').fill('Eine Aufgabe');
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('task-item').filter({ hasText: 'Eine Aufgabe' })).toBeVisible();
});

const viewports = [
	{ name: '320x568', width: 320, height: 568 },
	{ name: '390x844', width: 390, height: 844 },
	{ name: 'landscape 740x360', width: 740, height: 360 },
	{ name: 'landscape 568x320', width: 568, height: 320 },
	// Large system font (rem scale 150 %/200 %) makes menus taller and wider than the viewport allows.
	{ name: '320x568 with 200% text', width: 320, height: 568, fontPx: 32 },
	{ name: 'landscape 740x360 with 150% text', width: 740, height: 360, fontPx: 24 }
] as { name: string; width: number; height: number; fontPx?: number }[];

for (const vp of viewports) {
	test(`menus stay inside the viewport at ${vp.name}`, async () => {
		await page.setViewportSize({ width: vp.width, height: vp.height });
		await page.goto('/');
		await expect(page.locator('main')).toBeVisible();
		if (vp.fontPx) await page.addStyleTag({ content: `html { font-size: ${vp.fontPx}px !important; }` });

		// Project page toolbar (top right): display menu and "more".
		let nav = await openDrawerIfNeeded();
		await nav.getByTestId('project-item').getByRole('button', { name: 'Menüprojekt', exact: true }).first().click();
		await expect(page.getByTestId('task-heading')).toHaveText('Menüprojekt');
		for (const id of ['display-menu', 'project-more']) {
			await page.getByTestId(id).click();
			await expectInViewport(popover(), `${id} @${vp.name}`);
			await page.keyboard.press('Escape');
			await expect(page.getByTestId(id)).toBeFocused();
			await expect(page.locator('div[role="dialog"]:not([aria-modal])')).toHaveCount(0);
		}

		// Sidebar: account menu, notifications, project menu.
		nav = await openDrawerIfNeeded();
		for (const id of ['account-menu', 'notifications']) {
			await nav.getByTestId(id).click();
			await expectInViewport(popover(), `${id} @${vp.name}`);
			await page.keyboard.press('Escape');
		}
		const item = nav.getByTestId('project-item').filter({ hasText: 'Menüprojekt' }).first();
		await item.hover();
		await item.getByRole('button', { name: 'Projektmenü: Menüprojekt' }).click();
		await expectInViewport(popover(), `project item menu @${vp.name}`);
		await page.keyboard.press('Escape');
	});
}

test('board card menu stays inside a small viewport', async () => {
	await page.setViewportSize({ width: 320, height: 568 });
	await page.goto('/');
	const n = await openDrawerIfNeeded();
	await n.getByTestId('project-item').getByRole('button', { name: 'Menüprojekt', exact: true }).first().click();
	await page.getByTestId('display-menu').click();
	await page.getByRole('dialog', { name: 'Anzeige' }).getByRole('button', { name: 'Board' }).click();
	await page.keyboard.press('Escape');
	const card = page.getByTestId('board-card').filter({ hasText: 'Eine Aufgabe' });
	await expect(card).toBeVisible();
	await card.getByRole('button', { name: /Aufgabenmenü/ }).first().click();
	await expectInViewport(popover(), 'board card menu');
	await page.keyboard.press('Escape');
});

test('mode switch: classic hides project-management UI, management shows it, choice persists', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	await page.getByTestId('project-item').getByRole('button', { name: 'Menüprojekt', exact: true }).first().click();
	await expect(page.getByTestId('task-heading')).toHaveText('Menüprojekt');

	// New project without agent relation defaults to classic.
	await expect(page.getByTestId('project-tabs')).toHaveCount(0);
	await page.getByTestId('project-more').click();
	await expect(page.getByTestId('milestones-open')).toHaveCount(0);
	await page.keyboard.press('Escape');

	await page.getByTestId('display-menu').click();
	await expect(page.getByTestId('mode-classic')).toHaveAttribute('aria-pressed', 'true');
	await expect(page.getByTestId('mode-hint')).toContainText('Reine Aufgabenliste');
	await page.getByTestId('mode-management').click();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('project-tabs')).toBeVisible();
	await page.getByTestId('project-tab-overview').click();
	await expect(page.getByTestId('command-center')).toBeVisible();
	await page.getByTestId('project-tab-tasks').click();

	// Persisted on the server (survives reload) ...
	await page.reload();
	await page.getByTestId('project-item').getByRole('button', { name: 'Menüprojekt', exact: true }).first().click();
	await expect(page.getByTestId('project-tabs')).toBeVisible();
	const all = await page.evaluate(async () => (await fetch('/v1/me/project-prefs')).json());
	const prefs = all.items.find((p: { mode: string }) => p.mode === 'management');
	expect(prefs).toMatchObject({ mode: 'management', modeSource: 'user' });

	// ... and back to classic.
	await page.getByTestId('display-menu').click();
	await page.getByTestId('mode-classic').click();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('project-tabs')).toHaveCount(0);
});

test('quick add: Q opens, chips appear live, Enter keeps the field open, Esc closes', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	await page.getByTestId('project-item').getByRole('button', { name: 'Menüprojekt', exact: true }).first().click();
	await expect(page.getByTestId('task-heading')).toHaveText('Menüprojekt');
	await page.keyboard.press('q');
	const input = page.getByTestId('quick-add').getByLabel('Titel', { exact: true });
	await expect(input).toBeFocused();
	await input.fill('Zahnarzt anrufen morgen um 14:30 p1 @dringend jeden Tag');
	const chips = page.getByTestId('qa-chip');
	await expect(chips.filter({ hasText: 'Hoch' })).toBeVisible();
	await expect(chips.filter({ hasText: 'täglich' })).toBeVisible();
	await expect(chips.filter({ hasText: '@dringend' })).toBeVisible();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('quick-add-added')).toContainText('Zahnarzt anrufen');
	await expect(input).toBeFocused();
	await expect(input).toHaveValue('');
	// Second entry as sub-task via Tab.
	await input.fill('Nummer heraussuchen');
	await page.keyboard.press('Tab');
	await expect(page.getByTestId('qa-subtask')).toBeChecked();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('quick-add-added')).toContainText('Nummer heraussuchen');
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('quick-add')).toHaveCount(0);
	// The project is shown as a board here (set by an earlier test): the card carries the parsed priority.
	const card = page.getByTestId('board-card').filter({ hasText: 'Zahnarzt anrufen' });
	await expect(card).toBeVisible();
	await expect(card).toContainText('14:30');
	await expect(card).toContainText('dringend');
	const id = await card.getAttribute('data-id');
	const planning = await page.evaluate(async (i) => (await fetch(`/v1/planning/tasks/${i}`)).json(), id);
	expect(planning).toMatchObject({ priority: 3, recurrence: { frequency: 'daily' } });
	await expect(page.getByTestId('board-card').filter({ hasText: 'Nummer heraussuchen' })).toBeVisible();
});
