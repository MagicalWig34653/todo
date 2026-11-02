import { createHash, randomBytes } from 'node:crypto';
import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/action-requests.spec.ts --project=chromium
// The agent side is a real MCP connection (OAuth with PKCE, bearer token) that asks to delete projects (ADR 0026).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const ORIGIN = process.env.E2E_BASE_URL ?? 'http://localhost:25173';
test.describe.configure({ mode: 'serial' });
let page: Page;
let access = '';
const json = { headers: { 'Content-Type': 'application/json' } };

async function mcp(name: string, args: Record<string, unknown>): Promise<{ isError: boolean; text: string }> {
	const r = await page.request.post('/mcp', {
		headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
		data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }
	});
	const body = await r.json();
	return { isError: body.result.isError, text: body.result.content[0].text };
}
const projectNames = async () => ((await (await page.request.get('/v1/projects')).json()) as { name: string }[]).map((p) => p.name);

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
	await page.getByLabel('Anzeigename').fill('Confirm Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

test('agent asks to delete projects; the card confirms one (name typed) and rejects the other', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	const doomed = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Löschprojekt' } })).json();
	const kept = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Behaltprojekt' } })).json();
	expect((await page.request.post('/v1/tasks', { ...json, data: { projectID: doomed.id, title: 'Weg damit' } })).status()).toBe(201);

	// OAuth connection with PKCE, like an MCP client.
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
	expect(authorize.ok(), await authorize.text()).toBeTruthy();
	const consentToken = ((await authorize.json()) as { consent_token: string }).consent_token;
	const consent = await page.request.post('/oauth/consent', { ...json, data: { consent_token: consentToken, approve: true, project_ids: [doomed.id, kept.id] } });
	const code = new URL(((await consent.json()) as { redirect_uri: string }).redirect_uri).searchParams.get('code');
	const token = await page.request.post('/oauth/token', {
		...json, data: { grant_type: 'authorization_code', client_id: clientID, resource: `${ORIGIN}/mcp`, code, redirect_uri: 'https://client.example/cb', code_verifier: verifier }
	});
	access = ((await token.json()) as { access_token: string }).access_token;

	// The tool does not delete; it answers confirmation_required.
	const first = await mcp('delete_project', { projectID: doomed.id });
	expect(first.isError).toBe(true);
	expect(JSON.parse(first.text).error).toBe('confirmation_required');
	expect(await projectNames()).toContain('Löschprojekt');
	const second = await mcp('delete_project', { projectID: kept.id });
	expect(JSON.parse(second.text).error).toBe('confirmation_required');

	await page.goto('/for-you');
	const card = page.getByTestId('confirm-card').filter({ hasText: 'Löschprojekt' });
	await expect(card).toBeVisible();
	await expect(card.getByTestId('confirm-summary')).toContainText('mit 1 Aufgabe');
	await expect(card).toContainText('Test-Agent');

	// Second step: the name has to be typed.
	await card.getByRole('button', { name: 'Bestätigen', exact: true }).click();
	const run = card.getByTestId('confirm-run');
	await expect(run).toBeDisabled();
	await card.getByTestId('confirm-name').fill('falsch');
	await expect(run).toBeDisabled();
	await card.getByTestId('confirm-name').fill('Löschprojekt');
	await expect(run).toBeEnabled();
	await run.click();
	await expect(card.getByTestId('confirm-outcome')).toHaveText('Projekt gelöscht.');
	expect(await projectNames()).not.toContain('Löschprojekt');
	const got = await mcp('get_action_request', { id: JSON.parse(first.text).actionRequestID });
	expect(JSON.parse(got.text).state).toBe('executed');

	// Rejecting changes nothing.
	const other = page.getByTestId('confirm-card').filter({ hasText: 'Behaltprojekt' });
	await other.getByRole('button', { name: 'Ablehnen', exact: true }).click();
	await expect(other.getByTestId('confirm-outcome')).toContainText('Abgelehnt');
	expect(await projectNames()).toContain('Behaltprojekt');
});

test('card wraps at 320 px without horizontal scrolling', async () => {
	const projects = (await (await page.request.get('/v1/projects')).json()) as { id: string; name: string }[];
	expect(projects.length).toBeGreaterThan(0);
	const kept = projects.find((p) => p.name === 'Behaltprojekt')!;
	const r = await mcp('delete_project', { projectID: kept.id });
	expect(JSON.parse(r.text).error).toBe('confirmation_required');
	await page.setViewportSize({ width: 320, height: 700 });
	await page.goto('/for-you');
	const card = page.getByTestId('confirm-card').first();
	await expect(card).toBeVisible();
	const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
	expect(overflow).toBeLessThanOrEqual(0);
	await card.getByRole('button', { name: 'Ablehnen', exact: true }).click();
	await expect(card.getByTestId('confirm-outcome')).toBeVisible();
});
