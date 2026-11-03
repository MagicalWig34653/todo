import { expect, test, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/task-graph.spec.ts --project=chromium
// Optional: E2E_EDGE_SHIM=1 answers GET /v1/planning/dependencies from the per-task endpoints, for a backend binary
// built before that route existed. Screenshots go to E2E_SHOTS (default /private/tmp/claude-501/task-graph).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.E2E_SHOTS ?? '/private/tmp/claude-501/task-graph';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
let ids = { project: '', child: '', a: '', b: '', c: '', d: '', e: '', sub: '' };

async function send<T>(method: 'post' | 'put' | 'patch', path: string, data: unknown): Promise<T> {
	const r = await page.request[method](path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return r.status() === 204 ? (undefined as T) : ((await r.json()) as T);
}
const node = (id: string) => page.locator(`[data-testid="graph-node"][data-node="${id}"]`);
const noOverflow = async () => expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	mkdirSync(SHOTS, { recursive: true });
	page = await (await browser.newContext()).newPage();
	if (process.env.E2E_EDGE_SHIM) {
		await page.route('**/v1/planning/dependencies?*', async (route) => {
			const url = new URL(route.request().url());
			const root = url.searchParams.get('projectID')!;
			const sub = url.searchParams.get('includeSubprojects') === 'true';
			const projects = [root, ...(sub ? [ids.child] : [])];
			const tasks = (await Promise.all(projects.map(async (p) => (await (await page.request.get(`/v1/tasks?projectID=${p}`)).json()) as { id: string }[]))).flat();
			const edges: { taskID: string; prerequisiteID: string }[] = [];
			for (const t of tasks) for (const p of (await (await page.request.get(`/v1/planning/tasks/${t.id}/dependencies`)).json()) as { id: string }[]) edges.push({ taskID: t.id, prerequisiteID: p.id });
			const kinds = await Promise.all(tasks.map(async (t) => ({ taskID: t.id, kind: (await (await page.request.get(`/v1/tasks/${t.id}/context`)).json()).workflow.kind as string, updatedAt: new Date().toISOString() })));
			await route.fulfill({ json: { edges, tasks: kinds } });
		});
	}
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Graph Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();

	const project = await send<{ id: string }>('post', '/v1/projects', { name: 'Graphprojekt' });
	const child = await send<{ id: string }>('post', '/v1/projects', { name: 'Unterprojekt', parentID: project.id });
	const mk = (projectID: string, title: string) => send<{ id: string }>('post', '/v1/tasks', { projectID, title });
	const a = await mk(project.id, 'Fundament');
	const b = await mk(project.id, 'Login bauen');
	const c = await mk(project.id, 'Dashboard bauen');
	const d = await mk(project.id, 'Release vorbereiten');
	const e = await mk(project.id, 'Teilschritt');
	const sub = await mk(child.id, 'Unteraufgabe');
	await send('patch', `/v1/tasks/${a.id}`, { version: 1, status: 'done' });
	await send('put', `/v1/tasks/${b.id}/structure`, { kind: 'feature' });
	await send('put', `/v1/tasks/${e.id}/structure`, { kind: 'task', parentTaskID: b.id });
	await send('put', `/v1/planning/tasks/${b.id}/dependencies`, { prerequisiteID: a.id });
	await send('put', `/v1/planning/tasks/${c.id}/dependencies`, { prerequisiteID: b.id });
	await send('put', `/v1/planning/tasks/${d.id}/dependencies`, { prerequisiteID: c.id });
	await send('put', `/v1/planning/tasks/${d.id}`, { dueAt: '2020-01-01T10:00:00Z', priority: 0, reminders: [] });
	const past = await send<{ id: string }>('post', '/v1/planning/milestones', { projectID: project.id, title: 'Version 1.0', dueAt: '2026-01-15T10:00:00Z' });
	const next = await send<{ id: string }>('post', '/v1/planning/milestones', { projectID: project.id, title: 'Version 2.0', dueAt: '2099-01-15T10:00:00Z' });
	await send('put', `/v1/planning/milestones/${past.id}/tasks/${a.id}`, {});
	await send('put', `/v1/planning/milestones/${next.id}/tasks/${c.id}`, {});
	ids = { project: project.id, child: child.id, a: a.id, b: b.id, c: c.id, d: d.id, e: e.id, sub: sub.id };
});
test.afterAll(async () => {
	await page?.context().close();
});

test('the view switcher opens the graph and the URL is shareable', async () => {
	await page.goto(`/project/${ids.project}`);
	await page.getByTestId('display-menu').click();
	await page.getByTestId('view-graph').click();
	await expect(page.getByTestId('task-graph')).toBeVisible();
	await expect(page).toHaveURL(new RegExp(`/project/${ids.project}/graph$`));
	await page.reload();
	await expect(page.getByTestId('graph-node')).toHaveCount(5);
});

test('waiting is visible: blocked task names what it waits for, the predecessor is marked, milestones are markers', async () => {
	await page.goto(`/project/${ids.project}/graph`);
	await expect(page.getByTestId('graph-node')).toHaveCount(5);
	await expect(node(ids.c)).toHaveAttribute('data-blocked', 'true');
	await expect(node(ids.c)).toContainText('wartet auf Login bauen');
	await expect(node(ids.b)).toHaveAttribute('data-blocked', 'false');
	await expect(node(ids.b)).toContainText('blockiert andere');
	await expect(node(ids.a)).toHaveAttribute('data-status', 'done');
	await expect(node(ids.d)).toHaveAttribute('data-overdue', 'true');
	await expect(node(ids.d)).toContainText('überfällig');
	// Newest on top: the dependent sits above what it waits for.
	const top = async (id: string) => (await node(id).boundingBox())!.y;
	expect(await top(ids.d)).toBeLessThan(await top(ids.c));
	expect(await top(ids.c)).toBeLessThan(await top(ids.b));
	expect(await top(ids.b)).toBeLessThan(await top(ids.a));
	// Blocking edges are drawn dashed.
	await expect(page.locator(`[data-edge="${ids.c}>${ids.b}"]`)).toHaveAttribute('data-blocking', 'true');
	await expect(page.locator(`[data-edge="${ids.b}>${ids.a}"]`)).toHaveAttribute('data-blocking', 'false');
	// Releases are tags in the row of the task they ship with; the "now" line separates open from done work.
	await expect(node(ids.a).getByTestId('graph-tag')).toContainText('Version 1.0');
	await expect(node(ids.a).getByTestId('graph-tag')).toHaveAttribute('data-state', 'released');
	await expect(node(ids.c).getByTestId('graph-tag')).toContainText('Version 2.0');
	await expect(node(ids.c).getByTestId('graph-tag')).toHaveAttribute('data-state', 'planned');
	const now = (await page.getByTestId('graph-now').boundingBox())!.y;
	expect(now).toBeGreaterThan(await top(ids.d));
	expect(now).toBeLessThan(await top(ids.a));
	// The feature branches its subtask and merges: a sub edge, a merge point (plus) and a feature badge.
	await expect(page.locator(`[data-edge="${ids.b}>${ids.e}"]`)).toHaveAttribute('data-kind', 'sub');
	await expect(node(ids.b).getByTestId('graph-badge-feature')).toBeVisible();
	await expect(node(ids.a)).toContainText(/[0-9a-f]{7}/);
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.screenshot({ path: `${SHOTS}/graph-desktop-light.png` });
	await page.emulateMedia({ colorScheme: 'dark' });
	await page.screenshot({ path: `${SHOTS}/graph-desktop-dark.png` });
	await page.emulateMedia({ colorScheme: 'light' });
});

test('clicking a node opens the large card; arrow keys move between nodes', async () => {
	await page.goto(`/project/${ids.project}/graph`);
	await node(ids.b).focus();
	await page.keyboard.press('ArrowUp');
	await expect(page.locator(':focus')).toHaveAttribute('data-node', /./);
	await node(ids.c).click();
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	await expect(page.getByTestId('card-dialog').getByRole('textbox', { name: 'Titel der Aufgabe' })).toHaveValue('Dashboard bauen');
	await expect(page).toHaveURL(new RegExp(`card=task:${ids.c}`));
});

test('filters: only features, hide old done tasks, sub-projects', async () => {
	await page.goto(`/project/${ids.project}/graph`);
	await expect(page.getByTestId('graph-node')).toHaveCount(5);
	await page.getByTestId('graph-sub').click();
	await expect(page.getByTestId('graph-node')).toHaveCount(6);
	await expect(node(ids.sub)).toBeVisible();
	await page.getByTestId('graph-sub').click();
	await expect(page.getByTestId('graph-node')).toHaveCount(5);
	await page.getByTestId('graph-features').click();
	await expect(page.getByTestId('graph-node')).toHaveCount(1);
	await expect(node(ids.b)).toBeVisible();
	await page.getByTestId('graph-features').click();
	// The done task was finished just now: a 7 day filter keeps it, "never" keeps it too.
	await page.getByTestId('graph-hide-done').selectOption('7');
	await expect(page.getByTestId('graph-node')).toHaveCount(5);
});

test('390 px: graph scrolls inside its frame, the page does not overflow', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto(`/project/${ids.project}/graph`);
	await expect(page.getByTestId('graph-node')).toHaveCount(5);
	await noOverflow();
	await page.screenshot({ path: `${SHOTS}/graph-390.png` });
	await page.setViewportSize({ width: 320, height: 640 });
	await noOverflow();
	await page.screenshot({ path: `${SHOTS}/graph-320.png` });
	// 200 % text: rows scale with the root font size and stay clickable.
	await page.evaluate(() => (document.documentElement.style.fontSize = '32px'));
	await expect(page.getByTestId('graph-node')).toHaveCount(5);
	// The app header itself is wider than 320 px at 200 % (not part of this view); the graph frame must still fit.
	const frameFits = await page.evaluate(() => document.querySelector('[data-testid="graph-scroll"]')!.getBoundingClientRect().right <= window.innerWidth + 1);
	expect(frameFits).toBe(true);
	await page.screenshot({ path: `${SHOTS}/graph-320-font200.png` });
});
