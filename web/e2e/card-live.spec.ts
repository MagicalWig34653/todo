import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database (native backend, scratch SQLite) and E2E_SQLITE = absolute path of that SQLite file
// (used to move last_seen_at back for the "still" hint). Run on its own:
//   E2E_SQLITE=/abs/e2e.sqlite npx playwright test e2e/card-live.spec.ts --project=chromium   (also --project=webkit)
// Card CCCFFB78 (ADR 0031, contracts/live-session.yaml): the Aktivität tab shows the live view of the card: running sessions
// with the current step, the compact event history, and below it the previous activity list. Events are reported through the
// REAL MCP tools (report_session_step / report_session_event) with a real OAuth token, exactly like an agent does.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/live-ansicht');
const SQLITE = process.env.E2E_SQLITE ?? '';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
let agent = '';
const cards = { main: '', empty: '', many: '', error: '' };

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}

/** Real OAuth (register, authorize, consent, PKCE token) for /mcp, scope tasks:write. */
async function oauthToken(projectID: string, base: string): Promise<string> {
	const redirect = 'http://127.0.0.1:54321/callback';
	const reg = await (await fetch(`${base}/oauth/register`, { method: 'POST', ...json, body: JSON.stringify({ client_name: 'Live E2E', redirect_uris: [redirect] }) })).json();
	const verifier = 'a'.repeat(64);
	const challenge = createHash('sha256').update(verifier).digest('base64url');
	const resource = (await (await fetch(`${base}/.well-known/oauth-protected-resource/mcp`)).json()).resource as string;
	const q = new URLSearchParams({ response_type: 'code', client_id: reg.client_id, redirect_uri: redirect, scope: 'projects:read tasks:read tasks:write', state: 's', resource, code_challenge: challenge, code_challenge_method: 'S256' });
	const auth = await page.request.get(`/oauth/authorize?${q}`, { headers: { Accept: 'application/json' } });
	expect(auth.status(), await auth.text()).toBe(200);
	const consent = await page.request.post('/oauth/consent', { ...json, data: { consent_token: (await auth.json()).consent_token, approve: true, project_ids: [projectID] } });
	expect(consent.status(), await consent.text()).toBe(200);
	const code = new URL((await consent.json()).redirect_uri).searchParams.get('code')!;
	const tok = await fetch(`${base}/oauth/token`, { method: 'POST', ...json, body: JSON.stringify({ grant_type: 'authorization_code', client_id: reg.client_id, resource, code, redirect_uri: redirect, code_verifier: verifier }) });
	expect(tok.status).toBe(200);
	return (await tok.json()).access_token as string;
}

async function tool(name: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
	const base = test.info().project.use.baseURL!;
	const r = await fetch(`${base}/mcp`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${agent}` }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) });
	const res = (await r.json()).result;
	const text = res.content[0].text as string;
	expect(res.isError ?? false, `${name}: ${text}`).toBe(false);
	return JSON.parse(text);
}
const step = (taskID: string, text: string, extra: Record<string, unknown> = {}) => tool('report_session_step', { taskID, step: text, session: 'Mac Studio', model: 'claude-opus-4', agentName: 'Claude Code', ...extra });
const event = (taskID: string, kind: string, text: string, session = 'Mac Studio') => tool('report_session_event', { taskID, kind, text, session });

const dialog = () => page.getByTestId('card-dialog');
const panel = () => dialog().getByRole('tabpanel');
const live = () => panel().getByTestId('card-live');
const open = async (id: string) => {
	await page.goto(`/for-you?card=task:${id}&tab=activity`);
	await expect(dialog()).toBeVisible();
	await expect(dialog().getByRole('tab', { name: 'Aktivität', exact: true })).toHaveAttribute('aria-selected', 'true');
};
const noOverflow = async (label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
	const inner = await dialog().getByTestId('card-scroll').evaluate((el) => el.scrollWidth - el.clientWidth);
	expect(inner, `${label}: card scroll area overflows`).toBeLessThanOrEqual(0);
};

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Live Tester');
	await page.addInitScript(() => {
		const original = window.fetch.bind(window);
		window.fetch = (input, init) => {
			const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
			if (sessionStorage.getItem('failLive') && /\/v1\/tasks\/[^/]+\/live/.test(url)) {
				return Promise.resolve(new Response('{"error":true,"reason":"internal"}', { status: 500, headers: { 'Content-Type': 'application/json' } }));
			}
			return original(input, init);
		};
	});
	const project = await post<{ id: string }>('/v1/projects', { name: 'Liveprojekt' });
	const mk = (title: string) => post<{ id: string }>('/v1/tasks', { projectID: project.id, title });
	cards.main = (await mk('Aufgabe mit Live-Verlauf')).id;
	cards.empty = (await mk('Aufgabe ohne Meldung')).id;
	cards.many = (await mk('Aufgabe mit vielen Ereignissen')).id;
	cards.error = (await mk('Aufgabe mit Fehler')).id;
	await post(`/v1/tasks/${cards.main}/progress-notes`, { note: 'Bisheriger Fortschritt', percent: 10 });
	agent = await oauthToken(project.id, test.info().project.use.baseURL!);
});
test.afterAll(async () => {
	await page?.context().close();
});

test('empty state: no session has reported yet, the previous activity list stays', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await open(cards.empty);
	await expect(live().getByTestId('live-empty')).toHaveText('Noch keine Sitzung hat gemeldet.');
	await expect(live().getByTestId('live-session')).toHaveCount(0);
	await expect(panel().getByTestId('activity').first()).toBeVisible();
	// No error and no half-finished list in the empty state.
	await expect(live().getByTestId('live-error')).toHaveCount(0);
	await expect(live().getByTestId('live-event')).toHaveCount(0);
});

test('session with current step and the compact history, newest first, plain text, secrets masked', async () => {
	await step(cards.main, 'Lese die Karte');
	await event(cards.main, 'tool', 'swift test --filter LiveSessionTests');
	await event(cards.main, 'question', 'Soll der Filter Hex maskieren?');
	await event(cards.main, 'note', '<img src=x onerror="document.title=\'pwned\'"> <b>fett</b>');
	await event(cards.main, 'progress', '50 Prozent');
	await event(cards.main, 'note', 'git push https://lino:ghp_1234567890abcdefghijklmnopqrstuvwxyzAB@github.com/x/y.git');
	await step(cards.main, 'Schreibe den Migrationstest');
	await open(cards.main);
	const s = live().getByTestId('live-session');
	await expect(s).toHaveCount(1);
	await expect(s).toContainText('Mac Studio');
	await expect(s).toContainText('claude-opus-4');
	await expect(s).toContainText('Claude Code');
	await expect(s).toContainText('Seit ');
	await expect(s.getByTestId('live-session-step')).toHaveText('Schreibe den Migrationstest');
	// Polite live region for the current step.
	await expect(s.getByTestId('live-session-step')).toHaveAttribute('aria-live', 'polite');
	await expect(live().getByTestId('live-stale')).toHaveCount(0);
	// History: newest first, kind as a label, relative and absolute time.
	const rows = live().getByTestId('live-event');
	await expect(rows.first()).toContainText('Schritt');
	await expect(rows.first()).toContainText('Schreibe den Migrationstest');
	await expect(rows.first().locator('time')).toHaveAttribute('datetime', /^\d{4}-\d{2}-\d{2}T/);
	await expect(rows.first()).toContainText('gerade eben');
	await expect(rows.first().locator('time')).toHaveAttribute('title', /\d{2}:\d{2}/);
	const kinds = await rows.evaluateAll((els) => els.map((e) => e.getAttribute('data-kind')));
	expect(kinds).toEqual(['step', 'note', 'progress', 'note', 'question', 'tool', 'step']);
	await expect(rows.filter({ hasText: 'Frage' })).toContainText('Soll der Filter Hex maskieren?');
	// The secret is masked, never shown; markup is shown as text, nothing is executed or inserted.
	const html = await live().innerHTML();
	expect(html).not.toContain('ghp_1234567890');
	await expect(rows.filter({ hasText: 'github.com' })).toContainText('[gefiltert]');
	await expect(rows.filter({ hasText: 'onerror' })).toContainText('<img src=x onerror=');
	await expect(live().locator('img, b')).toHaveCount(0);
	expect(await page.title()).not.toBe('pwned');
	// The previous activity list is still there, below the live view.
	const liveBox = (await live().boundingBox())!;
	const act = (await panel().getByTestId('activity').first().boundingBox())!;
	expect(act.y).toBeGreaterThanOrEqual(liveBox.y + liveBox.height - 1);
});

test('a new step appears without a reload and without layout jump or re-mount', async () => {
	await open(cards.main);
	await expect(live().getByTestId('live-session-step')).toHaveText('Schreibe den Migrationstest');
	// Mark the DOM nodes: a flicker/re-mount would drop the marker.
	await live().getByTestId('live-session').evaluate((el) => ((el as HTMLElement & { _mark?: number })._mark = 42));
	await live().getByTestId('live-event').nth(3).evaluate((el) => ((el as HTMLElement & { _mark?: number })._mark = 7));
	const before = {
		live: (await live().boundingBox())!,
		session: (await live().getByTestId('live-session').boundingBox())!,
		count: await live().getByTestId('live-event').count()
	};
	await page.evaluate(() => {
		const w = window as unknown as { _shifts: number };
		w._shifts = 0;
		new PerformanceObserver((l) => { for (const e of l.getEntries() as (PerformanceEntry & { value: number; hadRecentInput: boolean })[]) if (!e.hadRecentInput) w._shifts += e.value; }).observe({ type: 'layout-shift', buffered: false });
	});
	await step(cards.main, 'Prüfe den Secrets-Filter');
	// No reload: the step shows up through the live refresh (long poll or fallback poll).
	await expect(live().getByTestId('live-session-step')).toHaveText('Prüfe den Secrets-Filter', { timeout: 20_000 });
	await expect(live().getByTestId('live-event')).toHaveCount(before.count + 1);
	await expect(live().getByTestId('live-event').first()).toContainText('Prüfe den Secrets-Filter');
	const after = { live: (await live().boundingBox())!, session: (await live().getByTestId('live-session').boundingBox())! };
	// The session block stays where it was (height can only follow the new text), the same nodes are kept.
	expect(Math.abs(after.session.y - before.session.y)).toBeLessThanOrEqual(1);
	expect(Math.abs(after.live.y - before.live.y)).toBeLessThanOrEqual(1);
	expect(await live().getByTestId('live-session').evaluate((el) => (el as HTMLElement & { _mark?: number })._mark)).toBe(42);
	expect(await live().getByTestId('live-event').nth(4).evaluate((el) => (el as HTMLElement & { _mark?: number })._mark)).toBe(7);
	expect(await page.evaluate(() => (window as unknown as { _shifts: number })._shifts)).toBeLessThan(0.05);
	// An event of another kind arrives as well.
	await event(cards.main, 'progress', '80 Prozent');
	await expect(live().getByTestId('live-event').first()).toContainText('80 Prozent', { timeout: 20_000 });
});

test('a silent active session shows "Still seit", ended sessions are collapsed and open by keyboard', async () => {
	test.skip(!SQLITE, 'E2E_SQLITE not set');
	await step(cards.main, 'Zweite Sitzung läuft', { session: 'Zweite' });
	await step(cards.main, 'fertig', { session: 'Alte', ended: true });
	// 30 minutes without a sign of life for "Zweite" (unix seconds in the scratch SQLite; relative shift, so the unit does not matter much).
	execFileSync('sqlite3', [SQLITE, `UPDATE task_live_sessions SET last_seen_at = last_seen_at - 1800 WHERE name = 'Zweite' AND task_id = '${cards.main.toUpperCase()}';`]);
	await open(cards.main);
	const zweite = live().getByTestId('live-session').filter({ hasText: 'Zweite' });
	await expect(zweite.getByTestId('live-stale')).toContainText(/Still seit .*30 Min/);
	await expect(live().getByTestId('live-session').filter({ hasText: 'Mac Studio' }).getByTestId('live-stale')).toHaveCount(0);
	// Ended: collapsed in a <details>, not among the running sessions.
	const ended = live().getByTestId('live-ended');
	await expect(ended).toBeVisible();
	expect(await ended.evaluate((el) => (el as HTMLDetailsElement).open)).toBe(false);
	await expect(ended.locator('summary')).toContainText('Beendete Sitzungen (1)');
	await expect(live().getByTestId('live-active').getByTestId('live-session').filter({ hasText: 'Alte' })).toHaveCount(0);
	await expect(ended.getByTestId('live-session')).toBeHidden();
	await ended.locator('summary').focus();
	await page.keyboard.press('Enter');
	expect(await ended.evaluate((el) => (el as HTMLDetailsElement).open)).toBe(true);
	await expect(ended).toContainText('Alte');
	await expect(ended).toContainText('Beendet');
	// A refresh does not collapse it again.
	await step(cards.main, 'Noch ein Schritt');
	await expect(live().getByTestId('live-event').first()).toContainText('Noch ein Schritt', { timeout: 20_000 });
	expect(await ended.evaluate((el) => (el as HTMLDetailsElement).open)).toBe(true);
});

test('load more: pages by nextCursor, no duplicates, keyboard reachable with a visible focus ring', async () => {
	await step(cards.many, 'Viele Ereignisse');
	for (let i = 1; i <= 54; i++) await event(cards.many, 'tool', `Ereignis ${String(i).padStart(2, '0')}`);
	await open(cards.many);
	const rows = live().getByTestId('live-event');
	await expect(rows).toHaveCount(50);
	await expect(rows.first()).toContainText('Ereignis 54');
	const more = live().getByTestId('live-more');
	await expect(more).toHaveText('Mehr laden');
	await more.focus();
	const ring = await more.evaluate((el) => { const s = getComputedStyle(el); return `${s.outlineStyle} ${s.outlineWidth} ${s.boxShadow}`; });
	expect(ring).not.toBe('none 0px none');
	await page.keyboard.press('Enter');
	await expect(rows).toHaveCount(55);
	await expect(live().getByTestId('live-more')).toHaveCount(0);
	const texts = await rows.allInnerTexts();
	expect(new Set(texts).size).toBe(texts.length);
	await expect(rows.last()).toContainText('Viele Ereignisse');
});

test('error state: message with retry, recovers without reload, and a later refresh failure keeps the shown data', async () => {
	await step(cards.error, 'Läuft');
	// The failure is injected in the page (sessionStorage flag read by the fetch wrapper from beforeAll): page.route does not
	// reliably intercept in WebKit, this works the same in every browser.
	const failLive = (on: boolean) => page.evaluate((v) => (v ? sessionStorage.setItem('failLive', '1') : sessionStorage.removeItem('failLive')), on);
	await failLive(true);
	await open(cards.error);
	const err = live().getByTestId('live-error');
	await expect(err).toBeVisible();
	await expect(err).toHaveAttribute('role', 'alert');
	await expect(err).toContainText('Live-Ansicht konnte nicht geladen werden');
	await expect(live().getByTestId('live-empty')).toHaveCount(0);
	await failLive(false);
	await live().getByTestId('live-retry').click();
	await expect(live().getByTestId('live-session-step')).toHaveText('Läuft');
	await expect(err).toHaveCount(0);
	// Later failures are silent (the data stays, the next refresh retries).
	await failLive(true);
	await step(cards.error, 'Nach dem Fehler');
	await page.waitForTimeout(2500);
	await expect(live().getByTestId('live-session-step')).toHaveText('Läuft');
	await expect(live().getByTestId('live-error')).toHaveCount(0);
	await failLive(false);
	await expect(live().getByTestId('live-session-step')).toHaveText('Nach dem Fehler', { timeout: 20_000 });
});

for (const [label, size] of [['desktop', { width: 1280, height: 800 }], ['mobile', { width: 390, height: 844 }]] as const) {
	test(`${label}: no overflow, light and dark screenshots`, async () => {
		await page.setViewportSize(size);
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			await open(cards.main);
			await expect(live().getByTestId('live-session').first()).toBeVisible();
			await noOverflow(`${label} ${scheme}`);
			// Long unbroken text wraps inside the card instead of widening it.
			await page.waitForTimeout(300);
			await page.screenshot({ path: `${SHOTS}/${label}-${scheme}-live.png` });
			await open(cards.empty);
			await expect(live().getByTestId('live-empty')).toBeVisible();
			await page.waitForTimeout(300);
			await page.screenshot({ path: `${SHOTS}/${label}-${scheme}-leer.png` });
		}
		await page.emulateMedia({ colorScheme: 'light' });
	});
}
