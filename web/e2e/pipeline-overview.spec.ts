import { expect, test, type Locator, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/pipeline-overview.spec.ts --project=chromium   (also --project=firefox / webkit)
// Card B926E7D8 (pipeline stage 2, docs/PLAN-PIPELINE-STUFE-2.md sections 5 and 7): a plan that waits for approval shows up in
// "Für dich" as a needs-you entry of kind "plan" (approve, or ask for changes with a comment), the plan events appear as feed posts and
// as updates in the overview, and the overview card of the task is marked. Plans are written through the real REST API like an agent
// would; the person decides in the browser.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/pipeline-stufe-2');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const LIVE = { timeout: 15_000 };
let project = { id: '', name: 'Überblickprojekt' };
let tasks = { approve: '', changes: '', race: '', cc: '', quiet: '' };

interface Pipeline {
	plan?: { version: number; state: string; decisionComment?: string | null } | null;
	steps: { step: string; state: string }[];
}
async function call<T>(method: 'post' | 'put' | 'patch', path: string, data: unknown): Promise<T> {
	const r = await page.request[method](path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const writePlan = (id: string, body: string) => call<Pipeline>('put', `/v1/tasks/${id}/plan`, { body, agentName: 'claude-code' });
const read = async (id: string) => (await (await page.request.get(`/v1/tasks/${id}/pipeline`)).json()) as Pipeline;

const needCard = (title: string) => page.locator('[data-testid="needs-card"][data-kind="plan"]').filter({ hasText: title });
const postCard = (text: string) => page.locator('[data-testid="post-card"][data-kind="plan"]').filter({ hasText: text });
const approveBtn = (card: Locator) => card.getByRole('button', { name: 'Plan freigeben', exact: true });
const changesBtn = (card: Locator) => card.getByRole('button', { name: 'Änderungen', exact: true });
const commentField = (card: Locator) => card.getByRole('textbox', { name: 'Was soll am Plan geändert werden?' });
const shoots = () => test.info().project.name === 'chromium';
const noOverflow = async (label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
};
/** Counts the plan decisions the browser sends while `action` runs. */
async function decisionsSent(action: () => Promise<unknown>): Promise<{ count: number; bodies: unknown[] }> {
	const bodies: unknown[] = [];
	const listener = (r: { url(): string; method(): string; postData(): string | null }) => {
		if (r.method() === 'POST' && r.url().endsWith('/plan/decision')) bodies.push(JSON.parse(r.postData() ?? '{}'));
	};
	page.on('request', listener);
	await action();
	await page.waitForTimeout(500);
	page.off('request', listener);
	return { count: bodies.length, bodies };
}

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Überblick Tester');
	project = { ...project, id: (await call<{ id: string }>('post', '/v1/projects', { name: project.name })).id };
	const mk = async (title: string) => (await call<{ id: string }>('post', '/v1/tasks', { projectID: project.id, title })).id;
	tasks = { approve: await mk('Plan zum Freigeben'), changes: await mk('Plan mit Änderungswunsch'), race: await mk('Plan wird überholt'), cc: await mk('Plan im Überblick'), quiet: await mk('Karte ohne Plan') };
});
test.afterAll(async () => {
	await page?.context().close();
});

test('a plan waiting for approval is a needs-you entry with the task title, the plan version and the first line of the plan', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	await writePlan(tasks.approve, '## Ziel\nDie Pipeline sichtbar machen.\n\n1. Bauen');
	await page.goto('/for-you');
	const card = needCard('Plan zum Freigeben');
	await expect(card).toBeVisible();
	await expect(card).toContainText('Plan wartet');
	await expect(card).toContainText('Plan v1 wartet auf Freigabe');
	await expect(card).toContainText('Überblickprojekt');
	await expect(approveBtn(card)).toBeVisible();
	await expect(changesBtn(card)).toBeVisible();
	// The entry sits among the needs-you cards, not among the news.
	await expect(page.getByTestId('needs-you').locator('[data-testid="needs-card"][data-kind="plan"]').first()).toBeVisible();
	// Only the plan waiting for approval is listed: a card without a plan is not.
	await expect(needCard('Karte ohne Plan')).toHaveCount(0);
});

test('a plan written by an agent is also a news post, readable in German', async () => {
	await page.goto('/for-you');
	const post = postCard('Plan v1');
	await expect(post.first()).toBeVisible();
	await expect(post.first()).toContainText('claude-code hat einen Plan geschrieben');
	await expect(post.first()).toContainText('Plan zum Freigeben');
	await expect(post.first()).not.toContainText('plan.written');
});

test('the entry opens the card on the Pipeline tab', async () => {
	await page.goto('/for-you');
	await needCard('Plan zum Freigeben').getByRole('button').first().click();
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	await expect(page).toHaveURL(/tab=pipeline/);
	await expect(page.getByTestId('card-dialog').getByTestId('card-tab-pipeline')).toHaveAttribute('aria-selected', 'true');
	await expect(page.getByTestId('card-dialog').getByTestId('pipeline-plan')).toContainText('Version 1');
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('card-dialog')).toHaveCount(0);
});

test('approving from the list sends the shown version once, removes the entry and shows the decision as a post', async () => {
	await page.goto('/for-you');
	const card = needCard('Plan zum Freigeben');
	const sent = await decisionsSent(() => approveBtn(card).dblclick());
	expect(sent.count).toBe(1);
	expect(sent.bodies[0]).toEqual({ decision: 'approve', version: 1 });
	await expect(card).toHaveCount(0);
	expect((await read(tasks.approve)).plan).toMatchObject({ version: 1, state: 'approved' });
	await expect(postCard('Plan v1').filter({ hasText: 'hat den Plan freigegeben' })).toBeVisible(LIVE);
});

test('asking for changes needs a comment: the first click opens the field, an empty one explains and sends nothing', async () => {
	await writePlan(tasks.changes, '1. Alles auf einmal');
	await page.goto('/for-you');
	const card = needCard('Plan mit Änderungswunsch');
	await expect(card).toBeVisible();
	await expect(commentField(card)).toHaveCount(0);
	await changesBtn(card).click();
	await expect(commentField(card)).toBeVisible();
	await expect(commentField(card)).toBeFocused();
	expect((await decisionsSent(() => changesBtn(card).click())).count).toBe(0);
	await expect(card.getByRole('alert')).toContainText('Beschreibe');
	await expect(commentField(card)).toHaveAttribute('aria-invalid', 'true');
	await commentField(card).fill('Bitte in kleinen Schritten.');
	await expect(card.getByRole('alert')).toHaveCount(0);
	const sent = await decisionsSent(() => changesBtn(card).click());
	expect(sent.count).toBe(1);
	expect(sent.bodies[0]).toEqual({ decision: 'request_changes', version: 1, comment: 'Bitte in kleinen Schritten.' });
	await expect(card).toHaveCount(0);
	expect((await read(tasks.changes)).plan).toMatchObject({ state: 'changes_requested', decisionComment: 'Bitte in kleinen Schritten.' });
	const post = postCard('Bitte in kleinen Schritten.');
	await expect(post).toBeVisible(LIVE);
	await expect(post).toContainText('hat Änderungen am Plan angefragt');
});

test('the comment survives a refresh of the list while it is typed', async () => {
	await writePlan(tasks.race, '1. Erste Fassung');
	await page.goto('/for-you');
	const card = needCard('Plan wird überholt');
	await changesBtn(card).click();
	await commentField(card).fill('Halber Gedanke');
	await call('post', `/v1/tasks/${tasks.quiet}/progress-notes`, { note: 'Nur ein Fortschritt', percent: 10 });
	await page.waitForTimeout(1500);
	await expect(commentField(card)).toHaveValue('Halber Gedanke');
});

test('a plan rewritten before the click is not decided: the message names it, the list shows the new version', async () => {
	await page.goto('/for-you');
	const card = needCard('Plan wird überholt');
	await expect(card).toContainText('Plan v1');
	// Freeze the list until the decision is sent, so the click is really based on the old version.
	const stale = await (await page.request.get('/v1/feed?limit=30')).json();
	let frozen = true;
	await page.route('**/v1/feed**', (r) => (frozen ? r.fulfill({ json: stale }) : r.continue()));
	await page.route('**/plan/decision', (r) => {
		frozen = false;
		return r.continue();
	});
	await writePlan(tasks.race, '1. Zweite Fassung');
	const sent = await decisionsSent(() => approveBtn(card).click());
	expect(sent.count).toBe(1);
	await expect(page.getByTestId('notice')).toContainText('Plan');
	await expect(page.getByTestId('notice')).toContainText('geändert');
	await expect(page.getByTestId('notice')).not.toContainText('plan_changed');
	expect((await read(tasks.race)).plan).toMatchObject({ version: 2, state: 'proposed' });
	await expect(needCard('Plan wird überholt')).toContainText('Plan v2', LIVE);
	await page.unroute('**/v1/feed**');
	await page.unroute('**/plan/decision');
});

test('the overview marks the card of a plan waiting for approval and counts it; updates name the plan events', async () => {
	await writePlan(tasks.cc, '1. Für den Überblick');
	// The overview lists projects in the management view.
	await page.goto(`/project/${project.id}`);
	await page.getByTestId('display-menu').click();
	await page.getByTestId('mode-management').click();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('project-tabs')).toBeVisible();
	await page.goto('/overview');
	const card = page.locator('[data-testid="oc-card"]').filter({ hasText: 'Plan im Überblick' });
	await expect(card).toBeVisible();
	await expect(card.getByTestId('oc-plan-waiting')).toContainText('Plan wartet auf Freigabe');
	await expect(card.getByTestId('oc-plan-waiting')).toHaveAccessibleName(/Plan wartet auf Freigabe/);
	await expect(page.locator('[data-testid="oc-card"]').filter({ hasText: 'Karte ohne Plan' }).getByTestId('oc-plan-waiting')).toHaveCount(0);
	// "Plan wird überholt" (version 2) and "Plan im Überblick" are waiting; the other plans are decided.
	await expect(page.getByTestId('cc-plans-waiting')).toContainText('2');
	await expect(page.getByTestId('cc-plans-waiting')).toContainText('Plan');
	// The marker opens the card on the Pipeline tab.
	await card.getByTestId('oc-plan-waiting').click();
	await expect(page.getByTestId('card-dialog').getByTestId('card-tab-pipeline')).toHaveAttribute('aria-selected', 'true');
	await page.keyboard.press('Escape');
	// Updates.
	await page.getByTestId('cc-section-updates').click();
	const update = page.locator('[data-testid="cc-update"]').filter({ hasText: 'Plan im Überblick' });
	await expect(update.first()).toBeVisible();
	await expect(update.first()).toContainText('Plan');
	await expect(update.first()).not.toContainText('Agentenereignis');
	await expect(page.locator('[data-testid="cc-update"][data-kind="plan.approved"]').first()).toContainText('freigegeben');
	await expect(page.locator('[data-testid="cc-update"][data-kind="plan.changes_requested"]').first()).toContainText('Änderungen');
});

test('once decided, the marker and the count are gone', async () => {
	await page.goto('/for-you');
	await approveBtn(needCard('Plan im Überblick')).click();
	await expect(needCard('Plan im Überblick')).toHaveCount(0);
	await page.goto('/overview');
	const card = page.locator('[data-testid="oc-card"]').filter({ hasText: 'Plan im Überblick' });
	await expect(card).toBeVisible();
	await expect(card.getByTestId('oc-plan-waiting')).toHaveCount(0);
	await expect(page.getByTestId('cc-plans-waiting')).toContainText('1');
});

test('unknown kinds from a newer server stay readable and nothing breaks', async () => {
	const page0 = await (await page.request.get('/v1/feed?limit=30')).json();
	const future = {
		...page0,
		needsYou: [
			...page0.needsYou,
			{ id: 'zukunft:1', kind: 'zukunft', projectID: project.id, projectName: project.name, taskID: tasks.quiet, taskTitle: 'Karte ohne Plan', taskVersion: 1, title: 'Etwas Neues', detail: 'Details dazu', options: [], blocking: false, actions: [] }
		],
		posts: [
			...page0.posts,
			{ id: 'zukunft:2', kind: 'zukunft', event: 'zukunft.event', projectID: project.id, projectName: project.name, taskID: tasks.quiet, taskTitle: 'Karte ohne Plan', actor: { type: 'Integration', id: 'x', name: 'Zukunft' }, text: 'Rohtext bleibt sichtbar', images: [] }
		]
	};
	await page.route('**/v1/feed**', (r) => r.fulfill({ json: future }));
	await page.goto('/for-you');
	const need = page.locator('[data-testid="needs-card"][data-kind="zukunft"]');
	await expect(need).toBeVisible();
	await expect(need).toContainText('Hinweis');
	await expect(need).toContainText('Etwas Neues');
	await expect(need).not.toContainText('undefined');
	const post = page.locator('[data-testid="post-card"][data-kind="zukunft"]');
	await expect(post).toContainText('Rohtext bleibt sichtbar');
	await expect(post).toContainText('Aktivität');
	await page.unroute('**/v1/feed**');
});

for (const [label, size] of [['desktop', { width: 1280, height: 900 }], ['mobile', { width: 390, height: 844 }]] as const) {
	test(`${label}: light and dark screenshots without horizontal scrolling`, async () => {
		test.skip(!shoots(), 'the pictures come from the Chromium run');
		await page.setViewportSize(size);
		const shot = await call<{ id: string }>('post', '/v1/tasks', { projectID: project.id, title: 'Wiederkehrende Aufgaben an Wochentagen' });
		await writePlan(shot.id, '## Ziel\nWiederkehrende Aufgaben auch an **Wochentagen**.\n\n1. Regel ergänzen\n2. Oberfläche bauen');
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			const name = scheme === 'light' ? 'hell' : 'dunkel';
			await page.goto('/for-you');
			await expect(needCard('Wiederkehrende Aufgaben an Wochentagen')).toBeVisible();
			await changesBtn(needCard('Wiederkehrende Aufgaben an Wochentagen')).click();
			await expect(commentField(needCard('Wiederkehrende Aufgaben an Wochentagen'))).toBeVisible();
			await noOverflow(`${label} ${scheme} for-you`);
			await page.waitForTimeout(300);
			await page.screenshot({ path: `${SHOTS}/fuer-dich-${label}-${name}.png` });
			await page.goto('/overview');
			await expect(page.getByTestId('oc-plan-waiting').first()).toBeVisible();
			await noOverflow(`${label} ${scheme} overview`);
			await page.waitForTimeout(300);
			await page.screenshot({ path: `${SHOTS}/ueberblick-${label}-${name}.png` });
		}
		await page.emulateMedia({ colorScheme: 'light' });
	});
}
