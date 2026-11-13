import { expect, test, type Locator, type Page } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signedInPage } from './support/session';

// Needs a fresh backend database and the path of its SQLite file (the "brain" marker is an agent comment, which only
// MCP can write; the spec inserts that one row like the MCP path stores it):
//   E2E_DB=/abs/path/e2e.sqlite npx playwright test e2e/reviews-bulk.spec.ts --project=chromium   (also --project=webkit)
// Card 9791E2C3: Sammelfreigabe. Reviews in the overview are selectable, a bar accepts or requests changes for all selected
// ones after a confirmation step with the count, partial failures are listed, "Vom Brain empfohlen" filters the list.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/reviews-bulk');
const DB = process.env.E2E_DB;
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const N = 14;
const BRAIN = [1, 2, 3];
let tasks: { id: string; title: string; reviewID: string }[] = [];
const title = (n: number) => `Review-Aufgabe ${String(n).padStart(2, '0')}`;

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const status = async (id: string) => ((await (await page.request.get(`/v1/tasks/${id}/context`)).json()) as { task: { status: string } }).task.status;
const reviewState = async (id: string) =>
	((await (await page.request.get('/v1/reviews?state=all&limit=200')).json()) as { id: string; state: string; decisionNote?: string }[]).find((r) => r.id === id);
const rows = () => page.getByTestId('cc-reviews').getByTestId('review-row');
const row = (n: number) => rows().filter({ hasText: title(n) });
const box = (n: number) => row(n).getByTestId('review-select');
const bar = () => page.getByTestId('review-bulk-bar');
const count = () => page.getByTestId('review-bulk-count');
async function openReviews() {
	await page.goto('/overview');
	await page.getByTestId('cc-section-reviews').click();
	await expect(page.getByTestId('review-toolbar')).toBeVisible();
}
async function noOverflow(label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}
const shot = async (name: string) => { await page.waitForTimeout(350); await page.screenshot({ path: `${SHOTS}/${name}.png` }); };
async function theme(mode: 'dark' | 'light') {
	await page.evaluate((m) => (m === 'dark' ? localStorage.setItem('todo.theme', 'dark') : localStorage.removeItem('todo.theme')), mode);
	await page.reload();
	await page.getByTestId('cc-section-reviews').click();
	await expect(page.getByTestId('review-toolbar')).toBeVisible();
}

test.beforeAll(async ({ browser }) => {
	test.skip(!DB, 'E2E_DB (path of the scratch SQLite file) is required');
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Sammel Tester');
	const project = await post<{ id: string }>('/v1/projects', { name: 'Sammelprojekt' });
	for (let n = 1; n <= N; n++) {
		const t = await post<{ id: string }>('/v1/tasks', { projectID: project.id, title: title(n) });
		const r = await post<{ id: string }>(`/v1/tasks/${t.id}/review`, { summary: `Ergebnis ${n} ist fertig.\n- Neu: Sammelfreigabe\n- Geprüft: Tests`, agentName: 'Claude Code' });
		tasks.push({ id: t.id, title: title(n), reviewID: r.id });
	}
	// The management view lists the project in the account overview.
	await page.goto(`/project/${project.id}`);
	if (!(await page.getByTestId('project-tabs').isVisible())) {
		await page.getByTestId('display-menu').click();
		await page.getByTestId('mode-management').click();
		await page.keyboard.press('Escape');
	}
	await expect(page.getByTestId('project-tabs')).toBeVisible();
	// "Vom Brain empfohlen": an agent comment labelled brain in the chat of the review.
	for (const n of BRAIN) {
		const t = tasks[n - 1];
		// Fluent stores UUIDs upper-case in SQLite.
		execFileSync('sqlite3', ['-cmd', '.timeout 10000', DB!, `INSERT INTO comments (id, task_id, author_id, body, version, review_id, author_kind, author_label, created_at)
			VALUES ('${randomUUID().toUpperCase()}', '${t.id.toUpperCase()}', (SELECT id FROM users LIMIT 1), 'Lino: das ist ok, annehmen.', 1,
			'${t.reviewID.toUpperCase()}', 'agent', 'brain', strftime('%s','now'))`]);
	}
});
test.afterAll(async () => {
	await page?.context().close();
});

test('every row has a labelled checkbox; selecting shows the bar with the count; select-all takes the visible rows; clear', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	await openReviews();
	await expect(rows()).toHaveCount(N);
	await expect(bar()).toHaveCount(0);
	await expect(box(5)).toHaveAccessibleName('Review auswählen: Review-Aufgabe 05');
	await box(5).check();
	await box(6).check();
	await expect(bar()).toBeVisible();
	await expect(bar()).toHaveAccessibleName('Sammelaktion für Reviews');
	await expect(count()).toHaveText('2 ausgewählt');
	await expect(page.getByTestId('review-select-all')).toHaveAttribute('aria-checked', 'mixed');
	await page.getByTestId('review-select-all').check();
	await expect(count()).toHaveText(`${N} ausgewählt`);
	await expect(page.getByTestId('review-select-all')).toHaveAttribute('aria-checked', 'true');
	await shot('desktop-hell-auswahl');
	await page.getByTestId('review-select-all').uncheck();
	await expect(bar()).toHaveCount(0);
	await box(5).check();
	await page.getByTestId('review-bulk-clear').click();
	await expect(bar()).toHaveCount(0);
	await expect(box(5)).not.toBeChecked();
	// The existing single decision stays in every row.
	await expect(row(5).getByTestId('review-accept')).toBeVisible();
	await expect(row(5).getByTestId('review-note')).toBeVisible();
});

test('keyboard: Space selects, the bar is reachable with Tab, Escape cancels the confirmation and then clears', async () => {
	await openReviews();
	await box(7).focus();
	await page.keyboard.press('Space');
	await expect(box(7)).toBeChecked();
	await expect(count()).toHaveText('1 ausgewählt');
	await page.getByTestId('review-bulk-accept').focus();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('review-bulk-confirm')).toBeVisible();
	await expect(page.getByTestId('review-bulk-confirm')).toHaveAttribute('role', 'alertdialog');
	// Focus moves to the confirming button, so Enter would confirm: it must be the deliberate action.
	await expect(page.getByTestId('review-bulk-confirm-go')).toBeFocused();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('review-bulk-confirm')).toHaveCount(0);
	await expect(box(7)).toBeChecked();
	await page.getByTestId('review-bulk-note').focus();
	await page.keyboard.press('Escape');
	await expect(bar()).toHaveCount(0);
	await expect(await status(tasks[6].id)).toBe('in_review');
});

test('filter "Vom Brain empfohlen": badge on the rows, only they are listed, select-all takes only them', async () => {
	await openReviews();
	await expect(page.getByTestId('review-filter-all')).toHaveText(`Alle (${N})`);
	await expect(page.getByTestId('review-filter-brain')).toHaveText(`Vom Brain empfohlen (${BRAIN.length})`);
	await expect(page.getByTestId('review-brain-badge')).toHaveCount(BRAIN.length);
	await expect(row(1).getByTestId('review-brain-badge')).toHaveText('Vom Brain empfohlen');
	await expect(row(4).getByTestId('review-brain-badge')).toHaveCount(0);
	await page.getByTestId('review-filter-brain').click();
	await expect(page.getByTestId('review-filter-brain')).toHaveAttribute('aria-pressed', 'true');
	await expect(rows()).toHaveCount(BRAIN.length);
	await page.getByTestId('review-select-all').check();
	await expect(count()).toHaveText(`${BRAIN.length} ausgewählt`);
	// Leaving the filter drops hidden rows from the selection, never selects them.
	await page.getByTestId('review-filter-all').click();
	await expect(rows()).toHaveCount(N);
	await expect(count()).toHaveText(`${BRAIN.length} ausgewählt`);
	await expect(box(4)).not.toBeChecked();
	await page.getByTestId('review-filter-brain').click();
	await shot('desktop-hell-brain-filter');
});

test('accept: confirmation names the count and can be cancelled; confirming accepts all selected and reports it', async () => {
	await openReviews();
	await page.getByTestId('review-filter-brain').click();
	await page.getByTestId('review-select-all').check();
	await page.getByTestId('review-bulk-note').fill('Mündlich freigegeben');
	await page.getByTestId('review-bulk-accept').click();
	const confirm = page.getByTestId('review-bulk-confirm');
	await expect(confirm).toContainText('3 Reviews annehmen?');
	await expect(confirm).toContainText('Zurücknehmen geht nur einzeln');
	await shot('desktop-hell-bestaetigung');
	// Cancel: nothing happened.
	await page.getByTestId('review-bulk-confirm-cancel').click();
	await expect(confirm).toHaveCount(0);
	await expect(rows()).toHaveCount(BRAIN.length);
	for (const n of BRAIN) expect(await status(tasks[n - 1].id)).toBe('in_review');
	// Confirm.
	await page.getByTestId('review-bulk-accept').click();
	await page.getByTestId('review-bulk-confirm-go').click();
	await expect(page.getByTestId('review-bulk-result')).toHaveText(/3 Reviews angenommen\./);
	await expect(page.getByTestId('review-bulk-result')).toHaveAttribute('role', 'status');
	await expect(bar()).toHaveCount(0);
	for (const n of BRAIN) {
		expect(await status(tasks[n - 1].id)).toBe('done');
		const r = await reviewState(tasks[n - 1].reviewID);
		expect(r?.state).toBe('accepted');
		expect(r?.decisionNote).toBe('Mündlich freigegeben');
	}
	await page.getByTestId('review-filter-all').click();
	await expect(rows()).toHaveCount(N - BRAIN.length);
	await expect(page.getByTestId('cc-count-reviews')).toHaveText(String(N - BRAIN.length));
	await shot('desktop-hell-ergebnis');
});

test('partial failure: a review decided meanwhile is reported, the others are done, nothing is rolled back', async () => {
	await openReviews();
	for (const n of [4, 5, 6, 8]) await box(n).check();
	await expect(count()).toHaveText('4 ausgewählt');
	// Someone decides review 5 after the selection but before the batch arrives (real backend, real single path).
	// In-page fetch wrapper (page.route does not intercept this request in WebKit): decide review 5 through the real single
	// path right before the batch request leaves.
	await page.evaluate((taskID) => {
		const original = window.fetch.bind(window);
		let done = false;
		window.fetch = async (input, init) => {
			const url = typeof input === 'string' ? input : input instanceof Request ? input.url : String(input);
			if (!done && url.endsWith('/v1/reviews/decisions') && init?.method === 'POST') {
				done = true;
				const r = await original(`/v1/tasks/${taskID}/review/decision`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ decision: 'accept' }) });
				if (!r.ok) throw new Error(`interleaved decision failed: ${r.status}`);
			}
			return original(input, init);
		};
	}, tasks[4].id);
	await page.getByTestId('review-bulk-accept').click();
	await expect(page.getByTestId('review-bulk-confirm')).toContainText('4 Reviews annehmen?');
	await page.getByTestId('review-bulk-confirm-go').click();
	const result = page.getByTestId('review-bulk-result');
	await expect(result).toContainText('3 von 4 erledigt, 1 nicht');
	await expect(result).toHaveAttribute('role', 'alert');
	await expect(page.getByTestId('review-bulk-failures').locator('li')).toHaveCount(1);
	await expect(page.getByTestId('review-bulk-failures')).toContainText('Review-Aufgabe 05');
	await expect(page.getByTestId('review-bulk-failures')).toContainText('Schon entschieden');
	for (const n of [4, 5, 6, 8]) expect(await status(tasks[n - 1].id), title(n)).toBe('done');
	await expect(rows()).toHaveCount(N - BRAIN.length - 4);
	await shot('desktop-hell-teilfehler');
	await result.getByRole('button', { name: 'Meldung schließen' }).click();
	await expect(result).toHaveCount(0);
});

test('changes requested needs a note; with it all selected go back to work with the shared note', async () => {
	await openReviews();
	await box(9).check();
	await box(10).check();
	await page.getByTestId('review-bulk-changes').click();
	await expect(page.getByText('Bitte beschreibe, was geändert werden soll.')).toBeVisible();
	await expect(page.getByTestId('review-bulk-confirm')).toHaveCount(0);
	await page.getByTestId('review-bulk-note').fill('Bitte Tests ergänzen');
	await page.getByTestId('review-bulk-changes').click();
	await expect(page.getByTestId('review-bulk-confirm')).toContainText('Für 2 Reviews Änderungen anfordern?');
	await page.getByTestId('review-bulk-confirm-go').click();
	await expect(page.getByTestId('review-bulk-result')).toHaveText(/Für 2 Reviews Änderungen angefordert\./);
	for (const n of [9, 10]) {
		expect(await status(tasks[n - 1].id)).toBe('in_progress');
		const r = await reviewState(tasks[n - 1].reviewID);
		expect(r?.state).toBe('changes_requested');
		expect(r?.decisionNote).toBe('Bitte Tests ergänzen');
	}
});

test('layout: 390 px mobile and dark mode (bar, confirmation, result); no horizontal overflow', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await openReviews();
	await expect(rows().first()).toBeVisible();
	await noOverflow('list');
	await shot('mobil-hell-liste');
	await page.getByTestId('review-select-all').check();
	await expect(bar()).toBeVisible();
	await noOverflow('selection');
	// The bar sits inside the viewport and its buttons are reachable (tap size).
	const b = await bar().boundingBox();
	expect(b!.y + b!.height).toBeLessThanOrEqual(844);
	for (const id of ['review-bulk-accept', 'review-bulk-changes']) {
		const r = await page.getByTestId(id).boundingBox();
		expect(r!.height, id).toBeGreaterThanOrEqual(32);
	}
	await shot('mobil-hell-auswahl');
	await page.getByTestId('review-bulk-accept').click();
	await expect(page.getByTestId('review-bulk-confirm')).toBeVisible();
	await noOverflow('confirm');
	await shot('mobil-hell-bestaetigung');
	await page.getByTestId('review-bulk-confirm-cancel').click();
	await theme('dark');
	await expect(page.locator('html')).toHaveClass(/dark/);
	await page.getByTestId('review-select-all').check();
	await noOverflow('dark selection');
	await shot('mobil-dunkel-auswahl');
	await page.getByTestId('review-bulk-accept').click();
	await shot('mobil-dunkel-bestaetigung');
	await page.getByTestId('review-bulk-confirm-cancel').click();
	await page.setViewportSize({ width: 1280, height: 900 });
	await expect(page.getByTestId('review-bulk-note')).toBeVisible();
	await shot('desktop-dunkel-auswahl');
	await theme('light');
});

test('single decision is unchanged, and the empty state follows the last review', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	await openReviews();
	const left = await rows().count();
	expect(left).toBeGreaterThan(0);
	await row(11).getByTestId('review-accept').click();
	await expect(row(11)).toHaveCount(0);
	expect(await status(tasks[10].id)).toBe('done');
	await expect(rows()).toHaveCount(left - 1);
	// Decide the rest in one batch; the empty state and no toolbar remain.
	await page.getByTestId('review-select-all').check();
	await page.getByTestId('review-bulk-accept').click();
	await page.getByTestId('review-bulk-confirm-go').click();
	await expect(page.getByTestId('review-bulk-result')).toContainText(`${left - 1} Reviews angenommen.`);
	await expect(rows()).toHaveCount(0);
	await expect(page.getByText('Keine fälligen Reviews')).toBeVisible();
	await expect(page.getByTestId('review-toolbar')).toHaveCount(0);
});
