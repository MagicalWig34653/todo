import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, request, test, type APIRequestContext, type Page } from '@playwright/test';
import { mcp, mcpCall } from './support/oauth';
import { signedInPage } from './support/session';

// Card BEF08998 (ADR 0036), needs a fresh backend database:
//   npx playwright test e2e/mandate-relogin.spec.ts --project=chromium   (also --project=firefox, --project=webkit)
// An MCP client signs in on the real consent page, gets a brain mandate, loses a rotation answer (stays signed in), is
// signed out by replay detection, signs in again and takes projects and mandate over with one click. Counter-checks: a
// connection the person revoked is never offered, a mandate the person revoked does not come back.
// Screenshots (docs/screenshots/vollmacht-neuanmeldung/) are written by the Chromium run only.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/vollmacht-neuanmeldung');
const CALLBACK = 'http://127.0.0.1:59999/callback';
const CLIENT = 'Claude Code (todolino-brain)';
const SCOPES = 'projects:read projects:write tasks:read tasks:write comments:write';
test.describe.configure({ mode: 'serial', timeout: 120_000 });

interface Client { id: string }
interface Tokens { access: string; refresh: string }
let page: Page;
let mcpApi: APIRequestContext;
let alpha = '', beta = '';
let client: Client;
let current: Tokens;

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Relogin Tester');
	mcpApi = await request.newContext({ baseURL: test.info().project.use.baseURL });
	await page.route(`${CALLBACK}**`, (route) => route.fulfill({ status: 200, contentType: 'text/html', body: 'ok' }));
	const make = async (name: string) => {
		const r = await page.request.post('/v1/projects', { data: { name } });
		expect(r.ok(), await r.text()).toBeTruthy();
		return ((await r.json()) as { id: string }).id;
	};
	alpha = await make('Heizung');
	beta = await make('Lager');
	await make('Privat');
});
test.afterAll(async () => {
	await mcpApi?.dispose();
	await page?.context().close();
});

async function register(name = CLIENT): Promise<Client> {
	const r = await page.request.post('/oauth/register', { data: { client_name: name, redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none' } });
	expect(r.ok(), await r.text()).toBeTruthy();
	return { id: ((await r.json()) as { client_id: string }).client_id };
}

/** Opens the real consent page for a client, like the browser window an MCP client opens. */
async function openConsent(c: Client): Promise<string> {
	const verifier = randomBytes(32).toString('base64url');
	const query = new URLSearchParams({
		response_type: 'code', client_id: c.id, redirect_uri: CALLBACK, scope: SCOPES, state: 's',
		code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256'
	});
	await page.goto(`/oauth/authorize?${query}`);
	await expect(page.getByRole('button', { name: 'Erlauben' })).toBeVisible({ timeout: 20_000 });
	return verifier;
}

async function allow(c: Client, verifier: string): Promise<Tokens> {
	const arrived = page.waitForRequest((r) => r.url().startsWith(CALLBACK));
	// Nothing listens on the callback port: the browser ends the redirect on its error page at the callback URL. Wait for that
	// page, otherwise the redirect can still be under way and interrupt the next page.goto (Firefox, E2E run 45932941121).
	const settled = page.waitForURL((u) => u.href.startsWith(CALLBACK), { timeout: 15_000 }).catch(() => undefined);
	await page.getByRole('button', { name: 'Erlauben' }).click();
	const code = new URL((await arrived).url()).searchParams.get('code');
	await settled;
	expect(code).toBeTruthy();
	const t = await page.request.post('/oauth/token', { form: { grant_type: 'authorization_code', client_id: c.id, code: code!, redirect_uri: CALLBACK, code_verifier: verifier } });
	expect(t.ok(), await t.text()).toBeTruthy();
	const body = (await t.json()) as { access_token: string; refresh_token: string };
	return { access: body.access_token, refresh: body.refresh_token };
}

async function refresh(c: Client, token: string): Promise<Tokens | null> {
	const t = await page.request.post('/oauth/token', { form: { grant_type: 'refresh_token', client_id: c.id, refresh_token: token } });
	if (t.status() === 400) return null;
	expect(t.status(), await t.text()).toBe(200);
	const body = (await t.json()) as { access_token: string; refresh_token: string };
	return { access: body.access_token, refresh: body.refresh_token };
}

/** A real forced sign-out: the old refresh token comes back although its successor was already used. */
async function signOutByReplay(c: Client, tokens: Tokens) {
	const second = await refresh(c, tokens.refresh);
	expect(await refresh(c, second!.refresh)).not.toBeNull();
	expect(await refresh(c, tokens.refresh)).toBeNull();
}

interface Mandate { grantID: string; projectIDs: string[]; active: boolean }
const mandates = async () => ((await (await page.request.get('/v1/settings/brain-mandate')).json()) as { mandates: Mandate[] }).mandates;
const brainOf = async (token: string) => (await mcp(mcpApi, token, 'get_connection', {})).brainMandate as { active: boolean; projectIDs?: string[] };
const sorted = (ids: string[] = []) => ids.map((i) => i.toLowerCase()).sort();
const box = (name: string) => page.getByRole('checkbox', { name, exact: true });

const shoots = () => test.info().project.name === 'chromium';
async function noOverflow(label: string) {
	const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
	expect(over, `${label}: page overflows horizontally`).toBeLessThanOrEqual(0);
}
/** The consent page follows the system colour scheme; it is checked and photographed light and dark, wide and narrow. */
async function consentShots(name: string) {
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		for (const [label, width, height] of [['desktop', 1280, 900], ['mobil', 390, 844]] as const) {
			await page.setViewportSize({ width, height });
			await noOverflow(`${name} ${label} ${scheme}`);
			// The sticky button bar would sit in the middle of a full page picture.
			await page.addStyleTag({ content: '.bar{position:static}' }).catch(() => {});
			if (shoots()) await page.screenshot({ path: `${SHOTS}/${label}-${scheme === 'light' ? 'hell' : 'dunkel'}-${name}.png`, fullPage: true });
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize({ width: 1280, height: 900 });
}
/** The PWA keeps its colour scheme in the account; `testid` is the part of the settings page to photograph. */
async function settingsShots(path: string, ready: string, testid: string, name: string) {
	for (const mode of ['light', 'dark'] as const) {
		const prefs = (await (await page.request.get('/v1/me/preferences')).json()) as { appearance: Record<string, unknown> };
		const put = await page.request.put('/v1/me/preferences', { data: { version: 1, appearance: { ...prefs.appearance, colorScheme: mode } } });
		expect(put.ok(), await put.text()).toBeTruthy();
		await page.emulateMedia({ colorScheme: mode });
		await page.evaluate((m) => localStorage.setItem('todo.theme', m), mode);
		for (const [label, width] of [['desktop', 1280], ['mobil', 390]] as const) {
			await page.setViewportSize({ width, height: 900 });
			await page.goto(path);
			await expect(page.getByTestId(ready).first()).toBeVisible({ timeout: 20_000 });
			expect(await page.evaluate(() => document.documentElement.classList.contains('dark'))).toBe(mode === 'dark');
			await noOverflow(`${name} ${label} ${mode}`);
			if (shoots()) {
				// A tall viewport shows the whole part in one real frame (the app shell has fixed bars).
				await page.setViewportSize({ width, height: 3200 });
				await page.getByTestId(testid).first().screenshot({ path: `${SHOTS}/${label}-${mode === 'light' ? 'hell' : 'dunkel'}-${name}.png` });
			}
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.evaluate(() => localStorage.setItem('todo.theme', 'light'));
	await page.setViewportSize({ width: 1280, height: 900 });
}

test('the MCP client signs in on the consent page and gets the mandate', async () => {
	client = await register();
	const verifier = await openConsent(client);
	await expect(page.locator('#takeover')).toHaveCount(0);
	await box('Heizung').check();
	await box('Lager').check();
	current = await allow(client, verifier);
	const grant = ((await (await page.request.get('/oauth/grants')).json()) as { id: string }[])[0];
	const put = await page.request.put('/v1/settings/brain-mandate', { data: { grantID: grant.id, projectIDs: [alpha, beta] } });
	expect(put.ok(), await put.text()).toBeTruthy();
	expect((await brainOf(current.access)).active).toBe(true);
});

test('a lost rotation answer does not sign the client out', async () => {
	const lost = await refresh(client, current.refresh);
	expect(lost).not.toBeNull();
	// The client never stored it and sends the previous token again (log of 26.11.).
	const again = await refresh(client, current.refresh);
	expect(again).not.toBeNull();
	expect((await brainOf(again!.access)).active).toBe(true);
	current = again!;
});

test('replay detection signs out and the settings say what can be done', async () => {
	await signOutByReplay(client, current);
	const r = await mcpApi.post('/mcp', { headers: { Authorization: `Bearer ${current.access}`, 'Content-Type': 'application/json' }, data: { jsonrpc: '2.0', id: 1, method: 'tools/list' } });
	expect(r.status()).toBe(401);
	await page.goto('/settings/brain-mandate');
	await expect(page.getByTestId('bm-recoverable')).toBeVisible({ timeout: 20_000 });
	await expect(page.getByTestId('bm-status')).toHaveText('Sicherheitsabmeldung');
	await settingsShots('/settings/brain-mandate', 'bm-recoverable', 'bm-list', 'vollmacht-abgemeldet');
	await page.goto('/settings/connections');
	await expect(page.getByTestId('oauth-replay')).toBeVisible({ timeout: 20_000 });
	await settingsShots('/settings/connections', 'oauth-replay', 'oauth-grants', 'verbindung-abgemeldet');
});

test('signing in again shows what moves before the click and takes it over', async () => {
	const verifier = await openConsent(client);
	const card = page.locator('#takeover');
	await expect(card).toContainText('Projekte und Brain-Vollmacht von „' + CLIENT + '“ übernehmen');
	await expect(card).toContainText('Brain-Vollmacht in diesen 2 Projekten: Heizung, Lager.');
	await expect(card).toContainText('Pipeline-Einstellungen ändern und diese Projekte für deine anderen Verbindungen freigeben oder entziehen');
	await expect(card).toContainText('aus Sicherheitsgründen abgemeldet');
	await expect(card).not.toContainText('Nur am gleichen Namen erkannt');
	const choice = card.getByRole('checkbox');
	await expect(choice).toBeChecked();
	await expect(box('Heizung')).toBeChecked();
	await expect(box('Lager')).toBeChecked();
	await expect(box('Privat')).not.toBeChecked();
	// It can be switched off and on again.
	await choice.uncheck();
	await expect(box('Heizung')).not.toBeChecked();
	await choice.check();
	await expect(box('Lager')).toBeChecked();
	await consentShots('zustimmung-uebernahme');
	current = await allow(client, verifier);

	const brain = await brainOf(current.access);
	expect(brain.active).toBe(true);
	expect(sorted(brain.projectIDs)).toEqual(sorted([alpha, beta]));
	expect((await mandates()).filter((m) => m.active)).toHaveLength(1);

	await page.goto('/settings/brain-mandate');
	await expect(page.getByTestId('bm-taken-over')).toContainText('Übernommen von „' + CLIENT + '“', { timeout: 20_000 });
	await expect(page.getByTestId('bm-mandate')).toHaveCount(1);
	await expect(page.getByTestId('bm-audit-item').filter({ hasText: 'Vollmacht übernommen' })).toHaveCount(2);
	await settingsShots('/settings/brain-mandate', 'bm-taken-over', 'brain-mandate', 'vollmacht-uebernommen');
});

test('a newly registered client of the same name is only matched with a clear warning', async () => {
	await signOutByReplay(client, current);
	client = await register();
	const verifier = await openConsent(client);
	const card = page.locator('#takeover');
	await expect(card).toContainText('Nur am gleichen Namen erkannt');
	await expect(card.getByRole('checkbox')).toBeChecked();
	await consentShots('zustimmung-nur-name');
	current = await allow(client, verifier);
	expect((await brainOf(current.access)).active).toBe(true);
});

test('counter-check: a mandate the person revoked does not come back', async () => {
	await page.goto('/settings/brain-mandate');
	await expect(page.getByTestId('bm-revoke')).toBeVisible({ timeout: 20_000 });
	await page.getByTestId('bm-revoke').click();
	await page.getByTestId('bm-revoke-go').click();
	await expect(page.getByTestId('bm-status')).toHaveText('Widerrufen');
	const verifier = await openConsent(client);
	const card = page.locator('#takeover');
	await expect(card).toContainText('Projekte von „' + CLIENT + '“ übernehmen');
	await expect(card).not.toContainText('Vollmacht');
	current = await allow(client, verifier);
	expect((await brainOf(current.access)).active).toBe(false);
});

test('counter-check: a connection the person revoked is never offered', async () => {
	await page.goto('/settings/connections');
	const live = page.getByTestId('oauth-grant').filter({ has: page.getByTestId('oauth-rename') });
	await expect(live).toHaveCount(1, { timeout: 20_000 });
	await live.getByRole('button', { name: 'Widerrufen' }).click();
	// The confirmation row has its own button.
	await live.getByRole('button', { name: 'Widerrufen' }).last().click();
	await expect(page.getByTestId('oauth-rename')).toHaveCount(0, { timeout: 20_000 });
	const dead = await mcpCall(mcpApi, current.access, 'get_connection', {}).catch((e: Error) => e.message);
	expect(String(dead)).toContain('401');
	for (const next of [client, await register()]) {
		await openConsent(next);
		await expect(page.locator('#takeover')).toHaveCount(0);
		await expect(box('Heizung')).not.toBeChecked();
		await expect(box('Lager')).not.toBeChecked();
	}
	await consentShots('zustimmung-ohne-uebernahme');
});
