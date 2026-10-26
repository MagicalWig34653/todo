import { describe, expect, it } from 'vitest';
import { createApi, type FetchLike, type OAuthGrant, type Project } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import { redirectTarget, resolveGrantProjects, safeRedirect, scopeLabel, sortGrants } from '../src/lib/oauth';

function recorder(body: unknown, status = 200) {
	const calls: { url: string; init?: RequestInit }[] = [];
	const fetchFn: FetchLike = async (url, init) => {
		calls.push({ url, init });
		return new Response(status === 204 ? null : JSON.stringify(body), { status });
	};
	return { calls, api: createApi(fetchFn) };
}

describe('oauth api', () => {
	it('passes the authorization query through on the unversioned /oauth path', async () => {
		const { calls, api } = recorder({ consent_token: 'c' });
		await api.oauthAuthorize('?client_id=1&state=a%20b');
		expect(calls[0].url).toBe('/oauth/authorize?client_id=1&state=a%20b');
		expect(calls[0].init?.method).toBe('GET');
	});
	it('sends no project ids when denying', async () => {
		const { calls, api } = recorder({ redirect_uri: 'x://y' });
		await api.oauthConsent('tok', false, ['p1']);
		expect(calls[0].url).toBe('/oauth/consent');
		expect(JSON.parse(calls[0].init?.body as string)).toEqual({ consent_token: 'tok', approve: false, project_ids: [] });
	});
	it('sends selected projects when approving', async () => {
		const { calls, api } = recorder({ redirect_uri: 'x://y' });
		await api.oauthConsent('tok', true, ['p1', 'p2']);
		expect(JSON.parse(calls[0].init?.body as string).project_ids).toEqual(['p1', 'p2']);
	});
	it('lists and revokes grants', async () => {
		const list = recorder([]);
		await list.api.listOAuthGrants();
		expect(list.calls[0].url).toBe('/oauth/grants');
		const del = recorder(null, 204);
		await del.api.revokeOAuthGrant('g1');
		expect(del.calls[0]).toMatchObject({ url: '/oauth/grants/g1', init: { method: 'DELETE' } });
	});
	it('issues recovery codes under /v1/identity', async () => {
		const { calls, api } = recorder({ token: 't', expiresAt: '2026-10-26T10:00:00Z' });
		const r = await api.issueRecovery('a/b');
		expect(r.token).toBe('t');
		expect(calls[0].url).toBe('/v1/identity/accounts/a%2Fb/recovery');
		expect(calls[0].init?.method).toBe('POST');
	});
});

describe('oauth helpers', () => {
	it('rejects script-like redirect schemes', () => {
		expect(safeRedirect('javascript:alert(1)')).toBeNull();
		expect(safeRedirect('data:text/html,x')).toBeNull();
		expect(safeRedirect('not a url')).toBeNull();
		expect(safeRedirect('https://client.example/cb?code=1')).toBe('https://client.example/cb?code=1');
		expect(safeRedirect('claude://cb?code=1')).toBe('claude://cb?code=1');
	});
	it('shows the redirect target host or scheme', () => {
		expect(redirectTarget('https://client.example/cb?code=1')).toBe('https://client.example');
		expect(redirectTarget('http://127.0.0.1:9/cb')).toBe('http://127.0.0.1:9');
		expect(redirectTarget('com.app:/cb')).toBe('com.app:');
	});
	it('resolves grant project names and counts hidden ones', () => {
		const projects = [{ id: 'a', name: 'A' }] as Project[];
		const grant = { project_ids: ['a', 'zz'] } as OAuthGrant;
		expect(resolveGrantProjects(grant, projects)).toEqual({ names: ['A'], unknown: 1 });
	});
	it('puts active grants first without reordering otherwise', () => {
		const gs = [{ id: '1', revoked: true }, { id: '2', revoked: false }, { id: '3', revoked: true }, { id: '4', revoked: false }] as OAuthGrant[];
		expect(sortGrants(gs).map((g) => g.id)).toEqual(['2', '4', '1', '3']);
	});
	it('localizes known scopes and passes unknown through', () => {
		expect(scopeLabel('tasks:read')).toBe(de['scope.tasks:read']);
		expect(scopeLabel('other')).toBe('other');
	});
});
