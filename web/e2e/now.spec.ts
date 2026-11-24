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
const ids = { alpha: '', quiet: '', running: '', question: '', review: '', oldReview: '', old: '' };
let rewrite = true;
/** Block `now` (contract session-status 1.4.0): the API cannot age a heartbeat, so "silent" entries are produced by rewriting the answer. */
let silentMode: 'off' | 'add' | 'move' = 'off';
const MIN = 60_000;
const block = () => page.getByTestId('now-block');

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
	const oldP = await api<{ id: string }>('post', '/v1/projects', { name: 'Altes Review' });
	ids.old = oldP.id;
	const mk = async (projectID: string, title: string) => (await api<{ id: string }>('post', '/v1/tasks', { projectID, title })).id;
	ids.running = await mk(alpha.id, 'Passkey-Anmeldung absichern');
	ids.question = await mk(alpha.id, 'Runner-Bindings');
	ids.review = await mk(alpha.id, 'Kalender Schedule-API');
	ids.oldReview = await mk(oldP.id, 'Rate-Limit je Mandant');
	await mk(quiet.id, 'Aufgeräumt');
	await api('post', `/v1/tasks/${ids.running}/claim`, { agentName: 'Claude Sonnet' });
	await api('post', `/v1/tasks/${ids.running}/progress-notes`, { note: 'Fallback geschrieben, Tests laufen', percent: 60 });
	await api('post', `/v1/tasks/${ids.question}/questions`, { prompt: 'Soll der Runner pausieren?', blocking: false });
	await api('post', `/v1/tasks/${ids.review}/review`, { summary: 'Kalender Stufe A fertig' });
	await api('post', `/v1/tasks/${ids.oldReview}/review`, { summary: 'Rate-Limit fertig' });
	await api('put', `/v1/projects/${alpha.id}/session-status`, { sessionName: 'web-passkey', activity: 'Führt vitest aus' });
	await api('put', `/v1/projects/${alpha.id}/session-status`, { sessionName: 'backend-oauth', activity: 'Migration prüfen' });

	await page.route('**/v1/overview/now', async (route) => {
		const res = await route.fetch();
		if (!rewrite || res.status() !== 200) return route.fulfill({ response: res });
		const body = await res.json();
		for (const p of body.projects) {
			if (p.projectID === ids.quiet || p.projectID === ids.old) p.lastActivityAt = new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString();
			for (const s of p.sessions) if (s.sessionName === 'backend-oauth') Object.assign(s, { orphaned: true, ageSeconds: 47 * 60, updatedAt: new Date(Date.now() - 47 * 60000).toISOString() });
		}
		if (silentMode !== 'off' && body.now) {
			const quietSign = { lastSignAt: new Date(Date.now() - 47 * MIN).toISOString(), ageSeconds: 47 * 60 };
			const extra = { kind: 'session', projectID: ids.alpha, projectName: 'Todolino Jetzt', title: 'ios-build', text: 'Wartet auf CI', worker: null, ...quietSign };
			const moved = silentMode === 'move' ? body.now.running.map((i: object) => ({ ...i, ...quietSign })) : [];
			if (silentMode === 'move') body.now.running = [];
			body.now.silent = [...moved, extra, ...body.now.silent];
			body.now.counts.running = body.now.running.length;
			body.now.counts.silent = body.now.silent.length;
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
	await expect(quiet).toContainText('nichts offen');
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

test('an old project with an open review is not quiet: it stands on top, expanded', async () => {
	const names = page.getByTestId('now-active').getByTestId('now-project-name');
	await expect(names).toHaveText(['Todolino Jetzt', 'Altes Review']);
	const old = project('Altes Review');
	await expect(old).toHaveAttribute('data-quiet', 'false');
	await expect(old).toHaveJSProperty('open', true);
	await expect(old.getByTestId('now-waiting-item')).toContainText('Rate-Limit fertig');
	await expect(page.getByTestId('now-quiet').getByText('Altes Review')).toHaveCount(0);
});

test('updates live when an agent reports something new', async () => {
	await api('post', `/v1/tasks/${ids.running}/progress-notes`, { note: 'Neuer Zwischenstand live', percent: 80 });
	await expect(project('Todolino Jetzt').getByTestId('now-running-item')).toContainText('Neuer Zwischenstand live', { timeout: 15_000 });
});

test('block "Läuft gerade": claimed card with note and reported sessions, with project, sentence and life sign', async () => {
	await page.goto('/now');
	const running = block().getByTestId('now-running');
	await expect(running.getByRole('heading', { name: /Läuft gerade/ })).toBeVisible();
	await expect(running.getByTestId('now-running-empty')).toHaveCount(0);
	const card = running.getByTestId('now-running-item').filter({ hasText: 'Passkey-Anmeldung absichern' });
	await expect(card).toHaveAttribute('data-kind', 'task');
	await expect(card).toContainText('Todolino Jetzt');
	await expect(card).toContainText('Neuer Zwischenstand live');
	await expect(card).toContainText(/seit .*Min\./);
	await expect(card).toContainText(/Lebenszeichen (gerade eben|vor .*Min\.)/);
	await expect(card.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '80');
	const ses = running.getByTestId('now-running-item').filter({ hasText: 'Führt vitest aus' });
	await expect(ses).toHaveAttribute('data-kind', 'session');
	await expect(ses).toContainText('web-passkey');
	await expect(running.getByTestId('now-running-item')).toHaveCount(3);
	// The card title opens the card detail like the project lists do.
	await card.getByRole('button', { name: 'Passkey-Anmeldung absichern' }).click();
	await expect(page.getByRole('dialog')).toContainText('Passkey-Anmeldung absichern');
	await page.keyboard.press('Escape');
	await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('block "Wartet auf dich" is separate from "Läuft gerade" and links to the card', async () => {
	const waiting = block().getByTestId('now-waiting');
	await expect(waiting.getByRole('heading', { name: /Wartet auf dich/ })).toBeVisible();
	await expect(waiting.getByTestId('now-waiting-item')).toHaveCount(3);
	await expect(waiting).toContainText('Soll der Runner pausieren?');
	await expect(waiting).toContainText('Kalender Stufe A fertig');
	await expect(waiting).toContainText('Rate-Limit fertig');
	const running = block().getByTestId('now-running');
	await expect(running).not.toContainText('Soll der Runner pausieren?');
	await expect(running).not.toContainText('Kalender Stufe A fertig');
	await expect(waiting).not.toContainText('Passkey-Anmeldung absichern');
	await waiting.getByRole('button', { name: 'Antworten' }).click();
	await expect(page.getByRole('dialog')).toContainText('Soll der Runner pausieren?');
	await page.keyboard.press('Escape');
	await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('a sentence starting with "Beendet" is shown nowhere: not in the block, not in the project sessions, not counted', async () => {
	await api('put', `/v1/projects/${ids.alpha}/session-status`, { sessionName: 'web-ende', activity: 'Beendet: alles erledigt' });
	await page.goto('/now');
	await expect(project('Todolino Jetzt')).toBeVisible();
	await expect(page.getByText('Beendet: alles erledigt')).toHaveCount(0);
	await expect(page.getByText('web-ende')).toHaveCount(0);
	await expect(summaryOf('Todolino Jetzt').getByTestId('now-stat-sessions')).toHaveText('2 Sessions');
	await expect(block().getByTestId('now-running-item')).toHaveCount(3);
});

test('block "Zuletzt fertig": cards done in the last 6 hours, at most 5 visible', async () => {
	for (let i = 1; i <= 6; i++) {
		const t = await api<{ id: string }>('post', '/v1/tasks', { projectID: ids.alpha, title: `Erledigt Nr ${i}` });
		await api('patch', `/v1/tasks/${t.id}`, { version: 1, status: 'done' });
	}
	await page.goto('/now');
	const done = block().getByTestId('now-done');
	await expect(done.getByRole('heading', { name: /Zuletzt fertig/ })).toBeVisible();
	await expect(done.getByTestId('now-done-item')).toHaveCount(5);
	await expect(done.getByTestId('now-done-item').first()).toContainText('Erledigt Nr 6');
	await expect(done).not.toContainText('Erledigt Nr 1');
	await expect(done.getByTestId('now-done-item').first()).toContainText('Todolino Jetzt');
});

test('"Ohne Lebenszeichen (n)": collapsed by default, counter, expandable by keyboard, never inside "Läuft gerade"', async () => {
	silentMode = 'add';
	await page.goto('/now');
	const silent = block().getByTestId('now-silent');
	await expect(silent).toBeVisible();
	await expect(silent).toHaveJSProperty('open', false);
	await expect(silent.locator('summary')).toHaveText(/Ohne Lebenszeichen \(1\)/);
	await expect(silent.getByTestId('now-silent-item')).toBeHidden();
	await silent.locator('summary').focus();
	await page.keyboard.press('Enter');
	await expect(silent).toHaveJSProperty('open', true);
	await expect(silent.getByTestId('now-silent-item')).toHaveCount(1);
	await expect(silent).toContainText('ios-build');
	await expect(silent).toContainText('Wartet auf CI');
	await expect(silent).toContainText(/Lebenszeichen vor 4\d Min\./);
	await expect(block().getByTestId('now-running')).not.toContainText('ios-build');
	await expect(block().getByTestId('now-running').getByTestId('now-running-item')).toHaveCount(3);

	// Everything without a life sign: "Läuft gerade" shows the calm sentence, the counter follows the list.
	silentMode = 'move';
	await page.goto('/now');
	await expect(block().getByTestId('now-running-empty')).toHaveText('Gerade läuft nichts mit Lebenszeichen.');
	await expect(block().getByTestId('now-running').getByTestId('now-running-item')).toHaveCount(0);
	const silent2 = block().getByTestId('now-silent');
	await expect(silent2).toHaveJSProperty('open', false);
	const n = Number(/\((\d+)\)/.exec((await silent2.locator('summary').textContent()) ?? '')?.[1]);
	expect(n).toBe(4);
	await silent2.locator('summary').click();
	await expect(silent2.getByTestId('now-silent-item')).toHaveCount(n);
	await expect(silent2).toContainText('Passkey-Anmeldung absichern');
	silentMode = 'off';
});

test('screenshots of the block: light and dark, desktop and 375 px, without horizontal overflow', async () => {
	mkdirSync(SHOTS, { recursive: true });
	silentMode = 'add';
	for (const [size, prefix] of [[{ width: 1280, height: 900 }, 'jetzt-block'], [{ width: 375, height: 800 }, 'jetzt-block-mobil']] as const) {
		await page.setViewportSize(size);
		await page.goto('/now');
		await expect(block()).toBeVisible();
		await block().getByTestId('now-silent').locator('summary').click();
		for (const [scheme, suffix] of [['light', 'hell'], ['dark', 'dunkel']] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			await page.waitForTimeout(400);
			const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
			expect(w.doc, `horizontal overflow at ${size.width}px (${scheme})`).toBeLessThanOrEqual(w.inner);
			await block().screenshot({ path: `${SHOTS}/${prefix}-${suffix}.png` });
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize({ width: 1280, height: 900 });
	silentMode = 'off';
});

test('shortcut "Jetzt" on the start page shows the running count and leads to the page (mouse and keyboard)', async () => {
	await page.goto('/for-you');
	const entry = page.getByTestId('now-entry');
	await expect(entry).toBeVisible();
	await expect(entry).toContainText('Jetzt');
	await expect(entry.getByTestId('now-entry-running')).toHaveText('3 laufen');
	await expect(entry.getByTestId('now-entry-waiting')).toContainText('warten auf dich');
	await entry.focus();
	await page.keyboard.press('Enter');
	await expect(page).toHaveURL(/\/now$/);
	await expect(block()).toBeVisible();
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
