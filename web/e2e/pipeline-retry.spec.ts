import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { clearMocks, installMocks, setMocks } from './support/fetchMock';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/pipeline-retry.spec.ts --project=chromium   (also --project=firefox / webkit)
// Card B926E7D8 (pipeline stage 2, docs/PLAN-PIPELINE-STUFE-2.md sections 2, 3 and 7): the Pipeline tab of a card shows steps that the
// project switched off ("Aus", not counted), model and effort per role, and offers "Wiederholen" at a failed step ("Runde n von m",
// disabled when the rounds are used up). Settings, plans and step states are written through the real REST API like an agent
// would; the browser checks what a person sees and does.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/pipeline-stufe-2');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const STEPS = ['Planer', 'Freigabe', 'Entwickler', 'Validierung', 'Tester', 'Review'];
const LIVE = { timeout: 15_000 };

interface Pipeline {
	plan?: { version: number; state: string } | null;
	steps: { step: string; state: string; enabled?: boolean }[];
	fixRounds?: { used: number; max: number; remaining: number };
	waitingApproval?: boolean;
}
let projects = { main: '', off: '', noApproval: '', noPlanner: '', zero: '' };
let tasks = { retry: '', rounds: '', off: '', roles: '', noApproval: '', noPlanner: '', zero: '', races: '', shot: '' };

async function call<T>(method: 'post' | 'put' | 'patch', path: string, data: unknown): Promise<T> {
	const r = await page.request[method](path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const settings = async (project: string, data: Record<string, unknown>) => {
	const current = (await (await page.request.get(`/v1/projects/${project}/pipeline-settings`)).json()) as { revision: number };
	return call('patch', `/v1/projects/${project}/pipeline-settings`, { revision: current.revision, ...data });
};
const writePlan = (id: string, body: string) => call<Pipeline>('put', `/v1/tasks/${id}/plan`, { body, agentName: 'claude-code' });
const approve = (id: string, version = 1) => call<Pipeline>('post', `/v1/tasks/${id}/plan/decision`, { decision: 'approve', version });
const setStep = (id: string, step: string, state: string, note?: string) =>
	call<Pipeline>('put', `/v1/tasks/${id}/pipeline/steps/${step}`, { state, note, agentName: 'claude-code' });
const retryApi = (id: string, step: string, planVersion?: number) => page.request.post(`/v1/tasks/${id}/pipeline/steps/${step}/retry`, { ...json, data: { planVersion, agentName: 'claude-code' } });
const read = async (id: string) => (await (await page.request.get(`/v1/tasks/${id}/pipeline`)).json()) as Pipeline;
/** An approved plan with a developer that finished and a tester that failed. */
async function failedTester(id: string) {
	await writePlan(id, '1. Bauen\n2. Testen');
	await approve(id);
	await setStep(id, 'developer', 'done');
	await setStep(id, 'validation', 'done');
	await setStep(id, 'tester', 'failed', '2 Tests rot');
}

const dialog = () => page.getByTestId('card-dialog');
const tab = () => dialog().getByTestId('card-tab-pipeline');
const panel = () => dialog().getByRole('tabpanel');
const step = (name: string) => panel().getByTestId('pipeline-step').nth(STEPS.indexOf(name));
const stepState = (name: string) => step(name).getByTestId('pipeline-step-state');
const roleLine = (name: string) => step(name).getByTestId('pipeline-step-role');
const retry = (name: string) => step(name).getByRole('button', { name: 'Wiederholen', exact: true });
const round = (name: string) => step(name).getByTestId('pipeline-step-round');
const feedback = () => panel().getByTestId('pipeline-feedback');
const summary = () => panel().getByTestId('pipeline-step-count');
const open = async (id: string) => {
	await page.goto(`/for-you?card=task:${id}&tab=pipeline`);
	await expect(dialog()).toBeVisible();
	await expect(tab()).toBeVisible();
	await expect(panel().getByTestId('pipeline-step').first().or(panel().getByTestId('tab-empty'))).toBeVisible();
};
/** Counts the retry requests the browser sends while `action` runs. */
async function retriesSent(action: () => Promise<unknown>): Promise<{ count: number; bodies: unknown[] }> {
	const bodies: unknown[] = [];
	const listener = (r: { url(): string; method(): string; postData(): string | null }) => {
		if (r.method() === 'POST' && r.url().endsWith('/retry')) bodies.push(JSON.parse(r.postData() ?? '{}'));
	};
	page.on('request', listener);
	await action();
	await page.waitForTimeout(500);
	page.off('request', listener);
	return { count: bodies.length, bodies };
}
/** Freezes what the browser reads of the pipeline until it sends the retry, so the click really is based on an old state. */
async function frozenUntilRetry(id: string) {
	const stale = await read(id);
	await setMocks(page, [{ url: `/v1/tasks/${id}/pipeline`, method: 'GET', json: stale, until: '/retry' }]);
	return () => clearMocks(page);
}
const noOverflow = async (label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
	const inner = await dialog().getByTestId('card-scroll').evaluate((el) => el.scrollWidth - el.clientWidth);
	expect(inner, `${label}: card scroll area overflows`).toBeLessThanOrEqual(0);
};
const shoots = () => test.info().project.name === 'chromium';

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Retry Tester');
	await installMocks(page);
	const mkProject = async (name: string) => ((await call<{ id: string }>('post', '/v1/projects', { name })).id);
	const mkTask = async (project: string, title: string) => ((await call<{ id: string }>('post', '/v1/tasks', { projectID: project, title })).id);
	projects = { main: await mkProject('Wiederholprojekt'), off: await mkProject('Projekt ohne Tester'), noApproval: await mkProject('Projekt ohne Freigabe'), noPlanner: await mkProject('Projekt ohne Planer'), zero: await mkProject('Projekt ohne Runden') };
	tasks = {
		retry: await mkTask(projects.main, 'Tester fehlgeschlagen'),
		rounds: await mkTask(projects.main, 'Runden aufgebraucht'),
		roles: await mkTask(projects.main, 'Modelle je Rolle'),
		races: await mkTask(projects.main, 'Zustand ändert sich'),
		shot: await mkTask(projects.main, 'Fehler im Tester'),
		off: await mkTask(projects.off, 'Karte ohne Tester'),
		noApproval: await mkTask(projects.noApproval, 'Plan ohne Freigabe'),
		noPlanner: await mkTask(projects.noPlanner, 'Karte ohne Planer'),
		zero: await mkTask(projects.zero, 'Keine Wiederholung erlaubt')
	};
	await settings(projects.main, { maxFixRounds: 2, roles: { developer: { model: 'sonnet', effort: 'high' }, tester: { model: 'haiku' } } });
	await settings(projects.off, { steps: { tester: false, review: false } });
	await settings(projects.noApproval, { steps: { approval: false } });
	await settings(projects.noPlanner, { steps: { planner: false, approval: false } });
	await settings(projects.zero, { maxFixRounds: 0 });
});
test.afterAll(async () => {
	await page?.context().close();
});

test('model and effort of each role are shown at the steps; validation and approval have none', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	await writePlan(tasks.roles, '1. Lesen\n2. Bauen');
	await open(tasks.roles);
	await expect(roleLine('Entwickler')).toContainText('Modell: sonnet');
	await expect(roleLine('Entwickler')).toContainText('Effort: Hoch');
	await expect(roleLine('Tester')).toContainText('Modell: haiku');
	await expect(roleLine('Tester')).toContainText('Effort: Standard');
	await expect(roleLine('Planer')).toContainText('Modell: Standard');
	await expect(roleLine('Review')).toContainText('Modell: Standard');
	await expect(step('Validierung').getByTestId('pipeline-step-role')).toHaveCount(0);
	await expect(step('Freigabe').getByTestId('pipeline-step-role')).toHaveCount(0);
	const server = await read(tasks.roles);
	expect(server.fixRounds).toEqual({ used: 0, max: 2, remaining: 2 });
	await expect(summary()).toContainText('1 von 6');
});

// A settings change sends no live hint to cards that are open (it is no event of the card), so it shows when the card is opened again.
test('a changed project setting shows when the card is opened again', async () => {
	await settings(projects.main, { roles: { developer: { model: 'opus' } } });
	await open(tasks.roles);
	await expect(roleLine('Entwickler')).toContainText('Modell: opus');
	await settings(projects.main, { roles: { developer: { model: 'sonnet' } } });
	await open(tasks.roles);
	await expect(roleLine('Entwickler')).toContainText('Modell: sonnet');
});

test('steps the project switched off are marked "Aus", not clickable and not counted', async () => {
	await writePlan(tasks.off, '1. Bauen');
	await approve(tasks.off);
	await setStep(tasks.off, 'developer', 'done');
	await open(tasks.off);
	await expect(stepState('Tester')).toHaveText('Aus');
	await expect(stepState('Review')).toHaveText('Aus');
	await expect(step('Tester')).toHaveAttribute('data-enabled', 'false');
	await expect(step('Review')).toHaveAttribute('data-enabled', 'false');
	await expect(step('Entwickler')).toHaveAttribute('data-enabled', 'true');
	await expect(roleLine('Tester')).toHaveCount(0);
	await expect(step('Tester').getByRole('button')).toHaveCount(0);
	// Planer, Freigabe, Entwickler are finished, Validierung is open: 3 of the 4 steps that are on.
	await expect(summary()).toContainText('3 von 4');
	await expect(summary()).toContainText('2 aus');
	// An agent cannot set a step that is off: the server refuses with 409.
	const refused = await page.request.put(`/v1/tasks/${tasks.off}/pipeline/steps/tester`, { ...json, data: { state: 'running', agentName: 'claude-code' } });
	expect(refused.status()).toBe(409);
	await expect(stepState('Tester')).toHaveText('Aus');
});

test('approval switched off: the plan is released at once, the step says "Aus" and nobody is asked', async () => {
	await writePlan(tasks.noApproval, '1. Direkt los');
	await open(tasks.noApproval);
	await expect(panel().getByTestId('pipeline-plan-state')).toHaveText('Freigegeben');
	await expect(stepState('Freigabe')).toHaveText('Aus');
	await expect(panel().getByTestId('pipeline-plan-decided')).toContainText('Automatisch freigegeben');
	await expect(panel().getByRole('button', { name: 'Plan freigeben', exact: true })).toHaveCount(0);
	await expect(tab()).toHaveAccessibleName('Pipeline');
	await expect(dialog().getByTestId('card-tab-hint-pipeline')).toHaveCount(0);
});

test('planner switched off: an untouched card still shows the empty state and says what is off', async () => {
	await open(tasks.noPlanner);
	await expect(panel().getByTestId('tab-empty')).toContainText('Noch keine Pipeline');
	await expect(panel().getByTestId('pipeline-off-hint')).toContainText('Planer');
	await expect(panel().getByTestId('pipeline-off-hint')).toContainText('Freigabe');
	// Without a plan the work steps are not locked by the plan gate: an agent reports straight away.
	await setStep(tasks.noPlanner, 'developer', 'running', 'Legt los');
	await expect(stepState('Entwickler')).toHaveText('Läuft', LIVE);
	await expect(stepState('Planer')).toHaveText('Aus');
	await expect(stepState('Freigabe')).toHaveText('Aus');
});

test('"Wiederholen" appears only at the failed step with "Runde 1 von 2" and sends one request with the plan version', async () => {
	await failedTester(tasks.retry);
	await open(tasks.retry);
	await expect(stepState('Tester')).toHaveText('Fehlgeschlagen');
	await expect(retry('Tester')).toBeVisible();
	await expect(retry('Tester')).toBeEnabled();
	await expect(round('Tester')).toHaveText('Runde 1 von 2');
	for (const name of ['Planer', 'Freigabe', 'Entwickler', 'Validierung', 'Review']) await expect(step(name).getByRole('button', { name: 'Wiederholen' })).toHaveCount(0);
	await expect(panel().getByRole('button', { name: 'Wiederholen' })).toHaveCount(1);
	const { count, bodies } = await retriesSent(() => retry('Tester').dblclick());
	expect(count).toBe(1);
	expect(bodies[0]).toMatchObject({ planVersion: 1 });
	await expect(stepState('Tester')).toHaveText('Offen');
	await expect(step('Tester')).not.toContainText('2 Tests rot');
	await expect(stepState('Entwickler')).toHaveText('Fertig');
	await expect(panel().getByRole('button', { name: 'Wiederholen' })).toHaveCount(0);
	await expect(feedback()).toContainText('Tester');
	await expect(feedback()).toContainText('wiederholt');
	await expect(feedback()).toBeFocused();
	const server = await read(tasks.retry);
	expect(server.fixRounds).toMatchObject({ used: 1, max: 2, remaining: 1 });
	expect(server.steps.find((s) => s.step === 'tester')?.state).toBe('pending');
	expect(server.steps.find((s) => s.step === 'developer')?.state).toBe('done');
	const history = panel().getByTestId('pipeline-history');
	await history.locator('summary').click();
	await expect(history).toContainText('Tester wiederholt');
});

test('the second failure offers the last round; the third has none left and the button is disabled with a reason', async () => {
	await setStep(tasks.retry, 'tester', 'failed', 'Immer noch rot');
	await expect(round('Tester')).toHaveText('Runde 2 von 2', LIVE);
	await expect(retry('Tester')).toBeEnabled();
	await retry('Tester').click();
	await expect(stepState('Tester')).toHaveText('Offen');
	await setStep(tasks.retry, 'tester', 'failed', 'Weiter rot');
	await expect(stepState('Tester')).toHaveText('Fehlgeschlagen', LIVE);
	await expect(retry('Tester')).toBeDisabled();
	await expect(step('Tester').getByTestId('pipeline-step-exhausted')).toContainText('Alle 2 Fix-Runden sind verbraucht');
	await expect(round('Tester')).toHaveCount(0);
	const sent = await retriesSent(() => retry('Tester').click({ force: true }).catch(() => undefined));
	expect(sent.count).toBe(0);
	expect((await read(tasks.retry)).fixRounds).toMatchObject({ used: 2, remaining: 0 });
});

test('a new plan version starts the rounds again', async () => {
	await writePlan(tasks.retry, '1. Bauen\n2. Testen\n3. Nachtrag');
	await approve(tasks.retry, 2);
	await setStep(tasks.retry, 'tester', 'failed', 'Neue Runde');
	await expect(round('Tester')).toHaveText('Runde 1 von 2', LIVE);
	await expect(retry('Tester')).toBeEnabled();
});

test('a project with zero rounds never offers a retry and says so', async () => {
	await failedTester(tasks.zero);
	await open(tasks.zero);
	await expect(retry('Tester')).toBeDisabled();
	await expect(step('Tester').getByTestId('pipeline-step-exhausted')).toContainText('Wiederholen ist in diesem Projekt ausgeschaltet');
});

test('the used-up rounds of a race are explained: the server refuses, the card reloads and shows the disabled button', async () => {
	await failedTester(tasks.rounds);
	await open(tasks.rounds);
	await expect(retry('Tester')).toBeEnabled();
	const unfreeze = await frozenUntilRetry(tasks.rounds);
	// Meanwhile an agent uses both rounds.
	for (const note of ['rot 1', 'rot 2']) {
		expect((await retryApi(tasks.rounds, 'tester', 1)).status()).toBeLessThan(300);
		await setStep(tasks.rounds, 'tester', 'failed', note);
	}
	const sent = await retriesSent(() => retry('Tester').click());
	expect(sent.count).toBe(1);
	await expect(feedback()).toContainText('Fix-Runden');
	await expect(feedback()).not.toContainText('fix_rounds_exhausted');
	await expect(retry('Tester')).toBeDisabled();
	await unfreeze();
});

test('a step that is no longer failed is explained and reloaded', async () => {
	await failedTester(tasks.races);
	await open(tasks.races);
	await expect(retry('Tester')).toBeEnabled();
	const unfreeze = await frozenUntilRetry(tasks.races);
	expect((await retryApi(tasks.races, 'tester', 1)).status()).toBeLessThan(300);
	await retriesSent(() => retry('Tester').click());
	await expect(feedback()).toContainText('nicht fehlgeschlagen');
	await expect(feedback()).not.toContainText('step_not_failed');
	await expect(stepState('Tester')).toHaveText('Offen');
	await expect(panel().getByRole('button', { name: 'Wiederholen' })).toHaveCount(0);
	await unfreeze();
});

test('the other refusals have German messages: plan_changed, step_disabled, 403 and a lost connection', async () => {
	await open(tasks.races);
	await setStep(tasks.races, 'tester', 'failed', 'Wieder rot');
	await expect(retry('Tester')).toBeEnabled(LIVE);
	const refuse = async (status: number, body: Record<string, unknown>) => {
		await setMocks(page, [{ url: '/retry', method: 'POST', status, json: { error: true, ...body } }]);
		await retry('Tester').click();
	};
	await refuse(409, { reason: 'plan_changed' });
	await expect(feedback()).toContainText('Plan');
	await expect(feedback()).toContainText('geändert');
	await refuse(409, { reason: 'step_disabled' });
	await expect(feedback()).toContainText('ausgeschaltet');
	await refuse(403, { reason: 'forbidden' });
	await expect(feedback()).toContainText('Berechtigung');
	await setMocks(page, [{ url: '/retry', method: 'POST', abort: true }]);
	await retry('Tester').click();
	await expect(feedback()).toContainText('nicht erreichbar');
	await clearMocks(page);
	for (const raw of ['plan_changed', 'step_disabled', 'step_not_failed', 'fix_rounds_exhausted']) await expect(feedback()).not.toContainText(raw);
	// The refusals changed nothing: the step is still failed and can be retried.
	await expect(stepState('Tester')).toHaveText('Fehlgeschlagen');
	await expect(retry('Tester')).toBeEnabled();
});

test('the retry button works with the keyboard and announces the result', async () => {
	await open(tasks.races);
	await expect(retry('Tester')).toBeEnabled();
	await retry('Tester').focus();
	await expect(retry('Tester')).toBeFocused();
	expect((await retriesSent(() => page.keyboard.press('Enter'))).count).toBe(1);
	await expect(stepState('Tester')).toHaveText('Offen');
	await expect(feedback()).toHaveAttribute('aria-live', 'polite');
	await expect(feedback()).toContainText('wiederholt');
	await expect(feedback()).toBeFocused();
});

for (const [label, size] of [['desktop', { width: 1280, height: 900 }], ['mobile', { width: 390, height: 844 }]] as const) {
	test(`${label}: light and dark screenshots without horizontal scrolling`, async () => {
		test.skip(!shoots(), 'the pictures come from the Chromium run');
		await page.setViewportSize(size);
		if ((await read(tasks.shot)).plan == null) await failedTester(tasks.shot);
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			const name = scheme === 'light' ? 'hell' : 'dunkel';
			for (const [file, id] of [['wiederholen', tasks.shot], ['aus', tasks.off], ['rollen', tasks.roles]] as const) {
				await open(id);
				await noOverflow(`${label} ${scheme} ${file}`);
				await page.waitForTimeout(300);
				await page.screenshot({ path: `${SHOTS}/karte-${file}-${label}-${name}.png` });
			}
			await open(tasks.zero);
			await page.waitForTimeout(300);
			await page.screenshot({ path: `${SHOTS}/karte-erschoepft-${label}-${name}.png` });
		}
		await page.emulateMedia({ colorScheme: 'light' });
	});
}
