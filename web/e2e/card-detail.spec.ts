import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/card-detail.spec.ts --project=chromium
// Covers the large card detail window: question, review, task/progress/screenshots and confirmation cards.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const ORIGIN = process.env.E2E_BASE_URL ?? 'http://localhost:25173';
const SHOTS = '/private/tmp/claude-501/card-detail2';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const PNG_1X1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const LONG_END = 'ENDE-DER-LANGEN-FRAGE';
const LONG_PROMPT = `${'Soll die Detailansicht wirklich jede Karte groß öffnen und dabei alles zeigen, ohne dass etwas abgeschnitten wird? '.repeat(14)}${LONG_END}`;
const DESC_END = 'ENDE-DER-BESCHREIBUNG';
const LONG_DESC = `${'Ausführliche Beschreibung der Aufgabe mit viel Text, damit nichts abgeschnitten werden darf. '.repeat(25)}${DESC_END}`;

let ids = { project: '', task: '', reviewTask: '', questionTask: '', focusTask: '' };
let access = '';

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
async function mcp(name: string, args: Record<string, unknown>) {
	const r = await page.request.post('/mcp', {
		headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
		data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }
	});
	const body = await r.json();
	return { isError: body.result.isError as boolean, text: body.result.content[0].text as string };
}
const dialog = () => page.getByTestId('card-dialog');
const backdrop = () => page.locator('[data-large]');
const noOverflow = async (label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
};

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	mkdirSync(SHOTS, { recursive: true });
	page = await (await browser.newContext()).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Karten Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();

	const project = await post<{ id: string }>('/v1/projects', { name: 'Kartenprojekt' });
	const mk = (title: string, description?: string) => post<{ id: string }>('/v1/tasks', { projectID: project.id, title, description });
	const task = await mk('Detailaufgabe', LONG_DESC);
	const reviewTask = await mk('Reviewaufgabe');
	const questionTask = await mk('Frageaufgabe');
	const focusTask = await mk('Fokusaufgabe');
	ids = { project: project.id, task: task.id, reviewTask: reviewTask.id, questionTask: questionTask.id, focusTask: focusTask.id };

	await post(`/v1/tasks/${task.id}/claim`, { agentName: 'Claude Code' });
	await post(`/v1/tasks/${task.id}/progress-notes`, { note: 'Erster Schritt erledigt', percent: 30 });
	await post(`/v1/tasks/${task.id}/progress-notes`, { note: 'Zweiter Schritt läuft', percent: 60 });
	for (const [i, name] of ['eins.png', 'zwei.png'].entries()) {
		const sha = createHash('sha256').update(PNG_1X1).digest('hex');
		const cap = await post<{ attachmentID: string; uploadURL: string; token: string }>('/v1/attachments/begin', {
			taskID: task.id, filename: name, role: 'result', mediaType: 'image/png', size: PNG_1X1.length, checksum: sha
		});
		const status = await page.evaluate(async ({ cap, png }) => {
			const r = await fetch(cap.uploadURL, { method: 'PUT', credentials: 'omit', headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` }, body: new Uint8Array(png) });
			return r.status;
		}, { cap, png: Array.from(PNG_1X1) });
		expect(status).toBeLessThan(300);
		await post(`/v1/attachments/${cap.attachmentID}/complete`, {});
		await post('/v1/builds', { attachmentID: cap.attachmentID, buildID: `build-${i}`, label: `Screenshot ${i + 1}`, platform: 'web' });
	}
	await post(`/v1/tasks/${questionTask.id}/questions`, { prompt: LONG_PROMPT, options: ['Ja, alles zeigen', 'Nein'], blocking: true, agentName: 'Claude Code' });
	await post(`/v1/tasks/${focusTask.id}/questions`, { prompt: 'Fokusfrage ohne Optionen?', agentName: 'Claude Code' });
	await post(`/v1/tasks/${reviewTask.id}/review`, { summary: 'Ergebnis ist fertig.\n- Neu: Detailfenster\n- Geprüft: 262 Tests\n- Ansehen: Blur im Dunkelmodus', agentName: 'Claude Code' });
});
test.afterAll(async () => {
	await page?.context().close();
});

test('question: opens big with blurred backdrop, full text, answer inside the window, deep link and back button', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/for-you');
	const card = page.getByTestId('needs-card').filter({ hasText: 'ENDE-DER-LANGEN-FRAGE' });
	await expect(card).toBeVisible();
	await card.locator('button[aria-labelledby^="need-t-"]').click();

	await expect(dialog()).toBeVisible();
	await expect(page).toHaveURL(/\/for-you\?card=question:[A-Za-z0-9-]+$/);
	const filter = await backdrop().evaluate((el) => getComputedStyle(el).backdropFilter);
	expect(filter).toContain('blur');
	// Full text, nothing cut off: the end marker is rendered and the prompt element is not clipped.
	const prompt = dialog().getByTestId('question-prompt');
	await expect(prompt).toContainText(LONG_END);
	expect(await prompt.evaluate((el) => el.scrollHeight - el.clientHeight)).toBeLessThanOrEqual(1);
	// The page behind is inert.
	expect(await page.evaluate(() => Array.from(document.body.children).some((c) => c.hasAttribute('inert')))).toBe(true);
	await expect(dialog().getByTestId('card-type')).toHaveText('Frage');
	await expect(dialog().getByTestId('card-project')).toContainText('Kartenprojekt');
	await page.screenshot({ path: `${SHOTS}/question-light.png` });

	// Reload opens the same card; back closes it.
	await page.reload();
	await expect(dialog()).toBeVisible();
	await expect(dialog().getByTestId('question-prompt')).toContainText(LONG_END);
	await page.goBack();
	await expect(dialog()).toHaveCount(0);
	await page.goForward();
	await expect(dialog()).toBeVisible();

	// Answering inside the window.
	await dialog().getByRole('button', { name: 'Ja, alles zeigen' }).click();
	await expect(dialog().getByTestId('question-answered')).toHaveText('Ja, alles zeigen');
	await dialog().getByRole('button', { name: 'Schließen' }).click();
	await expect(dialog()).toHaveCount(0);
	await expect(page).toHaveURL(/\/for-you$/);
	await expect(card).toHaveCount(0);
});

test('keyboard: Enter opens, Escape closes and focus returns to the card; actions on the card do not open the window', async () => {
	await page.goto('/for-you');
	const card = page.getByTestId('needs-card').filter({ hasText: 'Fokusfrage ohne Optionen?' });
	const trigger = card.locator('button[aria-labelledby^="need-t-"]');
	await trigger.focus();
	await page.keyboard.press('Enter');
	await expect(dialog()).toBeVisible();
	await expect(dialog().locator(':focus')).toHaveCount(1);
	await page.keyboard.press('Escape');
	await expect(dialog()).toHaveCount(0);
	await expect(trigger).toBeFocused();
	// Typing an answer on the card itself leaves the window closed.
	await card.getByPlaceholder(/Antwort/).fill('kurz');
	await expect(dialog()).toHaveCount(0);
});

test('review: summary as bullets, decision needs a note for changes, accept shows the result', async () => {
	await page.goto('/for-you');
	const card = page.getByTestId('needs-card').filter({ hasText: 'Reviewaufgabe' });
	await card.locator('button[aria-labelledby^="need-t-"]').click();
	await expect(page).toHaveURL(/card=review:/);
	const summary = dialog().getByTestId('review-summary');
	await expect(summary.locator('li')).toHaveCount(3);
	await expect(summary).toContainText('Blur im Dunkelmodus');
	await dialog().getByTestId('review-changes').click();
	await expect(dialog().getByRole('alert')).toBeVisible();
	await dialog().getByTestId('review-accept').click();
	await expect(dialog().getByTestId('card-review-result')).toContainText('Review angenommen');
	await page.keyboard.press('Escape');
	await expect(dialog()).toHaveCount(0);
});

test('task from a progress post: description, timeline, gallery, conversation, link to the task', async () => {
	await page.goto('/for-you');
	const post = page.getByTestId('post-card').filter({ hasText: 'Zweiter Schritt läuft' });
	await post.locator('button[aria-labelledby^="post-t-"]').click();
	await expect(page).toHaveURL(/card=task:/);
	await expect(dialog().getByTestId('card-description')).toContainText(DESC_END);
	await expect(dialog().getByTestId('detail-notes')).toContainText('Erster Schritt erledigt');
	await expect(dialog().getByTestId('detail-notes')).toContainText('Zweiter Schritt läuft');
	await expect(dialog().getByTestId('card-conversation')).toBeVisible();
	const gallery = dialog().getByTestId('card-gallery');
	await expect(gallery).toBeVisible();
	const first = await gallery.getByTestId('gallery-image').getAttribute('alt');
	await gallery.getByTestId('gallery-next').click();
	expect(await gallery.getByTestId('gallery-image').getAttribute('alt')).not.toBe(first);
	await gallery.getByTestId('gallery-prev').click();
	expect(await gallery.getByTestId('gallery-image').getAttribute('alt')).toBe(first);
	await expect(dialog().getByTestId('card-side')).toBeVisible();
	await dialog().getByTestId('card-open-task').click();
	await expect(dialog()).toHaveCount(0);
	await expect(page).toHaveURL(new RegExp(`/project/${ids.project}(/list)?\\?task=${ids.task}$`));
});

test('board and list: a task card opens the same window', async () => {
	await page.goto(`/project/${ids.project}/board`);
	await page.getByRole('button', { name: 'Detailaufgabe', exact: true }).first().click();
	await expect(dialog()).toBeVisible();
	await expect(page).toHaveURL(/card=task:/);
	await expect(dialog().getByTestId('card-type')).toHaveText('Aufgabe');
	await page.keyboard.press('Escape');
	await expect(dialog()).toHaveCount(0);
	await page.goto(`/project/${ids.project}/list`);
	await page.getByTestId('task-open-large').first().click();
	await expect(dialog()).toBeVisible();
	await page.keyboard.press('Escape');
});

test('confirmation: scope shown, name guard, reject', async () => {
	const doomed = await post<{ id: string }>('/v1/projects', { name: 'Löschprojekt' });
	await post('/v1/tasks', { projectID: doomed.id, title: 'Weg damit' });
	const reg = await page.request.post('/oauth/register', { ...json, data: { client_name: 'Test-Agent', redirect_uris: ['https://client.example/cb'], token_endpoint_auth_method: 'none' } });
	const clientID = ((await reg.json()) as { client_id: string }).client_id;
	const verifier = randomBytes(40).toString('hex');
	const challenge = createHash('sha256').update(verifier).digest('base64url');
	const authorize = await page.request.get('/oauth/authorize', {
		params: {
			response_type: 'code', client_id: clientID, redirect_uri: 'https://client.example/cb', scope: 'projects:read projects:write tasks:read tasks:write',
			state: 's', resource: `${ORIGIN}/mcp`, code_challenge: challenge, code_challenge_method: 'S256'
		}
	});
	const consentToken = ((await authorize.json()) as { consent_token: string }).consent_token;
	const consent = await page.request.post('/oauth/consent', { ...json, data: { consent_token: consentToken, approve: true, project_ids: [doomed.id] } });
	const code = new URL(((await consent.json()) as { redirect_uri: string }).redirect_uri).searchParams.get('code');
	const token = await page.request.post('/oauth/token', {
		...json, data: { grant_type: 'authorization_code', client_id: clientID, resource: `${ORIGIN}/mcp`, code, redirect_uri: 'https://client.example/cb', code_verifier: verifier }
	});
	access = ((await token.json()) as { access_token: string }).access_token;
	const asked = await mcp('delete_project', { projectID: doomed.id });
	expect(JSON.parse(asked.text).error).toBe('confirmation_required');

	await page.goto('/for-you');
	const card = page.getByTestId('confirm-card').filter({ hasText: 'Löschprojekt' });
	await card.locator('button[aria-labelledby^="confirm-t-"]').click();
	await expect(page).toHaveURL(/card=confirmation:/);
	await expect(dialog().getByTestId('card-type')).toHaveText('Bestätigung');
	await expect(dialog().getByTestId('confirm-scope')).toContainText('Löschprojekt');
	await dialog().getByRole('button', { name: 'Bestätigen', exact: true }).click();
	await expect(dialog().getByTestId('confirm-run')).toBeDisabled();
	await dialog().getByTestId('confirm-name').fill('Löschprojekt');
	await expect(dialog().getByTestId('confirm-run')).toBeEnabled();
	await dialog().getByRole('button', { name: 'Zurück', exact: true }).click();
	await dialog().getByRole('button', { name: 'Ablehnen', exact: true }).click();
	await expect(dialog().getByTestId('confirm-outcome')).toContainText('Abgelehnt');
	const names = ((await (await page.request.get('/v1/projects')).json()) as { name: string }[]).map((p) => p.name);
	expect(names).toContain('Löschprojekt');
});

test('invalid and unknown cards show a friendly message', async () => {
	await page.goto('/for-you?card=unsinn');
	await expect(dialog().getByTestId('card-invalid')).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(dialog()).toHaveCount(0);
	await page.goto('/for-you?card=task:00000000-0000-0000-0000-000000000000');
	await expect(dialog().getByTestId('card-error')).toContainText('nicht mehr');
});

test('320 px: full-screen sheet without horizontal overflow; light and dark screenshots', async () => {
	await page.setViewportSize({ width: 320, height: 700 });
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await page.goto(`/for-you?card=task:${ids.task}`);
		await expect(dialog()).toBeVisible();
		await expect(dialog().getByTestId('card-description')).toContainText(DESC_END);
		const box = await dialog().boundingBox();
		expect(box!.width).toBeLessThanOrEqual(320);
		expect(box!.width).toBeGreaterThanOrEqual(318);
		expect(box!.height).toBeGreaterThanOrEqual(690);
		await noOverflow('320');
		const inner = await dialog().getByTestId('card-scroll').evaluate((el) => el.scrollWidth - el.clientWidth);
		expect(inner).toBeLessThanOrEqual(0);
		await page.screenshot({ path: `${SHOTS}/task-320-${scheme}.png` });
	}
	await page.setViewportSize({ width: 1280, height: 800 });
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await page.goto(`/for-you?card=task:${ids.task}`);
		await expect(dialog()).toBeVisible();
		await page.screenshot({ path: `${SHOTS}/task-desktop-${scheme}.png` });
	}
});


test.describe('layout of the card window', () => {
	let nav: { project: string; a: string; b: string; c: string } = { project: '', a: '', b: '', c: '' };
	test.beforeAll(async () => {
		const parent = await post<{ id: string }>('/v1/projects', { name: 'Elternprojekt' });
		const project = await post<{ id: string }>('/v1/projects', { name: 'Unterprojekt', parentID: parent.id });
		const mk = (title: string) => post<{ id: string }>('/v1/tasks', { projectID: project.id, title });
		const [a, b, c] = [await mk('Nav A'), await mk('Nav B'), await mk('Nav C')];
		nav = { project: project.id, a: a.id, b: b.id, c: c.id };
		await post('/v1/labels', { name: 'Wichtig' });
	});

	test('1280 px: two columns, sidebar on the right with its blocks, breadcrumb link', async () => {
		await page.emulateMedia({ colorScheme: 'light' });
		await page.setViewportSize({ width: 1280, height: 800 });
		await page.goto(`/project/${nav.project}/list?card=task:${nav.b}`);
		await expect(dialog()).toBeVisible();
		const main = await dialog().getByTestId('card-main').boundingBox();
		const side = await dialog().getByTestId('card-side').boundingBox();
		expect(side!.x).toBeGreaterThan(main!.x + main!.width - 2);
		expect(side!.width).toBeGreaterThanOrEqual(260);
		expect(side!.width).toBeLessThanOrEqual(330);
		for (const id of ['side-project', 'side-date', 'side-priority', 'side-labels', 'side-reminders', 'side-recurrence']) await expect(dialog().getByTestId(id)).toBeVisible();
		await expect(dialog().getByTestId('card-breadcrumb')).toContainText('Elternprojekt');
		await expect(dialog().getByTestId('card-breadcrumb')).toContainText('Unterprojekt');
		await expect(dialog().getByTestId('card-title')).toHaveValue('Nav B');
		await page.screenshot({ path: `${SHOTS}/layout-desktop-light.png` });
		await page.emulateMedia({ colorScheme: 'dark' });
		await page.screenshot({ path: `${SHOTS}/layout-desktop-dark.png` });
		await page.emulateMedia({ colorScheme: 'light' });
		await dialog().getByTestId('card-project').click();
		await expect(dialog()).toHaveCount(0);
		await expect(page).toHaveURL(new RegExp(`/project/${nav.project}`));
	});

	test('priority, date, label and reminder from the sidebar save', async () => {
		await page.goto(`/project/${nav.project}/list?card=task:${nav.a}`);
		await expect(dialog()).toBeVisible();
		await dialog().getByTestId('side-priority-select').selectOption('3');
		await dialog().getByTestId('side-date-add').click();
		await dialog().getByLabel('Fällig').fill('2030-05-06T09:00');
		await expect(dialog().getByTestId('side-due')).toContainText('2030');
		await dialog().getByTestId('side-labels-add').click();
		await dialog().getByLabel('Label hinzufügen').selectOption({ label: 'Wichtig' });
		await expect(dialog().getByTestId('task-label')).toContainText('Wichtig');
		await dialog().getByTestId('side-reminders-add').click();
		await dialog().getByLabel('Neue Erinnerung').fill('2030-05-05T08:00');
		const saved = page.waitForResponse((r) => r.request().method() === 'PUT' && r.url().includes('/planning'));
		await dialog().getByRole('button', { name: 'Erinnerung hinzufügen', exact: true }).last().click();
		expect((await saved).status()).toBeLessThan(300);
		await expect(dialog().getByTestId('reminder')).toHaveCount(1);
		await page.reload();
		await expect(dialog().getByTestId('side-priority-select')).toHaveValue('3');
		await expect(dialog().getByTestId('side-due')).toContainText('2030');
		await expect(dialog().getByTestId('reminder')).toHaveCount(1);
		await expect(dialog().getByTestId('task-label')).toContainText('Wichtig');
	});

	test('up/down steps through the list, ends are disabled; checkbox completes; comment field sends', async () => {
		await page.goto(`/project/${nav.project}/board`);
		await expect(page.getByTestId('board-card').filter({ hasText: /Nav [ABC]/ })).toHaveCount(3);
		const order = (await page.getByTestId('board-card').filter({ hasText: /Nav [ABC]/ }).allInnerTexts()).map((x) => x.match(/Nav [ABC]/)![0]);
		expect(order.length).toBe(3);
		await page.getByRole('button', { name: order[0], exact: true }).first().click();
		await expect(dialog().getByTestId('card-title')).toHaveValue(order[0]);
		await expect(dialog().getByTestId('card-prev')).toBeDisabled();
		await dialog().getByTestId('card-next').click();
		await expect(dialog().getByTestId('card-title')).toHaveValue(order[1]);
		await dialog().getByTestId('card-next').click();
		await expect(dialog().getByTestId('card-title')).toHaveValue(order[2]);
		await expect(dialog().getByTestId('card-next')).toBeDisabled();
		await dialog().getByTestId('card-prev').click();
		await expect(dialog().getByTestId('card-title')).toHaveValue(order[1]);
		await expect(page).toHaveURL(/card=task:/);

		const box = dialog().getByLabel('Kommentar schreiben');
		await box.fill('Hallo aus dem Fenster');
		await box.press('Enter');
		await expect(dialog().getByTestId('comment')).toContainText('Hallo aus dem Fenster');

		await dialog().getByTestId('card-done').click();
		await expect(dialog().getByTestId('card-done')).toHaveAttribute('aria-checked', 'true');
		await dialog().getByTestId('card-done').click();
		await expect(dialog().getByTestId('card-done')).toHaveAttribute('aria-checked', 'false');
	});

	test('title and description edit inline; subtask can be added', async () => {
		await page.goto(`/project/${nav.project}/list?card=task:${nav.c}`);
		const title = dialog().getByTestId('card-title');
		await title.fill('Nav C neu');
		await title.press('Enter');
		await expect(title).toHaveValue('Nav C neu');
		await dialog().getByTestId('card-description-view').click();
		await dialog().getByTestId('card-description-input').fill('Text **fett**');
		await dialog().getByTestId('card-description-input').press('Control+Enter');
		await expect(dialog().getByTestId('card-description')).toContainText('fett');
		await dialog().getByTestId('card-subtask-add').click();
		await dialog().getByLabel('Titel der Unteraufgabe').fill('Teil 1');
		await dialog().getByLabel('Titel der Unteraufgabe').press('Enter');
		await expect(dialog().getByTestId('card-subtask')).toContainText('Teil 1');
		await page.reload();
		await expect(dialog().getByTestId('card-title')).toHaveValue('Nav C neu');
	});

	test('390 px: one column with the sidebar below, no overflow; question and review use the same frame', async () => {
		await page.setViewportSize({ width: 390, height: 800 });
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			await page.goto(`/for-you?card=task:${ids.task}`);
			await expect(dialog()).toBeVisible();
			const main = await dialog().getByTestId('card-main').boundingBox();
			const side = await dialog().getByTestId('card-side').boundingBox();
			expect(side!.y).toBeGreaterThanOrEqual(main!.y + main!.height - 2);
			expect(side!.width).toBeLessThanOrEqual(390);
			await noOverflow('390');
			expect(await dialog().getByTestId('card-scroll').evaluate((el) => el.scrollWidth - el.clientWidth)).toBeLessThanOrEqual(0);
			await expect(dialog().getByTestId('card-header')).toBeInViewport();
			await page.screenshot({ path: `${SHOTS}/layout-390-${scheme}.png` });
		}
		await page.emulateMedia({ colorScheme: 'light' });
		await page.goto(`/for-you?card=task:${ids.reviewTask}`);
		await expect(dialog().getByTestId('card-header')).toBeVisible();
		await expect(dialog().getByTestId('card-side')).toBeVisible();
		await page.goto(`/for-you`);
		const q = page.getByTestId('needs-card').filter({ hasText: 'Fokusfrage ohne Optionen?' });
		await q.locator('button[aria-labelledby^="need-t-"]').click();
		await expect(dialog().getByTestId('card-type')).toHaveText('Frage');
		await expect(dialog().getByTestId('card-crumb-task')).toContainText('Fokusaufgabe');
		await dialog().getByTestId('card-next').click();
		await noOverflow('390 question');
		await page.setViewportSize({ width: 1280, height: 800 });
	});
});

// Chat per card: people and agents write into the chat of a task, a question and a review.
async function connectAgent(projectID: string, scope: string): Promise<string> {
	const reg = await page.request.post('/oauth/register', { ...json, data: { client_name: 'Chat-Agent', redirect_uris: ['https://client.example/cb'], token_endpoint_auth_method: 'none' } });
	const clientID = ((await reg.json()) as { client_id: string }).client_id;
	const verifier = randomBytes(40).toString('hex');
	const challenge = createHash('sha256').update(verifier).digest('base64url');
	const authorize = await page.request.get('/oauth/authorize', {
		params: { response_type: 'code', client_id: clientID, redirect_uri: 'https://client.example/cb', scope, state: 's', resource: `${ORIGIN}/mcp`, code_challenge: challenge, code_challenge_method: 'S256' }
	});
	const consentToken = ((await authorize.json()) as { consent_token: string }).consent_token;
	const consent = await page.request.post('/oauth/consent', { ...json, data: { consent_token: consentToken, approve: true, project_ids: [projectID] } });
	const code = new URL(((await consent.json()) as { redirect_uri: string }).redirect_uri).searchParams.get('code');
	const token = await page.request.post('/oauth/token', {
		...json, data: { grant_type: 'authorization_code', client_id: clientID, resource: `${ORIGIN}/mcp`, code, redirect_uri: 'https://client.example/cb', code_verifier: verifier }
	});
	return ((await token.json()) as { access_token: string }).access_token;
}

test('chat: bubbles by author, agent reply arrives live, draft survives, question and review have their own chat', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	const saved = access;
	access = await connectAgent(ids.project, 'projects:read tasks:read tasks:write comments:write');
	try {
		await page.goto(`/for-you?card=task:${ids.focusTask}`);
		await expect(dialog().getByTestId('card-header')).toBeVisible();
		const task = dialog().locator('[data-testid="card-conversation"][data-thread="task"]');
		const field = task.getByLabel('Kommentar schreiben');
		await field.fill('Erste Zeile');
		await field.press('Shift+Enter');
		await field.pressSequentially('Zweite Zeile');
		await field.press('Control+Enter');
		const mine = task.locator('[data-testid="comment"][data-mine="true"]');
		await expect(mine).toHaveCount(1);
		await expect(mine).toContainText('Zweite Zeile');
		await expect(mine.getByTestId('comment-author')).toHaveText('Du');
		await expect(mine.getByTestId('comment-time')).toHaveText('gerade eben');

		// An agent answers through MCP; a half-written draft in the field is not touched by the live refresh.
		await field.fill('Noch nicht abgeschickt');
		const reply = await mcp('add_comment', { taskID: ids.focusTask, body: 'Verstanden, ich mache weiter.', agentName: 'claude-code@chat' });
		expect(reply.isError, reply.text).toBe(false);
		const agent = task.locator('[data-testid="comment"][data-author-kind="agent"]');
		await expect(agent).toHaveCount(1, { timeout: 15_000 });
		await expect(agent.getByTestId('comment-author')).toHaveText('claude-code@chat');
		await expect(agent).toContainText('Verstanden, ich mache weiter.');
		await expect(field).toHaveValue('Noch nicht abgeschickt');
		await field.fill('');

		// The question card has its own chat, separate from the task chat.
		await page.goto('/for-you');
		const q = page.getByTestId('needs-card').filter({ hasText: 'Fokusfrage ohne Optionen?' });
		await q.locator('button[aria-labelledby^="need-t-"]').click();
		const qChat = dialog().locator('[data-testid="card-conversation"][data-thread="question"]');
		await expect(qChat).toBeVisible();
		await expect(qChat.getByTestId('comment')).toHaveCount(0);
		await qChat.getByLabel('Kommentar schreiben').fill('Was meinst du genau?');
		await qChat.getByLabel('Kommentar schreiben').press('Enter');
		await expect(qChat.getByTestId('comment')).toHaveCount(1);
		const questionID = new URL(page.url()).searchParams.get('card')!.split(':')[1];
		const answer = await mcp('add_comment', { taskID: ids.focusTask, body: 'Die Frage betrifft die Reihenfolge.', questionID, agentName: 'claude-code@chat' });
		expect(answer.isError, answer.text).toBe(false);
		await expect(qChat.locator('[data-author-kind="agent"]')).toHaveCount(1, { timeout: 15_000 });
		const listed = await mcp('list_comments', { taskID: ids.focusTask, questionID, authorKind: 'person' });
		expect(JSON.parse(listed.text).map((c: { body: string }) => c.body)).toEqual(['Was meinst du genau?']);
		await page.screenshot({ path: `${SHOTS}/chat-question.png` });

		// Review card.
		await page.goto(`/for-you?card=task:${ids.reviewTask}`);
		const rChat = dialog().locator('[data-testid="card-conversation"][data-thread="review"]');
		await expect(rChat).toBeVisible();
		await rChat.getByLabel('Kommentar schreiben').fill('Bitte noch den Dunkelmodus zeigen');
		await rChat.getByTestId('comment-send').click();
		await expect(rChat.getByTestId('comment')).toHaveCount(1);
		await expect(dialog().locator('[data-testid="card-conversation"][data-thread="task"]').getByTestId('comment')).toHaveCount(0);
		await page.screenshot({ path: `${SHOTS}/chat-review.png` });
	} finally {
		access = saved;
	}
});
