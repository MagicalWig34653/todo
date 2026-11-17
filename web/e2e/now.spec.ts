import { expect, test, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';

// Page "Jetzt" (GET /v1/overview/now). Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/now.spec.ts --project=chromium
// Screenshots go to $NOW_SHOTS (default docs/screenshots/jetzt).
// The API cannot backdate activity or age a heartbeat, so the "quiet" project and the orphaned session are produced by
// rewriting the overview response in the browser (the rest of the data is real).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.NOW_SHOTS ?? '../docs/screenshots/jetzt';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const ids = { alpha: '', quiet: '', running: '', question: '', review: '', quietReview: '' };
let rewrite = true;

async function api<T>(method: 'post' | 'patch' | 'put' | 'get', path: string, data?: unknown): Promise<T> {
	const r = await page.request[method](path, method === 'get' ? undefined : { ...json, data });
	expect(r.status(), `${method} ${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const project = (name: string) => page.locator('[data-testid="now-project"]').filter({ has: page.locator('[data-testid="now-project-name"]', { hasText: name }) });
const summaryOf = (name: string) => project(name).locator('summary');

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'de-DE', timezoneId: 'Europe/Berlin' })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Jetzt Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();

	const alpha = await api<{ id: string }>('post', '/v1/projects', { name: 'Todolino Jetzt' });
	const quiet = await api<{ id: string }>('post', '/v1/projects', { name: 'Formular Ruhig' });
	ids.alpha = alpha.id;
	ids.quiet = quiet.id;
	const mk = async (projectID: string, title: string) => (await api<{ id: string }>('post', '/v1/tasks', { projectID, title })).id;
	ids.running = await mk(alpha.id, 'Passkey-Anmeldung absichern');
	ids.question = await mk(alpha.id, 'Runner-Bindings');
	ids.review = await mk(alpha.id, 'Kalender Schedule-API');
	ids.quietReview = await mk(quiet.id, 'Rate-Limit je Mandant');
	await api('post', `/v1/tasks/${ids.running}/claim`, { agentName: 'Claude Sonnet' });
	await api('post', `/v1/tasks/${ids.running}/progress-notes`, { note: 'Fallback geschrieben, Tests laufen', percent: 60 });
	await api('post', `/v1/tasks/${ids.question}/questions`, { prompt: 'Soll der Runner pausieren?', blocking: false });
	await api('post', `/v1/tasks/${ids.review}/review`, { summary: 'Kalender Stufe A fertig' });
	await api('post', `/v1/tasks/${ids.quietReview}/review`, { summary: 'Rate-Limit fertig' });
	await api('put', `/v1/projects/${alpha.id}/session-status`, { sessionName: 'web-passkey', activity: 'Führt vitest aus' });
	await api('put', `/v1/projects/${alpha.id}/session-status`, { sessionName: 'backend-oauth', activity: 'Migration prüfen' });

	await page.route('**/v1/overview/now', async (route) => {
		const res = await route.fetch();
		if (!rewrite || res.status() !== 200) return route.fulfill({ response: res });
		const body = await res.json();
		for (const p of body.projects) {
			if (p.projectID === ids.quiet) p.lastActivityAt = new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString();
			for (const s of p.sessions) if (s.sessionName === 'backend-oauth') Object.assign(s, { orphaned: true, ageSeconds: 47 * 60, updatedAt: new Date(Date.now() - 47 * 60000).toISOString() });
		}
		await route.fulfill({ response: res, json: body });
	});
	await page.goto('/now');
	await expect(page.getByTestId('now-view')).toBeVisible();
	await expect(project('Todolino Jetzt')).toBeVisible();
});

test('shows header, live badge, stand time and the active project expanded', async () => {
	await expect(page.getByTestId('view-heading')).toHaveText('Jetzt');
	await expect(page.getByTestId('now-live')).toContainText('Live');
	await expect(page.getByTestId('now-asof')).toContainText('Stand');
	await expect(page).toHaveTitle(/Jetzt/);
	await expect(page.getByRole('link', { name: 'Jetzt' }).or(page.getByRole('button', { name: 'Jetzt' })).first()).toBeVisible();
	const row = project('Todolino Jetzt');
	await expect(row).toHaveJSProperty('open', true);
	await expect(summaryOf('Todolino Jetzt').getByTestId('now-stat-running')).toHaveText('1 läuft');
	await expect(summaryOf('Todolino Jetzt').getByTestId('now-stat-sessions')).toHaveText('2 Sessions');
	await expect(summaryOf('Todolino Jetzt').getByTestId('now-stat-waiting')).toHaveText('2 warten auf dich');
});

test('running card shows worker, note, age and short id; sessions show orphaned state in words', async () => {
	const row = project('Todolino Jetzt');
	const item = row.getByTestId('now-running-item');
	await expect(item).toContainText('Passkey-Anmeldung absichern');
	await expect(item).toContainText('Claude Sonnet');
	await expect(item).toContainText('Fallback geschrieben, Tests laufen');
	await expect(item).toContainText('gerade eben');
	await expect(item.getByTestId('id-chip')).toContainText(ids.running.slice(0, 8).toUpperCase());
	await expect(row.locator('[data-testid="now-session"][data-orphaned="true"]')).toContainText('verwaist');
	await expect(row.locator('[data-testid="now-session"][data-orphaned="true"]')).toContainText('Keine Meldung seit über 30 Min.');
	await expect(row.locator('[data-testid="now-session"][data-orphaned="false"]')).toContainText('aktiv');
	await expect(row.getByTestId('now-events')).toContainText('Fortschritt gemeldet');
	await expect(row.getByTestId('now-builds')).toHaveCount(0); // empty sections are omitted
});

test('waiting items open the card detail', async () => {
	const row = project('Todolino Jetzt');
	await expect(row.getByTestId('now-waiting-item')).toHaveCount(2);
	await row.getByRole('button', { name: 'Antworten' }).click();
	await expect(page.getByRole('dialog')).toContainText('Soll der Runner pausieren?');
	await page.keyboard.press('Escape');
	await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('quiet projects are grouped, collapsed, and the expand state survives a reload', async () => {
	await expect(page.getByTestId('now-quiet-heading')).toHaveText('Ruhig (1 Projekt ohne Aktivität in den letzten 24 Std.)');
	const quiet = project('Formular Ruhig');
	await expect(quiet).toHaveJSProperty('open', false);
	await expect(page.getByTestId('now-quiet').locator('[data-testid="now-project"]')).toHaveCount(1);
	// Keyboard: Tab onto the summary, Enter opens it.
	await summaryOf('Formular Ruhig').focus();
	await page.keyboard.press('Enter');
	await expect(quiet).toHaveJSProperty('open', true);
	await expect(quiet.getByTestId('now-waiting-item')).toContainText('Rate-Limit fertig');
	await summaryOf('Todolino Jetzt').click();
	await expect(project('Todolino Jetzt')).toHaveJSProperty('open', false);
	await page.reload();
	await expect(project('Formular Ruhig')).toHaveJSProperty('open', true);
	await expect(project('Todolino Jetzt')).toHaveJSProperty('open', false);
	const stored = await page.evaluate(() => localStorage.getItem('todo.nowExpanded'));
	expect(JSON.parse(stored ?? '{}')).toEqual({ [ids.quiet]: true, [ids.alpha]: false });
	await summaryOf('Todolino Jetzt').click();
	await summaryOf('Formular Ruhig').click();
	await expect(project('Todolino Jetzt')).toHaveJSProperty('open', true);
	await expect(project('Formular Ruhig')).toHaveJSProperty('open', false);
});

test('updates live when an agent reports something new', async () => {
	await api('post', `/v1/tasks/${ids.running}/progress-notes`, { note: 'Neuer Zwischenstand live', percent: 80 });
	await expect(project('Todolino Jetzt').getByTestId('now-running-item')).toContainText('Neuer Zwischenstand live', { timeout: 15_000 });
});

test('screenshots desktop and mobile (light)', async () => {
	mkdirSync(SHOTS, { recursive: true });
	await page.goto('/now');
	await summaryOf('Formular Ruhig').click();
	await expect(project('Formular Ruhig')).toHaveJSProperty('open', true);
	await page.screenshot({ path: `${SHOTS}/jetzt-desktop.png`, fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/now');
	await expect(project('Todolino Jetzt')).toBeVisible();
	await page.screenshot({ path: `${SHOTS}/jetzt-mobil.png`, fullPage: true });
	await page.setViewportSize({ width: 1280, height: 900 });
});

test('empty state and error state are announced in words', async () => {
	await page.route('**/v1/overview/now', (route) => route.fulfill({ json: { serverTime: new Date().toISOString(), projects: [] } }), { times: 1 });
	await page.goto('/now');
	await expect(page.getByTestId('now-empty')).toContainText('Gerade passiert nichts');
	await page.unroute('**/v1/overview/now');
	await page.route('**/v1/overview/now', (route) => route.fulfill({ status: 500, json: { reason: 'boom' } }));
	await page.goto('/now');
	await expect(page.getByTestId('now-error')).toContainText('Der Stand konnte nicht geladen werden.');
	await expect(page.getByRole('button', { name: 'Erneut versuchen' })).toBeVisible();
});
