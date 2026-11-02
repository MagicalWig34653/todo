import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/review-undo.spec.ts --project=chromium
// A review decision can be taken back for a few minutes: inside the card window and via the toast.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
let ids = { project: '', windowTask: '', toastTask: '' };

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
async function status(taskID: string): Promise<string> {
	const r = await page.request.get(`/v1/tasks/${taskID}/context`);
	return (await r.json()).task.status as string;
}
const dialog = () => page.getByTestId('card-dialog');

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext()).newPage();
	// The project overview (with inline reviews) is a management-mode feature; report every project as such.
	await page.route('**/v1/me/project-prefs*', async (route) => {
		if (route.request().method() !== 'GET') return route.continue();
		const res = await route.fetch();
		const body = await res.json();
		const fix = (p: Record<string, unknown>) => Object.assign(p, { mode: 'management' });
		if (Array.isArray(body.items)) body.items.forEach(fix);
		else fix(body);
		await route.fulfill({ response: res, json: body });
	});
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Undo Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
	const project = await post<{ id: string }>('/v1/projects', { name: 'Undoprojekt' });
	const mk = (title: string) => post<{ id: string }>('/v1/tasks', { projectID: project.id, title });
	const windowTask = await mk('Fensteraufgabe');
	const toastTask = await mk('Toastaufgabe');
	ids = { project: project.id, windowTask: windowTask.id, toastTask: toastTask.id };
	for (const id of [windowTask.id, toastTask.id]) await post(`/v1/tasks/${id}/review`, { summary: 'Fertig zum Ansehen.', agentName: 'Claude Code' });
});
test.afterAll(async () => {
	await page?.context().close();
});

test('undo inside the card window restores the pending review and the task status', async () => {
	await page.goto(`/for-you?card=task:${ids.windowTask}`);
	await expect(dialog()).toBeVisible();
	await dialog().getByTestId('review-accept').click();
	await expect(dialog().getByTestId('card-review-result')).toContainText('Review angenommen');
	await expect(dialog().getByTestId('review-undo-time')).toContainText('noch');
	expect(await status(ids.windowTask)).toBe('done');
	await dialog().getByTestId('review-undo').click();
	await expect(dialog().getByTestId('review-accept')).toBeVisible();
	await expect(dialog().getByTestId('review-undo')).toHaveCount(0);
	expect(await status(ids.windowTask)).toBe('in_review');
});

test('toast after deciding on the card offers undo', async () => {
	await page.goto(`/project/${ids.project}/overview`);
	await expect(page.getByTestId('command-center')).toHaveAttribute('data-scope', 'project');
	await page.getByTestId('cc-section-reviews').click();
	const card = page.getByTestId('cc-reviews').getByTestId('review').filter({ hasText: 'Toastaufgabe' });
	await expect(card).toBeVisible();
	await card.getByTestId('review-changes').click();
	await expect(card.getByRole('alert')).toBeVisible();
	await card.getByTestId('review-note').fill('Bitte nachbessern');
	await card.getByTestId('review-changes').click();
	const toast = page.getByTestId('review-undo-toast');
	await expect(toast).toBeVisible();
	expect(await status(ids.toastTask)).toBe('in_progress');
	await toast.getByTestId('review-undo').click();
	await expect(toast).toHaveCount(0);
	expect(await status(ids.toastTask)).toBe('in_review');
	await expect(page.getByTestId('cc-reviews').getByTestId('review').filter({ hasText: 'Toastaufgabe' })).toBeVisible();
});
