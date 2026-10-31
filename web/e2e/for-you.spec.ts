import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/for-you.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

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
	await page.getByLabel('Anzeigename').fill('Feed Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

test('empty state, then needs-you card with options and a progress post; answering removes the card', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	await expect(page).toHaveURL(/\/fuer-dich$/);
	await expect(page.getByTestId('view-heading')).toHaveText('Für dich');
	await expect(page.getByText('Alles ruhig')).toBeVisible();

	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Feedprojekt' } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'Feedaufgabe' } })).json();
	expect((await page.request.post(`/v1/tasks/${task.id}/progress-notes`, { ...json, data: { note: 'Halbzeit erreicht', percent: 50 } })).status()).toBe(201);
	expect((await page.request.post(`/v1/tasks/${task.id}/questions`, { ...json, data: { prompt: 'Mobil zuerst?', options: ['Ja', 'Nein'], blocking: true } })).status()).toBe(201);

	await page.goto('/fuer-dich');
	const card = page.getByTestId('needs-card').filter({ hasText: 'Mobil zuerst?' });
	await expect(card).toBeVisible();
	await expect(page.getByTestId('post-card').filter({ hasText: 'Halbzeit erreicht' })).toBeVisible();
	await card.getByRole('button', { name: 'Ja', exact: true }).click();
	await expect(card).toHaveCount(0);
	await expect(page.getByTestId('post-card').filter({ hasText: 'Frage beantwortet' })).toBeVisible();

	// Tapping a card opens the task in its project.
	await page.getByTestId('post-card').filter({ hasText: 'Halbzeit erreicht' }).getByRole('button', { name: 'Aufgabe öffnen' }).click();
	await expect(page).toHaveURL(/\/projekt\/.+\?task=/);
});

test('mobile: Für dich is the first tab', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/');
	const tabs = page.getByRole('navigation', { name: 'Hauptnavigation' });
	await expect(tabs.getByRole('button').first()).toHaveText('Für dich');
	await expect(page.getByTestId('view-heading')).toHaveText('Für dich');
});
