import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/sidebar-rename.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Rename Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

async function nested(depth: number) {
	let parentID: string | undefined;
	let last: { id: string; name: string } | undefined;
	for (let i = 0; i <= depth; i++) {
		const r = await page.request.post('/v1/projects', { ...json, data: { name: `Ebene ${i}`, parentID } });
		last = await r.json();
		parentID = last!.id;
	}
	return last!;
}

for (const viewport of [{ width: 1280, height: 800 }, { width: 320, height: 700 }]) {
	test(`rename form fills the row and does not overflow (${viewport.width}px, deep tree)`, async () => {
		await page.setViewportSize(viewport);
		const leaf = await nested(4);
		await page.goto(`/project/${leaf.id}`);
		if (viewport.width < 700) await page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('button', { name: 'Menü' }).click();
		const nav = page.locator('#main-nav');
		const row = nav.getByTestId('project-item').filter({ hasText: leaf.name }).last();
		await row.hover();
		await row.getByRole('button', { name: /Projektmenü/ }).first().click();
		await page.getByRole('button', { name: 'Umbenennen', exact: true }).click();
		const form = nav.getByTestId('project-name-form');
		await expect(form).toBeVisible();
		const input = form.getByRole('textbox');
		await expect(input).toBeFocused();
		const navBox = (await nav.boundingBox())!;
		const formBox = (await form.boundingBox())!;
		const inputBox = (await input.boundingBox())!;
		// The field uses the whole form width (it used to share the line with two buttons) and is wide enough to read a name.
		expect(inputBox.width).toBeGreaterThanOrEqual(formBox.width - 2);
		expect(inputBox.width).toBeGreaterThanOrEqual(150);
		expect(formBox.x + formBox.width).toBeLessThanOrEqual(navBox.x + navBox.width + 1);
		expect(await nav.evaluate((el) => el.scrollWidth <= el.clientWidth + 1)).toBe(true);
		expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1)).toBe(true);
	});
}

test('Enter saves, Escape discards, an empty name is rejected', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	const project = (await (await page.request.post('/v1/projects', { ...json, data: { name: 'Altname' } })).json()) as { id: string };
	await page.goto(`/project/${project.id}`);
	const nav = page.locator('#main-nav');
	const open = async (name: string) => {
		const row = nav.getByTestId('project-item').filter({ hasText: name }).last();
		await row.hover();
		await row.getByRole('button', { name: /Projektmenü/ }).first().click();
		await page.getByRole('button', { name: 'Umbenennen', exact: true }).click();
		return nav.getByTestId('project-name-form').getByRole('textbox');
	};
	let input = await open('Altname');
	await input.fill('Neuer Name');
	await page.keyboard.press('Escape');
	await expect(nav.getByTestId('project-name-form')).toHaveCount(0);
	await expect(nav.getByText('Altname')).toBeVisible();
	input = await open('Altname');
	await input.fill('   ');
	await page.keyboard.press('Enter');
	await expect(nav.getByTestId('project-name-form')).toBeVisible();
	await input.fill('Neuer Name');
	await page.keyboard.press('Enter');
	await expect(nav.getByTestId('project-name-form')).toHaveCount(0);
	await expect(nav.getByText('Neuer Name')).toBeVisible();
});
