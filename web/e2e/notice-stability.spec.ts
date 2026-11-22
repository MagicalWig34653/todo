import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Card 188D611F: a notice about a failed action (for example the dependency cycle) must survive a background reload of the task list.
// Cause of the flake: the loaders of an open task detail (labels, criteria, attachments, activity, comments, milestone) reran when the
// list was reloaded, because their effect read `task.id` through the `task` object, and every `attempt()` clears the global notice.
// Needs a fresh backend database. Run on its own:  npx playwright test e2e/notice-stability.spec.ts --project=chromium   (also firefox, webkit)
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };
let page: Page;
let ids = { project: '', a: '', b: '' };

test('setup: project with two tasks, list view, detail of the first task open', async ({ browser }) => {
	test.setTimeout(90_000);
	page = await signedInPage(browser, 'Meldung Stabil');
	const project = (await (await page.request.post('/v1/projects', { ...json, data: { name: 'Meldungen' } })).json()) as { id: string };
	const mk = async (title: string) => ((await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title } })).json()) as { id: string }).id;
	ids = { project: project.id, a: await mk('Aufgabe Eins'), b: await mk('Aufgabe Zwei') };
	await page.setViewportSize({ width: 1280, height: 900 });
	await page.goto(`/project/${project.id}`);
	await page.getByTestId('display-menu').click();
	await page.getByRole('dialog', { name: 'Anzeige' }).getByRole('button', { name: 'Liste' }).click();
	await page.keyboard.press('Escape');
	const task = page.getByTestId('task-item').filter({ hasText: 'Aufgabe Eins' });
	await task.getByRole('button', { name: 'Details' }).click();
	await expect(task.getByTestId('task-detail')).toBeVisible();
});

test('a reload of the task list does not rerun the loaders of the open detail', async () => {
	const task = page.getByTestId('task-item').filter({ hasText: 'Aufgabe Eins' });
	await expect(task.getByTestId('task-detail')).toBeVisible();
	await page.waitForTimeout(1500);
	// Only the effect loaders (`attempt(load)`) ask for the label catalogue; the quiet live refresh asks for the task's own labels.
	let catalogue = 0;
	page.on('request', (r) => {
		if (r.method() === 'GET' && new URL(r.url()).pathname === '/v1/labels') catalogue++;
	});
	// Another client renames the second task: the list changes, the live refresh replaces the task objects.
	const fresh = (await (await page.request.get(`/v1/tasks?projectID=${ids.project}`)).json()) as { id: string; version: number }[];
	const b = fresh.find((t) => t.id === ids.b)!;
	expect((await page.request.patch(`/v1/tasks/${ids.b}`, { ...json, data: { version: b.version, title: 'Aufgabe Zwei neu' } })).ok()).toBeTruthy();
	await expect(page.getByTestId('task-item').filter({ hasText: 'Aufgabe Zwei neu' })).toBeVisible({ timeout: 20_000 });
	await page.waitForTimeout(1500);
	expect(catalogue, 'label catalogue requested again by a loader of the open detail').toBe(0);
});
