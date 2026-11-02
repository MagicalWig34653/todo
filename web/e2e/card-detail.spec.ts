import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/card-detail.spec.ts --project=chromium
// Covers the large card detail window: question, review, task/progress/screenshots and confirmation cards.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const ORIGIN = process.env.E2E_BASE_URL ?? 'http://localhost:25173';
const SHOTS = '/private/tmp/claude-501/card-detail';
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
	await expect(dialog().getByTestId('task-detail')).toBeVisible();
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
