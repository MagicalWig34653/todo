import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/freetext-review.spec.ts --project=chromium
// Free-text answers to questions with options, the chat-style review note field, and the attachment upload button.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
let ids = { project: '', optTask: '', reviewTask: '', fileTask: '', question: '' };
const PNG_1X1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const dialog = () => page.getByTestId('card-dialog');

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Freitext Tester');
	const project = await post<{ id: string }>('/v1/projects', { name: 'Freitextprojekt' });
	const mk = (title: string) => post<{ id: string }>('/v1/tasks', { projectID: project.id, title });
	const optTask = await mk('Optionsaufgabe');
	const reviewTask = await mk('Notizaufgabe');
	const fileTask = await mk('Dateiaufgabe');
	await post(`/v1/tasks/${optTask.id}/claim`, { agentName: 'Claude Code' });
	const q = await post<{ id: string }>(`/v1/tasks/${optTask.id}/questions`, { prompt: 'Welche Variante?', options: ['Variante A', 'Variante B'] });
	await post(`/v1/tasks/${reviewTask.id}/review`, { summary: 'Fertig zum Ansehen.', agentName: 'Claude Code' });
	ids = { project: project.id, optTask: optTask.id, reviewTask: reviewTask.id, fileTask: fileTask.id, question: q.id };
});
test.afterAll(async () => {
	await page?.context().close();
});

test('question with options accepts an own text answer; other text without freeText is still refused', async () => {
	const refused = await page.request.post(`/v1/questions/${ids.question}/answer`, { ...json, data: { answer: 'Variante C' } });
	expect(refused.status()).toBe(400);
	await page.goto(`/for-you?card=question:${ids.question}`);
	await expect(dialog()).toBeVisible();
	await expect(dialog().getByTestId('question-option')).toHaveCount(2);
	await expect(dialog().getByTestId('question-send')).toBeDisabled();
	await dialog().getByTestId('question-answer').fill('Weder noch, lieber Variante C mit Dunkelmodus');
	await dialog().getByTestId('question-send').click();
	await expect(dialog().getByTestId('question-answered')).toHaveText('Weder noch, lieber Variante C mit Dunkelmodus');
});

test('review: note field in chat style, send requests changes with the note, accept stays a separate button', async () => {
	await page.goto(`/for-you?card=review:${ids.reviewTask}`);
	await expect(dialog()).toBeVisible();
	const field = dialog().getByTestId('review').getByTestId('chat-field');
	await expect(field).toBeVisible();
	await expect(field.getByTestId('review-changes')).toBeVisible();
	await expect(dialog().getByTestId('review-accept')).toHaveText('Freigeben');
	await field.getByTestId('review-changes').click();
	await expect(dialog().getByRole('alert')).toBeVisible();
	await field.getByTestId('review-note').fill('Bitte Kontrast prüfen');
	await field.getByTestId('review-changes').click();
	await expect(dialog().getByTestId('card-review-result')).toContainText('Änderungen');
	const ctx = await (await page.request.get(`/v1/tasks/${ids.reviewTask}/context`)).json();
	expect(ctx.task.status).toBe('in_progress');
});

test('attachment: Hochladen without a file opens the picker, choosing a file uploads it', async () => {
	await page.goto(`/for-you?card=task:${ids.fileTask}`);
	await expect(dialog()).toBeVisible();
	const button = dialog().getByTestId('attachment-upload');
	await expect(button).toBeVisible();
	const chooser = page.waitForEvent('filechooser');
	await button.click();
	const fc = await chooser;
	await fc.setFiles({ name: 'shot.png', mimeType: 'image/png', buffer: PNG_1X1 });
	await expect(dialog().getByTestId('attachment').first()).toContainText('shot.png');
	const list = await (await page.request.get(`/v1/tasks/${ids.fileTask}/attachments`)).json();
	expect(list).toHaveLength(1);
});

// Light/dark check of the "Für dich" free-text question (no horizontal overflow); screenshots go to E2E_SHOT_DIR only when set (never into the repo).
for (const scheme of ['light', 'dark'] as const) {
	test(`for you: free-text question card renders without overflow in ${scheme} mode`, async ({ browserName }, testInfo) => {
		const task = await post<{ id: string }>('/v1/tasks', { projectID: ids.project, title: `Farbschema ${scheme}` });
		await post(`/v1/tasks/${task.id}/claim`, { agentName: 'Claude Code' });
		await post(`/v1/tasks/${task.id}/questions`, { prompt: `Welche Variante soll es sein (${scheme})?`, options: ['Variante A', 'Variante B'] });
		await page.emulateMedia({ colorScheme: scheme });
		await page.goto('/for-you');
		await page.getByText(`Welche Variante soll es sein (${scheme})?`).first().click();
		await expect(dialog()).toBeVisible();
		await expect(dialog().getByTestId('question-answer')).toBeVisible();
		await dialog().getByTestId('question-answer').fill('Weder noch, lieber eine dritte Variante');
		expect(await page.evaluate(() => matchMedia('(prefers-color-scheme: dark)').matches)).toBe(scheme === 'dark');
		expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
		const dir = process.env.E2E_SHOT_DIR;
		if (dir) await page.screenshot({ path: `${dir}/for-you-freetext-${testInfo.project.name}-${browserName}-${scheme}.png` });
		await page.emulateMedia({ colorScheme: null });
	});
}
