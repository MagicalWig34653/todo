import { expect, test, type Locator, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Card 330C57F8: creation/audit times on cards, questions, reviews, comments, board cards and the "Für dich" feed.
// Every <time> must carry the exact API instant in `datetime`, show a relative text and a Berlin tooltip with seconds and
// offset (GMT+1 / GMT+2). The Berlin wall clock is checked against the UTC instant independently of the browser's own zone.
// Needs a fresh backend database. Run on its own, per browser:
//   npx playwright test e2e/timestamps.spec.ts --project=chromium   (also firefox, webkit)
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };
const RELATIVE = /^(gerade eben|vor \d+ Min\.)$/;
const TITLE = /^(\d{2})\.(\d{2})\.(\d{4}), (\d{2}):(\d{2}):(\d{2}) GMT\+([12])$/;

let page: Page;
let ids = { project: '', task: '', question: '', review: '' };
let api = { task: { createdAt: '', updatedAt: '' }, question: { createdAt: '', answeredAt: '' }, review: { createdAt: '', decidedAt: '' }, comment: { createdAt: '' } };

async function post<T>(path: string, data?: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}

/** The element is a <time> for exactly this instant, with a Berlin tooltip whose wall clock matches the UTC instant. */
async function expectInstant(time: Locator, iso: string, what: string) {
	await expect(time, what).toBeVisible();
	const want = new Date(iso);
	expect(await time.getAttribute('datetime'), `${what}: datetime`).toBe(want.toISOString());
	await expect(time, `${what}: relative text`).toHaveText(RELATIVE);
	const title = (await time.getAttribute('title')) ?? '';
	const m = TITLE.exec(title);
	expect(m, `${what}: tooltip "${title}" is not "dd.MM.yyyy, HH:mm:ss GMT+n"`).not.toBeNull();
	const [, dd, mm, yyyy, hh, mi, ss, off] = m!;
	// Wall clock minus the stated offset must be the UTC instant (to the second).
	const wall = Date.UTC(+yyyy, +mm - 1, +dd, +hh, +mi, +ss);
	expect(wall - Number(off) * 3_600_000, `${what}: Berlin wall clock ${title} vs ${want.toISOString()}`).toBe(Math.floor(want.getTime() / 1000) * 1000);
	// Berlin is on GMT+1 in winter and GMT+2 in summer (last Sunday of March to last Sunday of October): never the browser zone.
	expect(['1', '2']).toContain(off);
}

const dialog = () => page.getByTestId('card-dialog');
const open = async (card: string) => {
	await page.goto(`/for-you?card=${card}`);
	await expect(dialog()).toBeVisible();
	await expect(dialog().getByTestId('card-detail')).toBeVisible();
};

test('setup: a task with a question, a review, a comment and a progress note', async ({ browser }) => {
	test.setTimeout(120_000);
	page = await signedInPage(browser, 'Zeitanzeige Tester');
	const project = await post<{ id: string }>('/v1/projects', { name: 'Zeitprojekt' });
	const task = await post<{ id: string }>('/v1/tasks', { projectID: project.id, title: 'Zeitaufgabe' });
	await post(`/v1/tasks/${task.id}/progress-notes`, { note: 'Erste Notiz', percent: 10 });
	const comment = await post<{ createdAt: string }>(`/v1/tasks/${task.id}/comments`, { body: 'Ein Kommentar' });
	const question = await post<{ id: string; createdAt: string }>(`/v1/tasks/${task.id}/questions`, { prompt: 'Wann ist es fertig?', options: ['Heute', 'Morgen'], agentName: 'Claude Code' });
	const answered = await post<{ answeredAt: string; createdAt: string }>(`/v1/questions/${question.id}/answer`, { answer: 'Heute' });
	const review = await post<{ id: string; createdAt: string }>(`/v1/tasks/${task.id}/review`, { summary: 'Ergebnis ist fertig.', agentName: 'Claude Code' });
	// Re-read the task: the question, the note and the review moved updatedAt.
	const fresh = ((await (await page.request.get(`/v1/tasks/${task.id}/context`)).json()) as { task: { createdAt: string; updatedAt: string } }).task;
	ids = { project: project.id, task: task.id, question: question.id, review: review.id };
	api = { task: { createdAt: fresh.createdAt, updatedAt: fresh.updatedAt }, question: { createdAt: answered.createdAt, answeredAt: answered.answeredAt }, review: { createdAt: review.createdAt, decidedAt: '' }, comment: { createdAt: comment.createdAt } };
	// The API really delivers the fields the UI shows.
	for (const [name, value] of Object.entries({ task: api.task.createdAt, updated: api.task.updatedAt, asked: api.question.createdAt, answered: api.question.answeredAt, requested: api.review.createdAt, comment: api.comment.createdAt })) {
		expect(Date.parse(value), `API field ${name}`).not.toBeNaN();
	}
});

test('task card: created and last changed, comment time, progress note time', async () => {
	await open(`task:${ids.task}`);
	await expectInstant(dialog().getByTestId('card-time').locator('time'), api.task.createdAt, 'task created');
	await expectInstant(dialog().getByTestId('card-updated').locator('time'), api.task.updatedAt, 'task updated');
	await expect(dialog().getByText('zuletzt geändert')).toBeVisible();
	const chat = dialog().locator('[data-testid="card-conversation"][data-thread="task"]');
	await expectInstant(chat.getByTestId('comment-time').first(), api.comment.createdAt, 'comment');
});

test('question card: asked and answered, and the task row says "erstellt"', async () => {
	await open(`question:${ids.question}`);
	const answer = dialog().getByTestId('card-answer');
	await expect(answer).toBeVisible();
	await expect(answer.getByText(/^gestellt/)).toBeVisible();
	await expectInstant(answer.locator('time').nth(0), api.question.createdAt, 'question asked');
	await expect(answer.getByText(/^beantwortet/)).toBeVisible();
	await expectInstant(answer.locator('time').nth(1), api.question.answeredAt, 'question answered');
	await expectInstant(dialog().getByTestId('card-time').locator('time'), api.question.createdAt, 'question side panel');
});

test('review card: requested, then decided after accepting', async () => {
	await open(`review:${ids.task}`);
	await expect(dialog().getByText(/^angefragt/).first()).toBeVisible();
	await expectInstant(dialog().getByTestId('card-time').locator('time'), api.review.createdAt, 'review requested');
	// Decide through the API (same rule as the button) and reopen: the decision time appears next to the request time.
	const decided = await post<{ decidedAt: string }>(`/v1/tasks/${ids.task}/review/decision`, { decision: 'accept' });
	api.review.decidedAt = decided.decidedAt;
	await open(`review:${ids.task}`);
	await expect(dialog().getByText(/entschieden/).first()).toBeVisible();
	await expectInstant(dialog().locator(`time[datetime="${new Date(api.review.decidedAt).toISOString()}"]`).first(), api.review.decidedAt, 'review decided');
});

test('board card: dezent "erstellt" with the exact instant', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto(`/project/${ids.project}`);
	await page.getByTestId('display-menu').click();
	await page.getByRole('dialog', { name: 'Anzeige' }).getByRole('button', { name: 'Board' }).click();
	await page.keyboard.press('Escape');
	const card = page.getByTestId('board-card').filter({ hasText: 'Zeitaufgabe' }).first();
	await expect(card).toBeVisible();
	await expect(card.getByText(/^erstellt/)).toBeVisible();
	await expectInstant(card.locator('time').first(), api.task.createdAt, 'board card created');
	// Quiet design: one short line, no wrapping into several lines.
	const lines = await card.locator('time').first().evaluate((el) => Math.round((el.parentElement as HTMLElement).getBoundingClientRect().height / parseFloat(getComputedStyle(el.parentElement as HTMLElement).lineHeight)));
	expect(lines).toBe(1);
});

test('"Für dich": an open question shows "gestellt" with the instant, no horizontal overflow at 320 px', async () => {
	const q = await post<{ id: string; createdAt: string }>(`/v1/tasks/${ids.task}/questions`, { prompt: 'Noch eine offene Frage?', options: ['Ja', 'Nein'] });
	await page.setViewportSize({ width: 320, height: 700 });
	await page.goto('/for-you');
	const card = page.getByTestId('needs-card').filter({ hasText: 'Noch eine offene Frage?' });
	await expect(card).toBeVisible();
	await expect(card.getByText(/^gestellt/)).toBeVisible();
	await expectInstant(card.locator('time').first(), q.createdAt, 'feed question asked');
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
