import { expect, test, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';

// Short ids (first 8 characters of the uuid): visible in card detail and on board cards, click copies the full id, search by short id.
// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/short-id.spec.ts --project=chromium
// Screenshots go to $SHORT_ID_SHOTS (default docs/screenshots/kurz-id).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.SHORT_ID_SHOTS ?? '../docs/screenshots/kurz-id';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const ids = { project: '', task: '', questionTask: '', question: '', reviewTask: '', review: '' };
const short = (id: string) => id.slice(0, 8).toUpperCase();

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const dialog = () => page.getByTestId('card-dialog');

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	mkdirSync(SHOTS, { recursive: true });
	const context = await browser.newContext({ viewport: { width: 1280, height: 860 }, locale: 'de-DE', colorScheme: 'light' });
	await context.grantPermissions(['clipboard-read', 'clipboard-write']);
	page = await context.newPage();
	const cdp = await context.newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Kurz-ID Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();

	const project = await post<{ id: string }>('/v1/projects', { name: 'ID-Projekt' });
	const mk = (title: string) => post<{ id: string }>('/v1/tasks', { projectID: project.id, title });
	const task = await mk('Aufgabe mit ID');
	const questionTask = await mk('Aufgabe mit Frage');
	const reviewTask = await mk('Aufgabe im Review');
	const question = await post<{ id: string }>(`/v1/tasks/${questionTask.id}/questions`, { prompt: 'Welche Variante?', options: ['A', 'B'], agentName: 'Claude Code' });
	const review = await post<{ id: string }>(`/v1/tasks/${reviewTask.id}/review`, { summary: 'Fertig, bitte ansehen.', agentName: 'Claude Code' });
	Object.assign(ids, { project: project.id, task: task.id, questionTask: questionTask.id, question: question.id, reviewTask: reviewTask.id, review: review.id });
});

test('card detail shows the short id of the card', async () => {
	await page.goto(`/inbox?card=task:${ids.task}`);
	await expect(dialog()).toBeVisible();
	const chip = dialog().getByTestId('id-card');
	await expect(chip).toContainText(short(ids.task));
	await expect(chip).toHaveAttribute('title', ids.task);
	await expect(chip).toHaveAttribute('aria-label', `ID ${short(ids.task)} kopieren (volle ID), Karte`);
	await page.screenshot({ path: `${SHOTS}/detail-hell-desktop.png` });
});

test('clicking the chip copies the full id, confirms politely and does not shift the layout', async () => {
	const chip = dialog().getByTestId('id-card');
	const before = await chip.boundingBox();
	await chip.click();
	await expect(dialog().getByTestId('id-card-status')).toHaveText('Kopiert');
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(ids.task);
	const during = await chip.boundingBox();
	expect(during).toEqual(before);
	await expect(dialog().getByTestId('id-card-status')).toHaveText('');
});

test('keyboard: Enter and Space on the chip copy as well', async () => {
	await page.evaluate(() => navigator.clipboard.writeText('x'));
	const chip = dialog().getByTestId('id-card');
	await chip.focus();
	await page.keyboard.press('Enter');
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(ids.task);
	await page.evaluate(() => navigator.clipboard.writeText('y'));
	await page.keyboard.press('Space');
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(ids.task);
});

test('question and review cards label the id of their own entry next to the card id', async () => {
	await page.goto(`/for-you?card=question:${ids.question}`);
	await expect(dialog().getByTestId('id-question')).toContainText(short(ids.question));
	await expect(dialog().getByTestId('id-card')).toContainText(short(ids.questionTask));
	await expect(dialog().getByTestId('card-ids')).toContainText('Frage');
	await page.screenshot({ path: `${SHOTS}/detail-frage-hell-desktop.png` });
	await dialog().getByTestId('id-question').click();
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(ids.question);

	await page.goto(`/for-you?card=review:${ids.reviewTask}`);
	await expect(dialog().getByTestId('id-review')).toContainText(short(ids.review));
	await expect(dialog().getByTestId('card-ids')).toContainText('Review');
	await dialog().getByTestId('id-review').click();
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(ids.review);
});

test('board card shows a discreet id; copying does not open the card', async () => {
	await page.goto(`/project/${ids.project}/board`);
	const card = page.getByTestId('board-card').filter({ hasText: 'Aufgabe mit ID' });
	await expect(card).toBeVisible();
	const chip = card.getByTestId('board-card-id');
	await expect(chip).toContainText(short(ids.task));
	await page.screenshot({ path: `${SHOTS}/board-hell-desktop.png` });
	await chip.click();
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(ids.task);
	await expect(dialog()).toHaveCount(0);
	await expect(page).not.toHaveURL(/card=/);
	// Reachable by keyboard and does not open the card on Enter either.
	await chip.focus();
	await expect(chip).toBeFocused();
	await page.keyboard.press('Enter');
	await expect(dialog()).toHaveCount(0);
});

test('search finds entries by short id (any case, with #), questions and reviews included', async () => {
	await page.goto('/search');
	const input = page.getByPlaceholder('Suchen in Titeln, Beschreibungen und Projekten');
	await input.fill(short(ids.task).toLowerCase());
	await input.press('Enter');
	await expect(page.getByTestId('search-id-hit')).toHaveCount(1);
	await expect(page.getByTestId('search-id-hit')).toContainText('Aufgabe mit ID');
	await page.screenshot({ path: `${SHOTS}/suche-hell-desktop.png` });
	await page.getByTestId('search-id-hit').getByRole('button', { name: 'Aufgabe mit ID' }).click();
	await expect(dialog()).toBeVisible();
	await page.keyboard.press('Escape');

	await input.fill(`#${short(ids.question)}`);
	await input.press('Enter');
	await expect(page.getByTestId('search-id-hit')).toHaveCount(1);
	await expect(page.getByTestId('search-id-hit')).toContainText('Welche Variante?');

	await input.fill(short(ids.review));
	await input.press('Enter');
	await expect(page.getByTestId('search-id-hit')).toContainText('Fertig, bitte ansehen.');
	await page.getByTestId('search-id-hit').getByRole('button', { name: 'Fertig, bitte ansehen.' }).click();
	await expect(dialog().getByTestId('id-review')).toContainText(short(ids.review));
	await page.keyboard.press('Escape');

	await input.fill('DEADBEEF');
	await input.press('Enter');
	await expect(page.getByTestId('search-id-hit')).toHaveCount(0);
});

test('mobile screenshots (light)', async ({ browser }) => {
	const context = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'de-DE', colorScheme: 'light' });
	// Reuse the signed-in session cookies of the desktop context.
	await context.addCookies(await page.context().cookies());
	const m = await context.newPage();
	await m.goto(`/inbox?card=task:${ids.task}`);
	await expect(m.getByTestId('card-dialog').getByTestId('id-card')).toBeVisible();
	await m.screenshot({ path: `${SHOTS}/detail-hell-mobil.png` });
	await m.goto(`/project/${ids.project}/board`);
	await expect(m.getByTestId('board-card').first()).toBeVisible();
	await m.screenshot({ path: `${SHOTS}/board-hell-mobil.png` });
	await context.close();
});
