import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/for-you.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Feed Tester');
});
test.afterAll(async () => {
	await page?.context().close();
});

test('empty state, then needs-you card with options and a progress post; answering removes the card', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	await expect(page).toHaveURL(/\/for-you$/);
	await expect(page.getByTestId('view-heading')).toHaveText('Für dich');
	await expect(page.getByText('Alles ruhig')).toBeVisible();

	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Feedprojekt' } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'Feedaufgabe' } })).json();
	expect((await page.request.post(`/v1/tasks/${task.id}/progress-notes`, { ...json, data: { note: 'Halbzeit erreicht', percent: 50 } })).status()).toBe(201);
	expect((await page.request.post(`/v1/tasks/${task.id}/questions`, { ...json, data: { prompt: 'Mobil zuerst?', options: ['Ja', 'Nein'], blocking: true } })).status()).toBe(201);

	await page.goto('/for-you');
	const card = page.getByTestId('needs-card').filter({ hasText: 'Mobil zuerst?' });
	await expect(card).toBeVisible();
	await expect(page.getByTestId('post-card').filter({ hasText: 'Halbzeit erreicht' })).toBeVisible();
	await card.getByRole('button', { name: 'Ja', exact: true }).click();
	await expect(card).toHaveCount(0);
	await expect(page.getByTestId('post-card').filter({ hasText: 'Frage beantwortet' })).toBeVisible();

	// Tapping a card opens the large detail window; "Zur Aufgabe" leads to the task in its project.
	await page.getByTestId('post-card').filter({ hasText: 'Halbzeit erreicht' }).getByRole('button').first().click();
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	await expect(page).toHaveURL(/\/for-you\?card=task:/);
	await page.getByTestId('card-open-task').click();
	await expect(page).toHaveURL(/\/project\/.+\?task=/);
});

test('needs-you question with options also takes an own text answer (320 px, no horizontal overflow)', async () => {
	await page.setViewportSize({ width: 320, height: 700 });
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Freitextfeed' } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'Freitextaufgabe' } })).json();
	expect((await page.request.post(`/v1/tasks/${task.id}/questions`, { ...json, data: { prompt: 'Welche Farbe?', options: ['Rot', 'Blau'] } })).status()).toBe(201);
	await page.goto('/for-you');
	const card = page.getByTestId('needs-card').filter({ hasText: 'Welche Farbe?' });
	await expect(card).toBeVisible();
	await expect(card.getByTestId('question-option')).toHaveCount(2);
	await expect(card.getByTestId('question-send')).toBeDisabled();
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
	await card.getByTestId('question-answer').fill('Grün, bitte');
	await card.getByTestId('question-send').click();
	await expect(card).toHaveCount(0);
	await expect(page.getByTestId('post-card').filter({ hasText: 'Grün, bitte' })).toBeVisible();
});

test('mobile: Für dich is the first tab', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/');
	const tabs = page.getByRole('navigation', { name: 'Hauptnavigation' });
	await expect(tabs.getByRole('button').first()).toHaveText('Für dich');
	await expect(page.getByTestId('view-heading')).toHaveText('Für dich');
});
