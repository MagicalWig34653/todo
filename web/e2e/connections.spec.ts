import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/connections.spec.ts --project=chromium
// Covers named MCP connections, connections in the share dialog and the "connection wanted a project" notice (ADR 0028).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const ORIGIN = process.env.E2E_BASE_URL ?? 'http://localhost:25173';
const SHOTS = process.env.SHOTS_DIR ?? '/private/tmp/claude-501/mcp-connections-shots';
test.describe.configure({ mode: 'serial' });
let page: Page;
let access = '';
const json = { headers: { 'Content-Type': 'application/json' } };
type Project = { id: string; name: string };

async function mcp(name: string, args: Record<string, unknown>): Promise<{ isError: boolean; text: string }> {
	const r = await page.request.post('/mcp', {
		headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
		data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }
	});
	const body = await r.json();
	return { isError: body.result.isError, text: body.result.content[0].text };
}
const project = async (name: string): Promise<Project> => (await page.request.post('/v1/projects', { ...json, data: { name } })).json();

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
	await page.getByLabel('Anzeigename').fill('Verbindungs-Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

let open: Project;
let locked: Project;
let ignored: Project;
let clientID = '';

test('consent page asks for a name, default is the client name', async () => {
	open = await project('Freigegeben');
	locked = await project('Gesperrt');
	ignored = await project('Ignoriert');
	expect((await page.request.post('/v1/tasks', { ...json, data: { projectID: locked.id, title: 'Geheime Aufgabe' } })).status()).toBe(201);

	const reg = await page.request.post('/oauth/register', { ...json, data: { client_name: 'Claude Code', redirect_uris: ['https://client.example/cb'], token_endpoint_auth_method: 'none' } });
	clientID = ((await reg.json()) as { client_id: string }).client_id;
	await page.route('https://client.example/**', (route) => route.fulfill({ status: 200, body: 'client' }));
	const verifier = randomBytes(40).toString('hex');
	const challenge = createHash('sha256').update(verifier).digest('base64url');
	const query = new URLSearchParams({
		response_type: 'code', client_id: clientID, redirect_uri: 'https://client.example/cb', scope: 'projects:read tasks:read tasks:write',
		state: 's', resource: `${ORIGIN}/mcp`, code_challenge: challenge, code_challenge_method: 'S256'
	});
	// The PWA consent route: field prefilled with the client name, changed to a custom name.
	await page.goto(`/consent?${query}`);
	const field = page.getByTestId('consent-name');
	await expect(field).toHaveValue('Claude Code');
	await field.fill('Mac mini Claude Code');
	await page.getByLabel('Freigegeben').check();
	await page.getByRole('button', { name: 'Erlauben' }).click();
	await page.waitForURL(/client\.example\/cb\?.*code=/);
	const code = new URL(page.url()).searchParams.get('code');
	const token = await page.request.post('/oauth/token', {
		...json, data: { grant_type: 'authorization_code', client_id: clientID, resource: `${ORIGIN}/mcp`, code, redirect_uri: 'https://client.example/cb', code_verifier: verifier }
	});
	access = ((await token.json()) as { access_token: string }).access_token;
	const info = await mcp('get_connection', {});
	expect(JSON.parse(info.text).name).toBe('Mac mini Claude Code');
});

test('settings: rename, last used, scopes and projects of the connection', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/settings/connections');
	const grant = page.getByTestId('oauth-grant').filter({ hasText: 'Mac mini Claude Code' });
	await expect(grant.getByTestId('oauth-name')).toContainText('(Claude Code)');
	await expect(grant.getByTestId('oauth-last-used')).toContainText('Zuletzt genutzt');
	await grant.getByTestId('oauth-rename').click();
	await grant.getByTestId('oauth-name-input').fill('Build-Mac');
	await grant.getByTestId('oauth-name-save').click();
	await expect(page.getByTestId('oauth-info')).toHaveText('Der Name wurde geändert.');
	await expect(page.getByTestId('oauth-grant').filter({ hasText: 'Build-Mac' })).toContainText('Freigegeben');
	expect(JSON.parse((await mcp('get_connection', {})).text).name).toBe('Build-Mac');
	// An empty name is refused by the form.
	const renamed = page.getByTestId('oauth-grant').filter({ hasText: 'Build-Mac' });
	await renamed.getByTestId('oauth-rename').click();
	await renamed.getByTestId('oauth-name-input').fill('   ');
	await renamed.getByTestId('oauth-name-save').click();
	await expect(page.getByTestId('oauth-info')).toContainText('nicht leer sein');
});

test('share dialog: the connection appears next to people and teams and can be added and removed', async () => {
	await page.goto(`/project/${open.id}`);
	await page.getByTestId('share-open').click();
	const row = page.getByTestId('mcp-connection').filter({ hasText: 'Build-Mac' });
	await expect(row).toContainText('Verbindung Build-Mac');
	await expect(row.getByTestId('mcp-badge')).toHaveText('MCP');
	await expect(row.getByTestId('mcp-role')).toHaveText('Verwalten');
	await page.keyboard.press('Escape');

	await page.goto(`/project/${locked.id}`);
	await page.getByTestId('share-open').click();
	await expect(page.getByTestId('mcp-connection')).toHaveCount(0);
	await page.getByLabel('Empfänger').selectOption('connection');
	await page.getByTestId('connection-pick').selectOption({ label: 'Build-Mac' });
	await page.getByTestId('sharing-panel').getByRole('button', { name: 'Hinzufügen' }).click();
	await expect(page.getByTestId('share-info')).toHaveText('Die Verbindung hat jetzt Zugriff.');
	const added = page.getByTestId('mcp-connection').filter({ hasText: 'Build-Mac' });
	await expect(added).toBeVisible();
	expect((await mcp('list_tasks', { projectID: locked.id })).isError).toBe(false);
	await added.getByTestId('mcp-remove').click();
	await added.getByTestId('mcp-remove-confirm').getByRole('button', { name: 'Zugriff entziehen' }).click();
	await expect(page.getByTestId('mcp-connection')).toHaveCount(0);
	expect(await mcp('list_tasks', { projectID: locked.id })).toEqual({ isError: true, text: 'not_found' });
	await page.keyboard.press('Escape');
});

test('agent asks for a project outside its grant: notice in Für dich, allow or ignore', async () => {
	// Same answer as before; nothing about the project leaks.
	const denied = await mcp('list_tasks', { projectID: locked.id });
	expect(denied).toEqual({ isError: true, text: 'not_found' });
	expect(await mcp('list_tasks', { projectID: ignored.id })).toEqual({ isError: true, text: 'not_found' });
	for (let i = 0; i < 5; i++) await mcp('list_tasks', { projectID: locked.id });
	expect(await mcp('list_tasks', { projectID: '00000000-0000-4000-8000-000000000001' })).toEqual({ isError: true, text: 'not_found' });

	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/for-you');
	const cards = page.getByTestId('access-card');
	await expect(cards).toHaveCount(2);
	const card = cards.filter({ hasText: 'Gesperrt' });
	await expect(card.getByTestId('access-title')).toHaveText('Build-Mac wollte auf Gesperrt zugreifen');
	await expect(card).not.toContainText('Geheime Aufgabe');
	await expect(page.getByRole('button', { name: /^Für dich\s*2$/ })).toBeVisible();

	// One click allows; the agent reads the project right away.
	await card.getByTestId('access-allow').click();
	await expect(cards).toHaveCount(1);
	expect((await mcp('list_tasks', { projectID: locked.id })).isError).toBe(false);
	// Ignoring silences the other one.
	await cards.getByTestId('access-ignore').click();
	await expect(cards).toHaveCount(0);
	expect(await mcp('list_tasks', { projectID: ignored.id })).toEqual({ isError: true, text: 'not_found' });
});

test('screenshots at 390 px, light and dark', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	// A fresh notice for the screenshot.
	const extra = await project('Archiv 2019');
	expect((await mcp('get_task', { id: extra.id })).isError).toBe(true);
	expect((await mcp('list_tasks', { projectID: extra.id })).isError).toBe(true);
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await page.goto('/for-you');
		await expect(page.getByTestId('access-card')).toBeVisible();
		await page.screenshot({ path: `${SHOTS}/for-you-${scheme}.png` });
		await page.goto(`/project/${open.id}`);
		await page.getByTestId('share-open').click();
		await expect(page.getByTestId('mcp-connection')).toBeVisible();
		await page.screenshot({ path: `${SHOTS}/share-${scheme}.png` });
		await page.keyboard.press('Escape');
		await page.goto('/settings/connections');
		await expect(page.getByTestId('oauth-grant')).toBeVisible();
		await page.screenshot({ path: `${SHOTS}/settings-${scheme}.png`, fullPage: true });
	}
	await page.emulateMedia({ colorScheme: 'light' });
});
