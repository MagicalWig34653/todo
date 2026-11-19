import { createHash, randomBytes } from 'node:crypto';
import { expect, type APIRequestContext, type Page } from '@playwright/test';

const CALLBACK = 'http://127.0.0.1:59999/callback';
const SCOPES = 'projects:read tasks:read tasks:write comments:write';
const json = { headers: { 'Content-Type': 'application/json' } };

export interface Connection {
	grantID: string;
	token: string;
}

/**
 * An agent connection like Claude Code gets it: register a client (dynamic registration), authorize with PKCE, the signed-in
 * person approves for the given projects, exchange the code. Everything is a real request against the backend.
 */
export async function connect(page: Page, name: string, projectIDs: string[]): Promise<Connection> {
	const reg = await page.request.post('/oauth/register', { data: { client_name: name, redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none' } });
	expect(reg.ok(), `register: ${await reg.text()}`).toBeTruthy();
	const clientID = ((await reg.json()) as { client_id: string }).client_id;
	const verifier = randomBytes(32).toString('base64url');
	const query = new URLSearchParams({
		response_type: 'code', client_id: clientID, redirect_uri: CALLBACK, scope: SCOPES, state: 'bulk',
		code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256'
	});
	const auth = await page.request.get(`/oauth/authorize?${query}`, { headers: { Accept: 'application/json' } });
	expect(auth.ok(), `authorize: ${await auth.text()}`).toBeTruthy();
	const consentRes = await page.request.post('/oauth/consent', {
		...json,
		data: { consent_token: ((await auth.json()) as { consent_token: string }).consent_token, approve: true, project_ids: projectIDs, connection_name: name }
	});
	expect(consentRes.status(), `/oauth/consent: ${await consentRes.text()}`).toBeLessThan(300);
	const consent = (await consentRes.json()) as { redirect_uri: string };
	const code = new URL(consent.redirect_uri).searchParams.get('code');
	expect(code, consent.redirect_uri).toBeTruthy();
	const token = await page.request.post('/oauth/token', {
		form: { grant_type: 'authorization_code', client_id: clientID, code: code!, redirect_uri: CALLBACK, code_verifier: verifier }
	});
	expect(token.ok(), `token: ${await token.text()}`).toBeTruthy();
	const grants = (await (await page.request.get('/oauth/grants')).json()) as { id: string; client_id: string }[];
	const grant = grants.find((g) => g.client_id.toLowerCase() === clientID.toLowerCase());
	expect(grant, 'grant of the new connection').toBeTruthy();
	return { grantID: grant!.id, token: ((await token.json()) as { access_token: string }).access_token };
}

/** One MCP tool call with the OAuth token of a connection (no session cookie involved); returns the raw tool result. */
export async function mcpCall(mcpApi: APIRequestContext, token: string, tool: string, args: Record<string, unknown>): Promise<{ isError: boolean; text: string }> {
	const r = await mcpApi.post('/mcp', {
		headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
		data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: tool, arguments: args } }
	});
	expect(r.status(), `${tool}: ${await r.text()}`).toBe(200);
	const result = ((await r.json()) as { result: { isError?: boolean; content: { text: string }[] } }).result;
	return { isError: result.isError ?? false, text: result.content[0].text };
}

/** Like `mcpCall`, but the call must succeed; returns the parsed JSON result. */
export async function mcp(mcpApi: APIRequestContext, token: string, tool: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
	const result = await mcpCall(mcpApi, token, tool, args);
	expect(result.isError, `${tool}: ${result.text}`).toBe(false);
	return JSON.parse(result.text) as Record<string, unknown>;
}
