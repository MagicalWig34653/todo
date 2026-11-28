import { describe, expect, it } from 'vitest';
import { ApiError, createApi, type FetchLike } from '../src/lib/api';
import {
	finishReturn,
	githubErrorText,
	parseGitHubReturn,
	repositoryChoices,
	safeGitHubURL,
	type GitHubAssignment,
	type GitHubRepository
} from '../src/lib/github';
import { findEntry, normalizeArea, searchSettings, settingsPath, visibleGroups } from '../src/lib/settingsNav';
import { t } from '../src/lib/i18n/index';

// Card E51E8B8C: one GitHub App of the operator, one installation per person (contracts/deploy.yaml 1.3.0).

function recorder(answers: unknown[] = [{}]) {
	const calls: { method: string; url: string; body?: unknown }[] = [];
	const fetchFn: FetchLike = async (url, init) => {
		calls.push({ method: init?.method ?? 'GET', url: String(url), body: init?.body ? JSON.parse(String(init.body)) : undefined });
		const next = answers.length > 1 ? answers.shift() : answers[0];
		return new Response(JSON.stringify(next), { status: 200, headers: { 'Content-Type': 'application/json' } });
	};
	return { calls, api: createApi(fetchFn) };
}

describe('GitHub API client', () => {
	it('uses the person endpoints', async () => {
		const { calls, api } = recorder([{ items: [] }]);
		await api.githubOverview();
		await api.githubConnect('install');
		await api.githubSetup('s1', '111', 'c1');
		await api.githubCallback('s2', 'c2');
		await api.githubRepositories('conn/1');
		await api.removeGitHubConnection('conn/1');
		await api.githubAssignments('p1');
		await api.assignGitHubRepository('p1', 'c', 'o/r');
		await api.unassignGitHubRepository('p1', 'm1');
		expect(calls.map((c) => `${c.method} ${c.url.replace(/^.*\/v1/, '')}`)).toEqual([
			'GET /github',
			'POST /github/connect',
			'POST /github/setup',
			'POST /github/callback',
			'GET /github/connections/conn%2F1/repositories',
			'DELETE /github/connections/conn%2F1',
			'GET /projects/p1/github-repositories',
			'POST /projects/p1/github-repositories',
			'DELETE /projects/p1/github-repositories/m1'
		]);
		expect(calls[1].body).toEqual({ mode: 'install' });
		expect(calls[2].body).toEqual({ state: 's1', installationID: '111', code: 'c1' });
		expect(calls[7].body).toEqual({ connectionID: 'c', repository: 'o/r' });
	});
});

describe('way back from GitHub', () => {
	const state = 'S'.repeat(43);
	it('reads the three kinds of return', () => {
		expect(parseGitHubReturn(`?code=abc&installation_id=111&setup_action=install&state=${state}`)).toEqual({ kind: 'setup', state, installationID: '111', code: 'abc' });
		expect(parseGitHubReturn(`?installation_id=111&setup_action=install&state=${state}`)).toEqual({ kind: 'setup', state, installationID: '111', code: undefined });
		expect(parseGitHubReturn(`?code=abc&state=${state}`)).toEqual({ kind: 'callback', state, code: 'abc' });
	});
	it('names refusal, organisation request, a change made on GitHub and nonsense', () => {
		expect(parseGitHubReturn(`?error=access_denied&state=${state}`).kind).toBe('denied');
		expect(parseGitHubReturn(`?setup_action=request&state=${state}`).kind).toBe('requested');
		expect(parseGitHubReturn('?setup_action=update&installation_id=111').kind).toBe('updated');
		for (const q of ['', '?code=abc', '?state=x', `?installation_id=1%2F2&state=${state}`]) expect(parseGitHubReturn(q).kind, q).toBe('missing');
	});
	it('finishes in one call or goes on to the authorization', async () => {
		const one = recorder([{ connections: [{ id: 'c' }] }]);
		expect(await finishReturn(one.api, { kind: 'setup', state, installationID: '111', code: 'abc' })).toEqual({ done: true });
		expect(one.calls).toHaveLength(1);
		const two = recorder([{ url: 'https://github.com/login/oauth/authorize?state=x' }]);
		expect(await finishReturn(two.api, { kind: 'setup', state, installationID: '111' })).toEqual({ redirect: 'https://github.com/login/oauth/authorize?state=x' });
		const three = recorder([{ connections: [] }]);
		expect(await finishReturn(three.api, { kind: 'callback', state, code: 'abc' })).toEqual({ done: true });
		expect(three.calls[0].url).toContain('/github/callback');
	});
	it('never follows an address that is not GitHub over https (or the local test double)', async () => {
		expect(safeGitHubURL('https://github.com/apps/x/installations/new?state=1')).toBe('https://github.com/apps/x/installations/new?state=1');
		expect(safeGitHubURL('http://127.0.0.1:9/login')).toBe('http://127.0.0.1:9/login');
		for (const bad of ['javascript:alert(1)', 'data:text/html,x', 'http://evil.example/x', '//evil.example', '/relative', 'https://user:pw@github.com/x', ''])
			expect(safeGitHubURL(bad), bad).toBeNull();
		const evil = recorder([{ url: 'javascript:alert(1)' }]);
		await expect(finishReturn(evil.api, { kind: 'setup', state, installationID: '111' })).rejects.toThrow();
	});
});

describe('texts and choices', () => {
	it('has a German text for every code of the server', () => {
		const codes = [
			'github_not_configured', 'github_state_invalid', 'github_installation_invalid', 'github_authorization_failed', 'github_installation_not_yours',
			'github_no_installation', 'github_connection_limit', 'github_repository_invalid', 'github_repository_assigned', 'github_repository_limit',
			'deploy_github_repository_not_allowed', 'deploy_github_repository_public', 'deploy_github_installation_removed',
			'deploy_github_installation_suspended', 'deploy_github_unavailable', 'deploy_github_forbidden', 'deploy_github_auth_failed', 'deploy_github_not_configured'
		];
		const generic = githubErrorText('something_new');
		for (const code of codes) {
			expect(githubErrorText(new ApiError(400, code)), code).not.toBe(generic);
			expect(githubErrorText(code), code).toBe(githubErrorText(new ApiError(400, code)));
		}
		expect(githubErrorText(new Error('server text GEHEIM'))).toBe(generic);
	});
	it('offers repositories not yet mapped; public ones stay visible but cannot be chosen', () => {
		const items: GitHubRepository[] = [
			{ repository: 'a/one', id: 1, private: true },
			{ repository: 'a/Two', id: 2, private: true },
			{ repository: 'a/open', id: 3, private: false }
		];
		const assigned: GitHubAssignment[] = [{ repository: 'a/two', source: 'operator', mine: false, active: true }];
		expect(repositoryChoices(items, assigned)).toEqual([
			{ repository: 'a/one', disabled: false },
			{ repository: 'a/open', disabled: true }
		]);
	});
	it('is a settings page everybody finds', () => {
		const entry = findEntry('github');
		expect(entry?.adminOnly).toBeFalsy();
		expect(visibleGroups(false).find((g) => g.entries.some((x) => x.id === 'github'))?.id).toBe('connected');
		expect(settingsPath('github')).toBe('/settings/github');
		expect(normalizeArea('github')).toBe('github');
		for (const word of ['github', 'repository', 'pull request']) expect(searchSettings(visibleGroups(false), word, t).map((x) => x.id), word).toContain('github');
	});
});
