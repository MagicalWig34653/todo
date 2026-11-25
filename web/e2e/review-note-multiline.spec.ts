import { expect, test, type Locator, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Bug DA09D11A: a person types a multi-line list ("- " lines) on a card and it is not saved. The card has three places that
// look like a chat field: the card chat, the review chat and the note field of the pending review ("Änderungen anfordern").
// The bulk bar of the review list takes the same note. All of them must keep the line breaks. Needs a fresh backend database:
//   npx playwright test e2e/review-note-multiline.spec.ts --project=firefox   (also chromium and webkit)
// Pictures (light and dark) go to E2E_SHOT_DIR only when set.
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };
const TEXT = 'Regen\n- Deutschland: Radar vom Wetterdienst reicht\n- Ausland: vorerst keine Karte\n\nKartenwahl\n- erst die einfache Variante\n- Anbieter später prüfen';
let page: Page;
let projectID = '';

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
/** A task with a pending review, requested by someone else than the person would be in real life. */
async function reviewCard(title: string) {
	const task = await post<{ id: string }>('/v1/tasks', { projectID, title });
	const review = await post<{ id: string }>(`/v1/tasks/${task.id}/review`, { summary: 'Kartenwahl: bitte ansehen.', agentName: 'Claude Code' });
	return { taskID: task.id, reviewID: review.id };
}
const dialog = () => page.getByTestId('card-dialog');
const chat = (thread: 'task' | 'review') => dialog().locator(`[data-testid="card-conversation"][data-thread="${thread}"]`);
/** Clicks `send` and returns the POST to `path`: status and body. */
async function sendAndRead(path: string, send: () => Promise<unknown>) {
	const [response] = await Promise.all([
		page.waitForResponse((r) => r.url().endsWith(path) && r.request().method() === 'POST', { timeout: 15_000 }),
		send()
	]);
	return { status: response.status(), body: await response.text() };
}
const alerts = async () => (await page.getByRole('alert').allInnerTexts()).join(' | ');
/** On a refused request: what the person reads, taken once the notice is there. */
async function shown(status: number) {
	if (status < 300) return '';
	await expect(page.getByRole('alert').first()).toBeVisible();
	await pictures(page.getByRole('alert').first(), `fehler-${test.info().title.replace(/\W+/g, '-')}`);
	return alerts();
}
async function pictures(target: Locator, name: string) {
	const dir = process.env.E2E_SHOT_DIR;
	if (!dir) return;
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await target.scrollIntoViewIfNeeded({ timeout: 2000 }).catch(() => undefined); // a notice may be re-rendered
		await page.waitForTimeout(350);
		await page.screenshot({ path: `${dir}/${name}-${test.info().project.name}-${scheme === 'light' ? 'hell' : 'dunkel'}.png` });
	}
	await page.emulateMedia({ colorScheme: null });
}

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Notiz Tester');
	await page.setViewportSize({ width: 1280, height: 900 });
	projectID = (await post<{ id: string }>('/v1/projects', { name: 'Notizprojekt' })).id;
});
test.afterAll(async () => {
	await page?.context().close();
});

for (const thread of ['task', 'review'] as const) {
	test(`${thread} chat: a person sends a multi-line list and it is saved unchanged`, async () => {
		const card = await reviewCard(`Chat ${thread}`);
		await page.goto(`/for-you?card=review:${card.taskID}`);
		await expect(dialog()).toBeVisible();
		const field = chat(thread).getByPlaceholder('Nachricht schreiben');
		await field.fill(TEXT);
		const res = await sendAndRead(`/tasks/${card.taskID}/comments`, () => chat(thread).getByTestId('comment-send').click());
		expect(res.status, res.body).toBe(201);
		await expect(chat(thread).getByTestId('comment')).toContainText('- Anbieter später prüfen');
		await expect(field).toHaveValue('');
		expect(await alerts()).toBe('');
		const saved = (await (await page.request.get(`/v1/tasks/${card.taskID}/comments`)).json()) as { body: string; authorKind: string; reviewID?: string }[];
		expect(saved.map((c) => [c.body, c.authorKind, !!c.reviewID])).toEqual([[TEXT, 'person', thread === 'review']]);
		await pictures(chat(thread).getByTestId('comment'), `${thread}-chat`);
	});
}

test('review note field: requesting changes with a multi-line list saves the note', async () => {
	const card = await reviewCard('Review-Notiz');
	await page.goto(`/for-you?card=review:${card.taskID}`);
	await expect(dialog()).toBeVisible();
	const field = dialog().getByTestId('review-note');
	// Typed like a person: Shift+Enter for the line breaks.
	for (const [i, line] of TEXT.split('\n').entries()) {
		if (i > 0) await field.press('Shift+Enter');
		if (line) await field.pressSequentially(line);
	}
	await expect(field).toHaveValue(TEXT);
	const res = await sendAndRead(`/tasks/${card.taskID}/review/decision`, () => dialog().getByTestId('review-changes').click());
	expect(res.status, `${res.body} | shown: ${await shown(res.status)}`).toBe(200);
	const result = dialog().getByTestId('card-review-result');
	await expect(result.getByTestId('review-note-shown')).toHaveText(TEXT, { useInnerText: true });
	await page.reload();
	await expect(result.getByTestId('review-note-shown')).toHaveText(TEXT, { useInnerText: true });
	await pictures(result.getByTestId('review-note-shown'), 'review-notiz');
});

test('review note field: accepting with a multi-line note saves the note', async () => {
	const card = await reviewCard('Freigabe mit Notiz');
	await page.goto(`/for-you?card=review:${card.taskID}`);
	await dialog().getByTestId('review-note').fill(TEXT);
	const res = await sendAndRead(`/tasks/${card.taskID}/review/decision`, () => dialog().getByTestId('review-accept').click());
	expect(res.status, `${res.body} | shown: ${await shown(res.status)}`).toBe(200);
	await expect(dialog().getByTestId('review-note-shown')).toHaveText(TEXT, { useInnerText: true });
});

test('review note field: a refused note stays in the field and the reason stays readable', async () => {
	const card = await reviewCard('Abgelehnte Notiz');
	await page.goto(`/for-you?card=review:${card.taskID}`);
	// Too long for the server (4000 characters): the field's own maxlength normally stops this, so it is lifted here.
	const bad = `Zeile\n- ${'x'.repeat(4100)}`;
	const field = dialog().getByTestId('review-note');
	await field.evaluate((el) => el.removeAttribute('maxlength'));
	await field.fill(bad);
	const res = await sendAndRead(`/tasks/${card.taskID}/review/decision`, () => dialog().getByTestId('review-changes').click());
	expect(res.status, res.body).toBe(400);
	// The card reloads its sections after a failed decision; the message must survive that.
	await page.waitForTimeout(1500);
	const message = dialog().getByRole('alert').filter({ hasText: '4 000 Zeichen' });
	await expect(message, `alerts: "${await alerts()}"`).toBeVisible();
	await expect(field).toHaveValue(bad);
	await pictures(message, 'review-notiz-abgelehnt');
	// The message belongs to this card: it does not follow to the next card the person opens.
	await dialog().getByTestId('card-close').click();
	await expect(dialog()).toHaveCount(0);
	await page.getByRole('main').getByText('Chat review').first().click();
	await expect(dialog().getByTestId('card-breadcrumb')).toContainText('Chat review');
	await expect(dialog().getByTestId('chat-history').first()).toBeVisible();
	await expect(dialog().getByRole('alert').filter({ hasText: '4 000 Zeichen' })).toHaveCount(0);
});

test('bulk review bar: one multi-line note for the selected reviews is saved', async () => {
	const card = await reviewCard('Sammelnotiz');
	// The overview lists only projects in the management view.
	await page.goto(`/project/${projectID}`);
	if (!(await page.getByTestId('project-tabs').isVisible())) {
		await page.getByTestId('display-menu').click();
		await page.getByTestId('mode-management').click();
		await page.keyboard.press('Escape');
	}
	await expect(page.getByTestId('project-tabs')).toBeVisible();
	await page.goto('/overview');
	await page.getByTestId('cc-section-reviews').click();
	const row = page.getByTestId('cc-reviews').getByTestId('review-row').filter({ hasText: 'Sammelnotiz' });
	await row.getByTestId('review-select').check();
	await page.getByTestId('review-bulk-note').fill(TEXT);
	await page.getByTestId('review-bulk-changes').click();
	const res = await sendAndRead('/reviews/decisions', () => page.getByTestId('review-bulk-confirm-go').click());
	expect(res.status, `${res.body} | shown: ${await shown(res.status)}`).toBe(200);
	expect((JSON.parse(res.body) as { summary: { ok: number } }).summary.ok, res.body).toBe(1);
	const all = (await (await page.request.get('/v1/reviews?state=all&limit=200')).json()) as { id: string; decisionNote?: string }[];
	expect(all.find((r) => r.id === card.reviewID)?.decisionNote).toBe(TEXT);
});
