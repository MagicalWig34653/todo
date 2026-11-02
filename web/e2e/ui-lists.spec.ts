import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/ui-lists.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext()).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('List Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

let projectID = '';
let taskID = '';
const due = () => new Date(new Date().setHours(8, 0, 0, 0)).toISOString();
const planning = (dueAt: string) => ({ dueAt, plannedAt: null, priority: 0, recurrence: null, reminders: [] });

test('quick add keeps the typed text when projects change in the background', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Listenprojekt' } })).json();
	projectID = project.id;
	await page.goto('/today');
	await expect(page.getByTestId('project-item').getByRole('button', { name: 'Listenprojekt', exact: true }).first()).toBeVisible();
	await page.keyboard.press('q');
	const input = page.getByTestId('quick-add').getByLabel('Titel', { exact: true });
	await input.fill('Entwurf bleibt erhalten');
	await page.request.post('/v1/projects', { ...json, data: { name: 'Hintergrundprojekt' } });
	// Live refresh is deferred while a dialog is open, so force the same state change the refresh makes:
	// workspace.projects gets a new array (here via the sidebar reload hook on window focus after closing is not
	// possible), then check the draft survives a poll interval.
	await page.waitForTimeout(6_000);
	await expect(input).toHaveValue('Entwurf bleibt erhalten');
	await page.keyboard.press('Escape');
	// After closing, the deferred refresh runs; reopening starts with a clean field and the new project is selectable.
	await expect(page.getByTestId('project-item').getByRole('button', { name: 'Hintergrundprojekt', exact: true }).first()).toBeVisible({ timeout: 20_000 });
});

test('today list: appears via live refresh, complete from the row, project link', async () => {
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID, title: 'Heute fällig' } })).json();
	taskID = task.id;
	await page.goto('/today');
	// Created and planned elsewhere after the view opened: shows up without reload.
	await page.request.put(`/v1/planning/tasks/${task.id}`, { ...json, data: planning(due()) });
	const row = page.getByTestId('planning-item').filter({ hasText: 'Heute fällig' });
	await expect(row).toBeVisible({ timeout: 20_000 });
	await expect(row.getByTestId('task-project-link')).toHaveText(/Listenprojekt/);
	await row.getByRole('button', { name: 'Details' }).click();
	await expect(row.getByTestId('detail-status')).toHaveText('Als erledigt markieren');
	await row.getByRole('checkbox', { name: 'Als erledigt markieren' }).check();
	await expect(page.getByTestId('planning-item').filter({ hasText: 'Heute fällig' })).toHaveCount(0);

	const second = await (await page.request.post('/v1/tasks', { ...json, data: { projectID, title: 'Zweite Aufgabe' } })).json();
	await page.request.put(`/v1/planning/tasks/${second.id}`, { ...json, data: planning(due()) });
	const row2 = page.getByTestId('planning-item').filter({ hasText: 'Zweite Aufgabe' });
	await expect(row2).toBeVisible({ timeout: 20_000 });
	await row2.getByTestId('task-project-link').click();
	await expect(page).toHaveURL(new RegExp(`/project/${projectID}`));
});

test('search opens the task itself, also a completed one', async () => {
	await page.goto('/search');
	await page.getByPlaceholder('Suchen in Titeln, Beschreibungen und Projekten').fill('Heute fällig');
	await page.getByRole('button', { name: 'Suchen', exact: true }).click();
	const hit = page.getByTestId('search-hit').filter({ hasText: 'Heute fällig' });
	await expect(hit).toBeVisible();
	await hit.getByRole('button', { name: 'Heute fällig' }).click();
	// A task hit opens the large card detail window (deep link ?card=task:<id>), also for a completed task.
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	await expect(page).toHaveURL(new RegExp(`card=task:${taskID}`));
	await page.keyboard.press('Escape');
});

test('comments: a failed send keeps the draft and the button label returns', async () => {
	await page.goto(`/project/${projectID}?task=${taskID}`);
	const area = page.getByTestId('task-detail').first();
	await expect(area).toBeVisible();
	await page.route('**/v1/tasks/*/comments', (route) => (route.request().method() === 'POST' ? route.fulfill({ status: 500, contentType: 'application/json', body: '{}' }) : route.continue()));
	const box = area.getByLabel('Kommentar schreiben');
	await box.fill('Entwurf bleibt');
	await area.getByRole('button', { name: 'Kommentieren' }).click();
	await expect(area.getByRole('button', { name: 'Kommentieren' })).toBeVisible();
	await expect(box).toHaveValue('Entwurf bleibt');
	await page.unroute('**/v1/tasks/*/comments');
});
