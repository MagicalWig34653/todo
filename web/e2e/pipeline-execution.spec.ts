import { expect, request, test, type APIRequestContext, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/pipeline-execution.spec.ts --project=chromium   (also --project=firefox / webkit)
// Card F5DD1C00 (pipeline stage 3, docs/PLAN-PIPELINE-STUFE-3.md sections 2 to 4 and 6): the owner starts the pipeline of a card on a
// runner, watches it step by step, continues or stops it. The runner is played by this spec through the real runner API (pairing
// code, jobs?pipeline=1, claim, progress, hold, submit); the browser checks what a person sees and does, without reloading.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/pipeline-stufe-3');
test.describe.configure({ mode: 'serial' });
let page: Page;
let runner: APIRequestContext;
let deviceID = '';
let secondDeviceID = '';
const json = { headers: { 'Content-Type': 'application/json' } };
const STEPS = ['Planer', 'Freigabe', 'Entwickler', 'Validierung', 'Tester', 'Review'];
const LIVE = { timeout: 20_000 };
const HOLD = 'Kontingent-Bremse: Wochenkontingent zu 92 % verbraucht, Ampel rot. Nächste Prüfung in 15 Minuten.';

interface Card {
	project: string;
	task: string;
	binding: string;
}
interface Pipeline {
	plan?: { version: number; state: string } | null;
	steps: { step: string; state: string }[];
	execution?: { id: string; state: string; reason?: string | null; step?: string | null; jobState?: string | null } | null;
}
interface Job {
	id: string;
	taskID: string;
	state: string;
	pipelineStep?: string;
}
interface Run {
	id: string;
	generation: number;
	job: Job;
}

async function call<T>(method: 'post' | 'put' | 'patch', path: string, data: unknown, on: Page = page): Promise<T> {
	const r = await on.request[method](path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const read = async (id: string) => (await (await page.request.get(`/v1/tasks/${id}/pipeline`)).json()) as Pipeline;
const writePlan = (id: string) => call<Pipeline>('put', `/v1/tasks/${id}/plan`, { body: '## Ziel\nFormular mit Prüfung bauen.\n\n1. Felder anlegen\n2. Prüfung schreiben', agentName: 'claude-code' });
const approve = (id: string, version = 1) => call<Pipeline>('post', `/v1/tasks/${id}/plan/decision`, { decision: 'approve', version });

/** Pairs a runner device the way `todo-runner pair` does: the code is redeemed without any session. */
async function pairDevice(label: string): Promise<{ deviceID: string; token: string }> {
	const pairing = await call<{ deviceID: string; code: string }>('post', '/v1/agents/devices', { label });
	const r = await runner.post('/v1/runner/pair', { ...json, data: { code: pairing.code } });
	expect(r.ok(), await r.text()).toBeTruthy();
	return { deviceID: pairing.deviceID, token: ((await r.json()) as { token: string }).token };
}
/** The token of the runner that works in this spec. */
let runnerToken = '';
const auth = () => ({ headers: { Authorization: `Bearer ${runnerToken}`, 'Content-Type': 'application/json' } });
async function runnerPost<T>(path: string, data: unknown = {}): Promise<T> {
	const r = await runner.post(path, { ...auth(), data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const queued = async () => (await (await runner.get('/v1/runner/jobs?pipeline=1', auth())).json()) as Job[];
async function jobFor(card: Card, step: string): Promise<Job> {
	await expect.poll(async () => (await queued()).find((j) => j.taskID === card.task)?.pipelineStep ?? 'none', LIVE).toBe(step);
	return (await queued()).find((j) => j.taskID === card.task)!;
}
const claim = async (card: Card, step: string) => runnerPost<Run>(`/v1/runner/jobs/${(await jobFor(card, step)).id}/claim?pipeline=1`);
const progress = (run: Run, text: string) => runnerPost<Run>(`/v1/runner/runs/${run.id}/progress`, { generation: run.generation, progress: text });
const submit = (run: Run, outcome: 'passed' | 'failed', summary: string, plan?: string) =>
	runnerPost<Run>(`/v1/runner/runs/${run.id}/submit`, { generation: run.generation, outcome, plan, result: { summary, references: [], checks: [], limitations: [] } });
const work = async (card: Card, step: string, outcome: 'passed' | 'failed' = 'passed', summary = `${step} fertig`) => submit(await claim(card, step), outcome, summary);
const hold = async (card: Card, step: string, reason: string) => runnerPost<Job>(`/v1/runner/jobs/${(await jobFor(card, step)).id}/hold`, { reason });

/** A card in its own project, bound to the runner with its own repository slot. */
async function card(projectName: string, title: string, plan = true): Promise<Card> {
	const project = (await call<{ id: string }>('post', '/v1/projects', { name: projectName })).id;
	const binding = (await call<{ id: string }>('post', '/v1/agents/bindings', { projectID: project, deviceID, repositoryKey: crypto.randomUUID(), label: 'formular-repo' })).id;
	const task = (await call<{ id: string }>('post', '/v1/tasks', { projectID: project, title, description: 'Das Formular prüft seine Eingaben.' })).id;
	if (plan) {
		await writePlan(task);
		await approve(task);
	}
	return { project, task, binding };
}
const startApi = (c: Card) => call<Pipeline>('post', `/v1/tasks/${c.task}/pipeline/execution`, { id: crypto.randomUUID(), bindingID: c.binding });
const rename = async (c: Card, title: string) => {
	const tasks = (await (await page.request.get(`/v1/tasks?projectID=${c.project}`)).json()) as { id: string; version: number }[];
	return call('patch', `/v1/tasks/${c.task}`, { version: tasks.find((t) => t.id === c.task)!.version, title });
};
/** The runner finds the card changed when it claims: the execution pauses. */
async function pauseByChange(c: Card, step = 'developer') {
	const job = await jobFor(c, step);
	await rename(c, 'Formular mit neuem Titel');
	const refused = await runner.post(`/v1/runner/jobs/${job.id}/claim?pipeline=1`, { ...auth(), data: {} });
	expect(refused.status(), await refused.text()).toBe(409);
	expect(await refused.text()).toContain('task_changed');
}

const dialog = (on: Page = page) => on.getByTestId('card-dialog');
const panel = (on: Page = page) => dialog(on).getByRole('tabpanel');
const section = (on: Page = page) => panel(on).getByTestId('pipeline-execution');
const state = (on: Page = page) => panel(on).getByTestId('pipeline-execution-state');
const hint = (on: Page = page) => panel(on).getByTestId('pipeline-execution-hint');
const execFeedback = () => panel().getByTestId('pipeline-execution-feedback');
const startButton = (on: Page = page) => panel(on).getByTestId('pipeline-execution-start-button');
const stopButton = (on: Page = page) => section(on).getByRole('button', { name: 'Stoppen', exact: true });
const continueButton = (on: Page = page) => panel(on).getByTestId('pipeline-execution-continue');
const step = (name: string, on: Page = page) => panel(on).getByTestId('pipeline-step').nth(STEPS.indexOf(name));
const stepState = (name: string) => step(name).getByTestId('pipeline-step-state');
const liveLine = (name: string) => step(name).getByTestId('pipeline-step-live');
const retry = (name: string, on: Page = page) => step(name, on).getByRole('button', { name: 'Wiederholen', exact: true });

/** Opens the Pipeline tab and waits until the card and its pipeline are loaded. */
async function open(c: Card, on: Page = page) {
	await on.goto(`/for-you?card=task:${c.task}&tab=pipeline`);
	await expect(dialog(on)).toBeVisible();
	await expect(panel(on).getByTestId('pipeline-step').first().or(panel(on).getByTestId('tab-empty'))).toBeVisible();
}
/** Bodies of the execution requests the browser sends while `action` runs. */
async function sent(suffix: string, action: () => Promise<unknown>): Promise<unknown[]> {
	const bodies: unknown[] = [];
	const listener = (r: { url(): string; method(): string; postData(): string | null }) => {
		if (r.method() === 'POST' && r.url().endsWith(suffix)) bodies.push(JSON.parse(r.postData() ?? '{}'));
	};
	page.on('request', listener);
	await action();
	await page.waitForTimeout(500);
	page.off('request', listener);
	return bodies;
}
const noOverflow = async (label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
	const inner = await dialog().getByTestId('card-scroll').evaluate((el) => el.scrollWidth - el.clientWidth);
	expect(inner, `${label}: card scroll area overflows`).toBeLessThanOrEqual(0);
};

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Ausführung Tester');
	const use = test.info().project.use;
	runner = await request.newContext({ baseURL: use.baseURL, ignoreHTTPSErrors: use.ignoreHTTPSErrors ?? false });
	({ deviceID, token: runnerToken } = await pairDevice('Mac Studio'));
	secondDeviceID = (await pairDevice('MacBook im Büro')).deviceID;
});
test.afterAll(async () => {
	await runner?.dispose();
	await page?.context().close();
});

test('without a runner binding the tab looks like before', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	const project = (await call<{ id: string }>('post', '/v1/projects', { name: 'Ohne Runner' })).id;
	const task = (await call<{ id: string }>('post', '/v1/tasks', { projectID: project, title: 'Karte ohne Runner' })).id;
	await writePlan(task);
	await open({ project, task, binding: '' });
	await expect(panel().getByTestId('pipeline-plan')).toBeVisible();
	await expect(section()).toHaveCount(0);
});

let main: Card;
test('start: choose the binding, one request, the running step is marked; an unknown runner gets a hint', async () => {
	main = await card('Ausführung', 'Formular bauen');
	await call('post', '/v1/agents/bindings', { projectID: main.project, deviceID: secondDeviceID, repositoryKey: crypto.randomUUID(), label: 'zweiter-ordner' });
	await open(main);
	await expect(section()).toHaveAttribute('data-state', 'none');
	const choice = section().getByLabel('Gerät und Ordner');
	await expect(choice.locator('option')).toHaveCount(2);
	await choice.selectOption({ label: 'Mac Studio · formular-repo' });
	const bodies = await sent('/pipeline/execution', () => startButton().dblclick());
	expect(bodies).toHaveLength(1);
	expect(bodies[0]).toMatchObject({ bindingID: main.binding });
	await expect(state()).toHaveText('Läuft');
	await expect(execFeedback()).toHaveText('Pipeline gestartet.');
	await expect(execFeedback()).toBeFocused();
	await expect(panel().getByTestId('pipeline-execution-step')).toHaveText('Entwickler');
	await expect(panel().getByTestId('pipeline-execution-device')).toHaveText('Mac Studio · formular-repo');
	await expect(panel().getByTestId('pipeline-execution-job')).toHaveText('Wartet');
	await expect(liveLine('Entwickler')).toHaveText('Wartet auf den Runner');
	await expect(step('Entwickler')).toHaveAttribute('aria-current', 'step');
	await expect(panel().getByTestId('pipeline-step-live')).toHaveCount(1);
	await expect(panel().getByTestId('pipeline-execution-unsupported')).toContainText('todo-runner');
	await expect(startButton()).toHaveCount(0);
	await expect(stopButton()).toBeVisible();
});

test('budget hold, claim and progress show up without reloading', async () => {
	await hold(main, 'developer', HOLD);
	await expect(panel().getByTestId('pipeline-execution-hold')).toHaveText(HOLD, LIVE);
	await expect(liveLine('Entwickler')).toContainText('Kontingent-Bremse');
	await expect(step('Entwickler')).toHaveAttribute('data-live', 'warning');
	const run = await claim(main, 'developer');
	await expect(panel().getByTestId('pipeline-execution-hold')).toHaveCount(0, LIVE);
	await expect(stepState('Entwickler')).toHaveText('Läuft', LIVE);
	await progress(run, 'Felder angelegt, Prüfung folgt');
	await expect(panel().getByTestId('pipeline-execution-job')).toHaveText('Läuft', LIVE);
	await expect(panel().getByTestId('pipeline-execution-progress')).toHaveText('Felder angelegt, Prüfung folgt');
	await expect(liveLine('Entwickler')).toHaveText('Läuft auf dem Runner: Felder angelegt, Prüfung folgt');
	await expect(step('Entwickler')).toHaveAttribute('data-live', 'running');
	await expect(panel().getByTestId('pipeline-execution-unsupported')).toHaveCount(0);
	await submit(run, 'passed', 'Felder und Prüfung stehen');
	await expect(stepState('Entwickler')).toHaveText('Fertig', LIVE);
	await expect(liveLine('Validierung')).toHaveText('Wartet auf den Runner', LIVE);
	await expect(execFeedback()).toHaveText('');
});

test('a failed step blocks; "Wiederholen" says that it runs again, and the run finishes in a review', async () => {
	await work(main, 'validation');
	await work(main, 'tester', 'failed', '2 Tests rot');
	await expect(state()).toHaveText('Blockiert', LIVE);
	await expect(hint()).toContainText('Der Schritt „Tester“ ist fehlgeschlagen');
	await expect(panel().getByTestId('pipeline-execution-rounds')).toContainText('0 von');
	await expect(panel().getByTestId('pipeline-step-live')).toHaveCount(0);
	await expect(step('Tester')).toContainText('2 Tests rot');
	await expect(step('Tester').getByTestId('pipeline-step-retry-hint')).toContainText('erneut auf dem Runner');
	await retry('Tester').click();
	await expect(state()).toHaveText('Läuft');
	await expect(panel().getByTestId('pipeline-feedback')).toContainText('läuft erneut');
	await expect(liveLine('Tester')).toHaveText('Wartet auf den Runner');
	await work(main, 'tester');
	await work(main, 'review');
	await expect(state()).toHaveText('Abgeschlossen', LIVE);
	await expect(hint()).toContainText('wartet im Review', LIVE);
	await expect(panel().getByTestId('pipeline-step-live')).toHaveCount(0);
	await expect(stopButton()).toHaveCount(0);
	await expect(startButton()).toHaveCount(0);
	const history = panel().getByTestId('pipeline-history');
	await history.locator('summary').click();
	await expect(history).toContainText('Ausführung gestartet');
	await expect(history).toContainText('Ausführung abgeschlossen');
	await expect(history).toContainText('Runner');
	await panel().getByTestId('pipeline-execution-review').click();
	await expect(dialog().getByTestId('card-tab-overview')).toHaveAttribute('aria-selected', 'true');
	await expect(dialog().getByTestId('card-tab-overview')).toBeFocused();
	await expect(dialog().getByTestId('card-decide')).toBeVisible();
	await dialog().getByTestId('card-tab-activity').click();
	await expect(dialog().getByTestId('card-activity-all')).toContainText('Pipeline-Ausführung geändert');
});

test('the planner writes the plan, the approval continues the execution', async () => {
	const c = await card('Planung', 'Erst planen', false);
	await open(c);
	await expect(panel().getByTestId('tab-empty')).toBeVisible();
	await startButton().click();
	await expect(state()).toHaveText('Läuft');
	await expect(liveLine('Planer')).toHaveText('Wartet auf den Runner');
	await submit(await claim(c, 'planner'), 'passed', 'Plan geschrieben', '1. Lesen\n2. Bauen');
	await expect(state()).toHaveText('Wartet auf Freigabe', LIVE);
	await expect(hint()).toContainText('automatisch weiter');
	await expect(panel().getByTestId('pipeline-plan-body')).toContainText('Lesen');
	await expect(panel().getByTestId('pipeline-step-live')).toHaveCount(0);
	await panel().getByRole('button', { name: 'Plan freigeben', exact: true }).click();
	await expect(state()).toHaveText('Läuft', LIVE);
	await expect(liveLine('Entwickler')).toHaveText('Wartet auf den Runner', LIVE);
});

test('a changed card pauses; "Fortsetzen" sends the plan version', async () => {
	const c = await card('Pause', 'Titel ändert sich');
	await startApi(c);
	await open(c);
	await expect(state()).toHaveText('Läuft');
	await pauseByChange(c);
	await expect(state()).toHaveText('Angehalten', LIVE);
	await expect(hint()).toContainText('Titel oder Beschreibung');
	const bodies = await sent('/pipeline/execution/continue', () => continueButton().click());
	expect(bodies).toEqual([{ planVersion: 1 }]);
	await expect(state()).toHaveText('Läuft');
	await expect(execFeedback()).toHaveText('Ausführung fortgesetzt.');
	await expect(liveLine('Entwickler')).toHaveText('Wartet auf den Runner');
});

test('"Stoppen" ends a running execution with the keyboard, and it can be started again', async () => {
	const c = await card('Stopp', 'Wird gestoppt');
	await startApi(c);
	await open(c);
	const run = await claim(c, 'developer');
	await progress(run, 'Arbeitet');
	await expect(liveLine('Entwickler')).toContainText('Arbeitet', LIVE);
	await stopButton().focus();
	expect(await sent('/pipeline/execution/stop', () => page.keyboard.press('Enter'))).toHaveLength(1);
	await expect(state()).toHaveText('Gestoppt');
	await expect(execFeedback()).toHaveText('Ausführung gestoppt.');
	await expect(execFeedback()).toBeFocused();
	await expect(stepState('Entwickler')).toHaveText('Offen');
	await expect(panel().getByTestId('pipeline-step-live')).toHaveCount(0);
	await expect(stopButton()).toHaveCount(0);
	// The runner confirms that its process ended, which frees the repository slot.
	const runs = (await (await runner.get('/v1/runner/runs', auth())).json()) as Run[];
	const current = runs.find((r) => r.id === run.id);
	if (current) await runnerPost(`/v1/runner/runs/${run.id}/reconcile`, { generation: current.generation, observation: 'stopped' });
	await startButton().click();
	await expect(state()).toHaveText('Läuft');
	await expect(liveLine('Entwickler')).toHaveText('Wartet auf den Runner');
});

test('a person who may edit sees the state, can mark a retry, but only the owner continues', async ({ browser }) => {
	const c = await card('Geteilt', 'Gemeinsame Karte');
	await startApi(c);
	await work(c, 'developer', 'failed', 'Baut nicht');
	const { token } = await call<{ token: string }>('post', '/v1/invitations', {});
	const guest = await signedInPage(browser, 'Gast mit Bearbeitungsrecht', token);
	try {
		const { id } = (await (await guest.request.get('/v1/me')).json()) as { id: string };
		await call('put', `/v1/projects/${c.project}/grants`, { principalType: 'user', principalID: id, role: 'edit' });
		await open(c, guest);
		await expect(state(guest)).toHaveText('Blockiert');
		await expect(startButton(guest)).toHaveCount(0);
		await expect(stopButton(guest)).toHaveCount(0);
		await expect(step('Entwickler', guest).getByTestId('pipeline-step-retry-hint')).toContainText('Projekteigentümer');
		await retry('Entwickler', guest).click();
		await expect(state(guest)).toHaveText('Angehalten');
		await expect(panel(guest).getByTestId('pipeline-feedback')).toContainText('muss fortgesetzt werden');
		await expect(panel(guest).getByTestId('pipeline-execution-owner-only')).toBeVisible();
		await expect(continueButton(guest)).toHaveCount(0);
	} finally {
		await guest.context().close();
	}
	await open(c);
	await expect(hint()).toContainText('zum Wiederholen vorgemerkt');
	await continueButton().click();
	await expect(state()).toHaveText('Läuft');
});

test('screenshots: every state, light and dark, wide and narrow, without horizontal scrolling', async () => {
	test.skip(test.info().project.name !== 'chromium', 'the pictures come from the Chromium run');
	test.setTimeout(240_000);
	const start = await card('Bildprojekt Start', 'Formular für die Anmeldung bauen');
	const running = await card('Bildprojekt Lauf', 'Formular für die Anmeldung bauen');
	await startApi(running);
	const run = await claim(running, 'developer');
	await progress(run, 'Eingabefelder angelegt, schreibe jetzt die Prüfung der E-Mail-Adresse in Sources/Formular/Anmeldung/EingabePruefungMitSehrLangemDateinamen.swift');
	const held = await card('Bildprojekt Bremse', 'Formular für die Anmeldung bauen');
	await startApi(held);
	await hold(held, 'developer', HOLD);
	const blocked = await card('Bildprojekt Block', 'Formular für die Anmeldung bauen');
	await startApi(blocked);
	await work(blocked, 'developer', 'passed', 'Felder und Prüfung stehen');
	await work(blocked, 'validation', 'failed', 'Exit-Code 1 nach 42 s');
	const paused = await card('Bildprojekt Pause', 'Formular für die Anmeldung bauen');
	await startApi(paused);
	await pauseByChange(paused);
	const completed = await card('Bildprojekt Fertig', 'Formular für die Anmeldung bauen');
	await startApi(completed);
	for (const name of ['developer', 'validation', 'tester', 'review']) await work(completed, name);
	expect((await read(completed.task)).execution?.state).toBe('completed');

	const states = [
		['start', start, 'none'],
		['laeuft', running, 'running'],
		['bremse', held, 'running'],
		['blockiert', blocked, 'blocked'],
		['angehalten', paused, 'paused'],
		['fertig', completed, 'completed']
	] as const;
	for (const [label, size] of [['desktop', { width: 1280, height: 1000 }], ['mobile', { width: 390, height: 1100 }]] as const) {
		await page.setViewportSize(size);
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			for (const [file, c, expected] of states) {
				await open(c);
				await expect(section()).toHaveAttribute('data-state', expected);
				await noOverflow(`${label} ${scheme} ${file}`);
				await section().evaluate((el) => el.scrollIntoView({ block: 'start' }));
				await page.waitForTimeout(300);
				await page.screenshot({ path: `${SHOTS}/${file}-${label}-${scheme === 'light' ? 'hell' : 'dunkel'}.png` });
			}
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
});
