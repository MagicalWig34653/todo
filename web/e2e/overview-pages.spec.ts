import { expect, request, test, type APIRequestContext, type Locator, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signedInPage } from './support/session';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/overview-pages.spec.ts --project=chromium   (also --project=firefox / webkit)
// Card B0CF5F73 ("/now" showed "500" live): every overview page against data shaped like a real account, created through the real
// API. Above all: several build artifacts (screenshots) of one build share a buildID, per card and across cards of a project.
// No page may answer 5xx, throw, log an error or fall back to the SvelteKit error page, and each must show its real content.
// Screenshots go to $NOW500_SHOTS; without it none are written.
const SHOTS = process.env.NOW500_SHOTS ? resolve(dirname(fileURLToPath(import.meta.url)), '../..', process.env.NOW500_SHOTS) : null;
const PNG_1X1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const json = { headers: { 'Content-Type': 'application/json' } };
const LIVE = { timeout: 20_000 };

let page: Page;
let helper: APIRequestContext;
let problems: string[] = [];
const ids = { root: '', backend: '', detail: '', other: '' };

async function call<T>(method: 'post' | 'put' | 'patch', path: string, data: unknown): Promise<T> {
	const r = await page.request[method](path, { ...json, data });
	expect(r.status(), `${method} ${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json().catch(() => ({}))) as T;
}
const project = async (name: string, parentID?: string) => (await call<{ id: string }>('post', '/v1/projects', { name, parentID })).id;
const task = async (projectID: string, title: string) => (await call<{ id: string }>('post', '/v1/tasks', { projectID, title })).id;
const claim = (id: string, agentName = 'claude-code') => call('post', `/v1/tasks/${id}/claim`, { agentName });
const note = (id: string, text: string, percent?: number) => call('post', `/v1/tasks/${id}/progress-notes`, { note: text, percent });
const ask = (id: string, prompt: string, blocking = false) => call('post', `/v1/tasks/${id}/questions`, { prompt, options: ['Ja', 'Nein'], blocking });
const review = (id: string, summary: string) => call('post', `/v1/tasks/${id}/review`, { summary });
const session = (projectID: string, sessionName: string, activity: string) => call('put', `/v1/projects/${projectID}/session-status`, { sessionName, activity });
const plan = (id: string) => call('put', `/v1/tasks/${id}/plan`, { body: '## Ziel\nÜbersicht reparieren.\n\n1. Test schreiben\n2. Fehler beheben', agentName: 'claude-code' });
const decide = (id: string, decision: 'approve' | 'request_changes') => call('post', `/v1/tasks/${id}/plan/decision`, { decision, version: 1, comment: decision === 'approve' ? undefined : 'Bitte mit Tests.' });
const step = (id: string, name: string, state: string) => call('put', `/v1/tasks/${id}/pipeline/steps/${name}`, { state, agentName: 'claude-code' });

/** One screenshot of a build: upload, complete, register (POST /v1/builds). */
async function screenshot(taskID: string, filename: string, build: { buildID: string; label?: string; platform?: string; status?: string; commit?: string }): Promise<string> {
	const checksum = createHash('sha256').update(PNG_1X1).digest('hex');
	const cap = await call<{ attachmentID: string; uploadURL: string; token: string }>('post', '/v1/attachments/begin', { taskID, filename, role: 'result', mediaType: 'image/png', size: PNG_1X1.length, checksum });
	const put = await helper.put(cap.uploadURL, { headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` }, data: PNG_1X1 });
	expect(put.status(), await put.text()).toBeLessThan(300);
	await call('post', `/v1/attachments/${cap.attachmentID}/complete`, {});
	await call('post', '/v1/builds', { attachmentID: cap.attachmentID, ...build });
	return cap.attachmentID;
}

/** A running pipeline execution, the runner played through the real runner API (see pipeline-execution.spec.ts). */
async function execution(projectID: string, taskID: string) {
	const pairing = await call<{ deviceID: string; code: string }>('post', '/v1/agents/devices', { label: 'Linos Mac' });
	const paired = await helper.post('/v1/runner/pair', { ...json, data: { code: pairing.code } });
	expect(paired.ok(), await paired.text()).toBeTruthy();
	const auth = { Authorization: `Bearer ${((await paired.json()) as { token: string }).token}`, 'Content-Type': 'application/json' };
	const binding = await call<{ id: string }>('post', '/v1/agents/bindings', { projectID, deviceID: pairing.deviceID, repositoryKey: crypto.randomUUID(), label: 'todo-repo' });
	await call('post', `/v1/tasks/${taskID}/pipeline/execution`, { id: crypto.randomUUID(), bindingID: binding.id });
	const jobs = (await (await helper.get('/v1/runner/jobs?pipeline=1', { headers: auth })).json()) as { id: string; taskID: string }[];
	const job = jobs.find((j) => j.taskID === taskID)!;
	const claimed = await helper.post(`/v1/runner/jobs/${job.id}/claim?pipeline=1`, { headers: auth, data: {} });
	expect(claimed.status(), await claimed.text()).toBeLessThan(300);
	const run = (await claimed.json()) as { id: string; generation: number };
	const progress = await helper.post(`/v1/runner/runs/${run.id}/progress`, { headers: auth, data: { generation: run.generation, progress: 'Entwickler arbeitet' } });
	expect(progress.status(), await progress.text()).toBeLessThan(300);
}

async function seed() {
	ids.root = await project('Todolino');
	ids.backend = await project('Backend', ids.root);
	const pwa = await project('PWA', ids.root);
	const mcp = await project('MCP-Server', ids.backend);
	ids.other = await project('Orchestrator');
	const form = await project('Formular-Backend');
	const apple = await project('Apple-App');
	await project('Leeres Projekt');
	const quiet = await project('Ideen');
	await task(quiet, 'Irgendwann: Widgets');

	// Builds: three screenshots of one build on one card, the same build on a second card, a second build, status changes.
	ids.detail = await task(ids.backend, 'Jetzt-Seite reparieren');
	await claim(ids.detail);
	await note(ids.detail, 'Fehler nachgestellt', 30);
	await note(ids.detail, 'Test ist rot, Behebung läuft', 60);
	const web = { buildID: '564a6b4', label: 'Web 564a6b4', platform: 'web', commit: '564a6b4' };
	const first = await screenshot(ids.detail, 'jetzt-hell.png', { ...web, status: 'building' });
	await screenshot(ids.detail, 'jetzt-dunkel.png', { ...web, status: 'building' });
	await screenshot(ids.detail, 'jetzt-schmal.png', web);
	await call('post', '/v1/builds', { attachmentID: first, ...web, status: 'succeeded' });
	const second = await task(ids.backend, 'Aufgabenbaum prüfen');
	await screenshot(second, 'baum.png', { ...web, status: 'failed' });
	await screenshot(second, 'baum-alt.png', { buildID: 'ios-42', label: 'iOS 42', platform: 'ios' });
	for (const p of [pwa, mcp, ids.other, form, apple]) {
		const t = await task(p, 'Screenshots ablegen');
		for (const name of ['a.png', 'b.png']) await screenshot(t, name, { buildID: 'build-7', label: 'Build 7', platform: 'web', status: 'succeeded' });
		await note(t, 'Zwei Bilder angehängt', 80);
	}

	// Cards in every state, dependencies, questions, reviews, sessions (same name in two projects).
	const done = await task(ids.backend, 'Migration schreiben');
	await call('patch', `/v1/tasks/${done}`, { version: 1, status: 'done' });
	await call('put', `/v1/planning/tasks/${ids.detail}/dependencies`, { prerequisiteID: done });
	await call('put', `/v1/planning/tasks/${second}/dependencies`, { prerequisiteID: ids.detail });
	await ask(ids.detail, 'Soll die Liste gekürzt werden?', true);
	await ask(ids.detail, 'Auch die Apple-App anpassen?');
	await review(second, 'Baum zeigt Builds');
	const formReview = await task(form, 'Rate-Limit je Mandant');
	await review(formReview, 'Rate-Limit fertig');
	await ask(await task(ids.other, 'Runner-Bindings'), 'Soll der Runner pausieren?');
	for (const p of [ids.backend, ids.other]) await session(p, 'claude-main', 'Führt Tests aus');
	await session(ids.backend, 'web-worker', 'Beendet: fertig');

	// Pipeline plans in every state, steps failed / running / done, one execution.
	const proposed = await task(ids.backend, 'Plan wartet');
	await plan(proposed);
	const changes = await task(pwa, 'Plan mit Änderungen');
	await plan(changes);
	await decide(changes, 'request_changes');
	const steps = await task(pwa, 'Plan in Arbeit');
	await plan(steps);
	await decide(steps, 'approve');
	await step(steps, 'developer', 'running');
	await step(steps, 'developer', 'done');
	await step(steps, 'validation', 'running');
	await step(steps, 'validation', 'failed');
	await step(steps, 'tester', 'running');
	const executing = await task(mcp, 'Pipeline läuft');
	await plan(executing);
	await decide(executing, 'approve');
	await execution(mcp, executing);
}

/** Everything that must never happen on any page; collected from the first navigation on. */
function watch(p: Page) {
	p.on('response', (r) => { if (r.status() >= 500) problems.push(`HTTP ${r.status()} ${r.url()}`); });
	p.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
	// Visiting ten pages within seconds leaves the long polls of the pages before still open on the server, so the live
	// wait (/v1/sync/wait) of the next page may be refused with 429 (a limit on parallel waiters, not a defect of the page).
	p.on('console', (m) => { if (m.type() === 'error' && !/status of 429/.test(m.text())) problems.push(`console: ${m.text()}`); });
}
const failures: string[] = [];
/** Opens a page, waits for its content, lets late rendering happen and records everything that went wrong there. */
async function healthy(path: string, content: () => Promise<void>) {
	problems = [];
	await page.goto(path);
	let failure = '';
	try {
		await content();
		await page.waitForTimeout(500);
	} catch (e) {
		failure = (e as Error).message.replace(/\u001b\[[0-9;]*m/g, '').split('\n').slice(0, 4).join(' ');
	}
	if (await page.getByText('Internal Error').count()) problems.push('SvelteKit error page "500 Internal Error"');
	if (failure) problems.push(`content missing: ${failure}`);
	for (const p of problems) failures.push(`${path}: ${p}`);
}
const visible = (l: Locator) => expect(l.first()).toBeVisible(LIVE);

/** Opens every collapsed project row so that its sections (builds among them) are really rendered. */
async function expandAll() {
	await visible(page.getByTestId('now-project'));
	for (const row of await page.getByTestId('now-project').all()) {
		if (!(await row.evaluate((e) => (e as HTMLDetailsElement).open))) await row.locator('summary').click();
		await expect(row).toHaveJSProperty('open', true);
	}
}

/** One test for all pages: the bootstrap account is single use, and a failing page must not hide the others. */
test('every overview page renders its content without an error', async ({ browser }) => {
	test.setTimeout(180_000);
	page = await signedInPage(browser, 'Übersicht Tester');
	await page.setViewportSize({ width: 1280, height: 900 });
	helper = await request.newContext({ baseURL: test.info().project.use.baseURL, ignoreHTTPSErrors: test.info().project.use.ignoreHTTPSErrors });
	await seed();
	watch(page);

	await healthy('/now', async () => {
		await visible(page.getByTestId('now-view'));
		await expandAll();
		// Backend: five artifacts, three of them of one build on one card, a fourth of that build on another card.
		const backend = page.getByTestId('now-project').filter({ has: page.getByTestId('now-project-name').getByText('Backend', { exact: true }) });
		await expect(backend.getByTestId('now-build')).toHaveCount(5);
		await expect(backend.getByTestId('now-build').filter({ hasText: 'Web 564a6b4' })).toHaveCount(4);
		await expect(page.getByTestId('now-build')).toHaveCount(15);
	});
	if (SHOTS) {
		mkdirSync(SHOTS, { recursive: true });
		for (const scheme of ['light', 'dark'] as const) {
			for (const width of [1280, 390]) {
				await page.emulateMedia({ colorScheme: scheme });
				await page.setViewportSize({ width, height: 900 });
				await healthy('/now', async () => {
					await expandAll();
					await expect(page.getByTestId('now-build')).toHaveCount(15);
				});
				await page.screenshot({ path: `${SHOTS}/jetzt-${scheme}-${width}.png`, fullPage: true });
			}
		}
		await page.emulateMedia({ colorScheme: null });
		await page.setViewportSize({ width: 1280, height: 900 });
	}

	await healthy('/overview', async () => {
		await visible(page.getByTestId('command-center'));
		await visible(page.getByTestId('oc-builds'));
		await page.getByTestId('cc-section-updates').click();
		await visible(page.getByTestId('cc-update'));
	});

	await healthy('/for-you', async () => {
		await visible(page.getByTestId('for-you').getByText('Soll die Liste gekürzt werden?'));
	});

	await healthy('/activity', async () => {
		await visible(page.getByTestId('feed-item'));
	});

	await healthy(`/project/${ids.backend}`, async () => {
		await visible(page.getByText('Jetzt-Seite reparieren'));
	});
	await healthy(`/project/${ids.backend}/overview`, async () => {
		await visible(page.getByText('Jetzt-Seite reparieren'));
	});
	await healthy(`/project/${ids.root}/graph`, async () => {
		await visible(page.getByTestId('task-graph'));
		const subprojects = page.getByTestId('graph-sub');
		if (!(await subprojects.isChecked().catch(() => true))) await subprojects.check();
		await visible(page.getByTestId('graph-node').filter({ hasText: 'Jetzt-Seite reparieren' }));
		await visible(page.getByTestId('graph-build'));
	});

	await healthy(`/for-you?card=task:${ids.detail}`, async () => {
		const gallery = page.getByRole('dialog').getByTestId('card-gallery');
		await visible(gallery);
		await expect(gallery.getByRole('button', { name: /Web 564a6b4/ })).toHaveCount(3);
	});

	await healthy('/agents', async () => {
		await visible(page.getByTestId('device-list').getByText('Linos Mac'));
	});

	await helper.dispose();
	expect(failures).toEqual([]);
});
