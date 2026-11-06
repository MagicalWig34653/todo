import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// Real OAuth run against the running backend: dynamic client registration, logged-out authorize redirects to the
// login, passkey login returns to the (server-rendered) consent page, screenshots, approval and token scopes.
// Screenshots go to E2E_SHOT_DIR when set (never into the repo).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.E2E_SHOT_DIR;
const CALLBACK = 'http://127.0.0.1:9/callback';

test.describe.configure({ mode: 'serial' });
let page: Page;
let authorizeUrl = '';
let clientID = '';
let verifier = '';
let appOrigin = '';

async function shot(name: string) {
	if (!SHOTS) return;
	mkdirSync(SHOTS, { recursive: true });
	await page.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: true });
}

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey flow needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext()).newPage();
});
test.afterAll(async () => {
	await page?.context().close();
});

test('set up account and projects, then sign out', async () => {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	appOrigin = new URL(page.url()).origin;
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Consent Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();

	// Projects through the cookie session (same origin).
	const make = async (name: string, parentID: string | null) => {
		const res = await page.request.post('/v1/projects', { data: { name, parentID }, headers: { Origin: new URL(page.url()).origin } });
		expect(res.ok()).toBeTruthy();
		return (await res.json()).id as string;
	};
	const home = await make('Haushalt', null);
	await make('Küche und Esszimmer mit einem sehr langen Namen, der umbrechen muss', home);
	await make('Steuererklärung', null);
	await make('Reise', null);

	await page.getByTestId('account-menu').click();
	await page.getByRole('button', { name: 'Abmelden' }).click();
	await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
});

test('logged-out authorize redirects to login and returns to consent after passkey login', async () => {
	const origin = new URL(page.url()).origin;
	const reg = await page.request.post('/oauth/register', {
		data: { client_name: 'Claude Code', redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none' }
	});
	expect(reg.ok()).toBeTruthy();
	clientID = (await reg.json()).client_id;
	verifier = randomBytes(32).toString('base64url');
	const challenge = createHash('sha256').update(verifier).digest('base64url');
	const params = new URLSearchParams({
		response_type: 'code',
		client_id: clientID,
		redirect_uri: CALLBACK,
		scope: 'projects:read tasks:read tasks:write comments:write sharing:write',
		state: 'st a+te&x=1',
		code_challenge: challenge,
		code_challenge_method: 'S256'
	});
	authorizeUrl = `${origin}/oauth/authorize?${params}`;

	await page.goto(authorizeUrl);
	await expect(page).toHaveURL(/\/login\?next=%2Foauth%2Fauthorize%3F/);
	await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
	await shot('login-redirect');

	await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
	await page.waitForURL(/\/oauth\/authorize\?/);
	// The OAuth query comes back unchanged.
	expect(new URL(page.url()).search).toBe(`?${params}`);
	await expect(page.getByRole('heading', { name: /Claude Code möchte auf dein Todolino zugreifen/ })).toBeVisible();
});

test('hostile next values never leave the origin', async () => {
	for (const next of ['//evil.example', 'https://evil.example/', '/\\evil.example', '/oauth/authorize%0d%0aX:1', '/v1/me']) {
		await page.goto(`/login?next=${encodeURIComponent(next)}`);
		await page.waitForTimeout(300);
		expect(new URL(page.url()).pathname, next).toBe('/login');
	}
	await page.goto(authorizeUrl);
	await expect(page.getByRole('heading', { name: /möchte auf dein Todolino zugreifen/ })).toBeVisible();
});

test('consent page renders cleanly in all sizes and themes', async () => {
	const sizes = [
		{ name: 'desktop', width: 1280, height: 900 },
		{ name: '390', width: 390, height: 844 },
		{ name: '320', width: 320, height: 640 }
	];
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		for (const s of sizes) {
			await page.setViewportSize({ width: s.width, height: s.height });
			await expect(page.getByRole('button', { name: 'Erlauben' })).toBeVisible();
			const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
			expect(overflow, `${scheme} ${s.name}`).toBeLessThanOrEqual(0);
			await shot(`consent-${scheme}-${s.name}`);
		}
	}
	// 200 % text size
	await page.setViewportSize({ width: 390, height: 844 });
	await page.evaluate(() => (document.documentElement.style.fontSize = '200%'));
	const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
	expect(overflow).toBeLessThanOrEqual(0);
	await shot('consent-light-200pct');
	await page.evaluate(() => (document.documentElement.style.fontSize = ''));
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize({ width: 1280, height: 900 });
});

test('approve issues a token with exactly the requested scopes', async () => {
	await page.getByRole('checkbox', { name: 'Haushalt' }).check();
	let callback = '';
	await page.route(`${CALLBACK}**`, async (route) => {
		callback = route.request().url();
		await route.fulfill({ status: 200, contentType: 'text/html', body: 'ok' });
	});
	await page.getByRole('button', { name: 'Erlauben' }).click();
	await expect.poll(() => callback).not.toBe('');
	const url = new URL(callback);
	expect(url.searchParams.get('state')).toBe('st a+te&x=1');
	const code = url.searchParams.get('code')!;
	expect(code).toBeTruthy();

	const token = await page.request.post('/oauth/token', {
		form: { grant_type: 'authorization_code', client_id: clientID, code, redirect_uri: CALLBACK, code_verifier: verifier }
	});
	expect(token.ok()).toBeTruthy();
	const body = await token.json();
	expect(body.scope.split(' ').sort()).toEqual(['comments:write', 'projects:read', 'sharing:write', 'tasks:read', 'tasks:write']);
	expect(body.access_token).toBeTruthy();
});

// ---- Connection name (`connection_name`, default `default_name`, at most 80 characters) on the server-rendered page ----

async function registerClient(clientName: string) {
	const reg = await page.request.post('/oauth/register', {
		data: { client_name: clientName, redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none' }
	});
	expect(reg.ok()).toBeTruthy();
	const id = (await reg.json()).client_id as string;
	const nameVerifier = randomBytes(32).toString('base64url');
	const query = new URLSearchParams({
		response_type: 'code',
		client_id: id,
		redirect_uri: CALLBACK,
		scope: 'projects:read tasks:read',
		state: 'n',
		code_challenge: createHash('sha256').update(nameVerifier).digest('base64url'),
		code_challenge_method: 'S256'
	});
	return { id, verifier: nameVerifier, url: `${appOrigin}/oauth/authorize?${query}` };
}

async function exchange(client: { id: string; verifier: string }, code: string): Promise<string> {
	const token = await page.request.post('/oauth/token', {
		form: { grant_type: 'authorization_code', client_id: client.id, code, redirect_uri: CALLBACK, code_verifier: client.verifier }
	});
	expect(token.ok()).toBeTruthy();
	return (await token.json()).access_token as string;
}

async function connectionName(access: string): Promise<string> {
	// The Vite dev proxy does not forward /mcp; talk to the backend directly when BACKEND_URL is set.
	const r = await page.request.post(`${process.env.BACKEND_URL ?? ''}/mcp`, {
		headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
		data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_connection', arguments: {} } }
	});
	return JSON.parse((await r.json()).result.content[0].text).name as string;
}

async function approveOnPage(): Promise<string> {
	await page.getByRole('checkbox', { name: 'Haushalt' }).check();
	let callback = '';
	await page.route(`${CALLBACK}**`, async (route) => {
		callback = route.request().url();
		await route.fulfill({ status: 200, contentType: 'text/html', body: 'ok' });
	});
	await page.getByRole('button', { name: 'Erlauben' }).click();
	await expect.poll(() => callback).toContain('code=');
	return new URL(callback).searchParams.get('code')!;
}

test('consent page: name field is prefilled with the default, capped at 80, a custom name is stored and shown in settings', async () => {
	const client = await registerClient('Namens-Client');
	await page.goto(client.url);
	const field = page.getByLabel('Name der Verbindung');
	await expect(field).toHaveValue('Namens-Client');
	await expect(field).toHaveAttribute('maxlength', '80');
	await field.fill('Mac mini Claude Code');
	const access = await exchange(client, await approveOnPage());
	expect(await connectionName(access)).toBe('Mac mini Claude Code');

	await page.goto('/settings/connections');
	await expect(page.getByTestId('oauth-grant').filter({ hasText: 'Mac mini Claude Code' })).toBeVisible();
});

test('consent page: an untouched field keeps the default name', async () => {
	const client = await registerClient('Standard-Client');
	await page.goto(client.url);
	await expect(page.getByLabel('Name der Verbindung')).toHaveValue('Standard-Client');
	expect(await connectionName(await exchange(client, await approveOnPage()))).toBe('Standard-Client');
});

test('consent endpoint: 81 characters are rejected with invalid_name and the request stays usable, 80 are accepted', async () => {
	const client = await registerClient('Grenz-Client');
	const origin = appOrigin;
	// Without Accept: text/html the authorize endpoint speaks the JSON contract the consent page uses.
	const pending = await page.request.get(client.url);
	expect(pending.ok()).toBeTruthy();
	const offer = await pending.json();
	expect(offer.default_name).toBe('Grenz-Client');
	const projects = (await (await page.request.get('/v1/projects')).json()) as { id: string; name: string }[];
	const home = projects.find((p) => p.name === 'Haushalt')!.id;
	const consent = (name: string) =>
		page.request.post('/oauth/consent', {
			headers: { Origin: origin },
			data: { consent_token: offer.consent_token, approve: true, project_ids: [home], connection_name: name }
		});

	const tooLong = await consent('x'.repeat(81));
	expect(tooLong.status()).toBe(400);
	expect(await tooLong.text()).toContain('invalid_name');

	const exact = 'y'.repeat(80);
	const ok = await consent(exact);
	expect(ok.ok()).toBeTruthy();
	const code = new URL((await ok.json()).redirect_uri).searchParams.get('code')!;
	expect(await connectionName(await exchange(client, code))).toBe(exact);
});
