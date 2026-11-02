import { describe, expect, it } from 'vitest';
import { buildPath, loginRedirectTarget, parseRoute, safeRedirect } from '../src/lib/routing';

const id = '0DCBB03D-997B-4C08-80CB-9FBD69226644';
describe('routing', () => {
	it('maps simple views both ways', () => {
		for (const p of ['/today', '/inbox', '/upcoming', '/up-next', '/search', '/overview', '/activity', '/agents', '/teams', '/filter', '/settings', '/help']) {
			expect(buildPath(parseRoute(p))).toBe(p);
		}
		expect(parseRoute('/')).toEqual({ view: 'forYou' });
		expect(parseRoute('/for-you')).toEqual({ view: 'forYou' });
	});
	it('project with sub path and task query', () => {
		const r = parseRoute(`/project/${id}/board`, `?task=${id}`);
		expect(r).toEqual({ view: 'project', projectID: id, sub: 'board', taskID: id });
		expect(buildPath(r)).toBe(`/project/${id}/board?task=${id}`);
		expect(parseRoute(`/project/${id}`).sub).toBeUndefined();
	});
	it('label, filter, account area, task deep link', () => {
		expect(parseRoute(`/labels/${id}`)).toEqual({ view: 'search', labelID: id });
		expect(buildPath({ view: 'search', filterID: id })).toBe(`/filter/${id}`);
		expect(parseRoute('/settings/passkeys').area).toBe('passkeys');
		expect(parseRoute(`/task/${id}`).taskID).toBe(id);
	});
	it('unknown or malformed paths are notfound', () => {
		for (const p of ['/nix', '/project', `/project/${id}/foo`, '/project/%E0%A4', '/today/x', '/project/a b']) expect(parseRoute(p).view).toBe('notfound');
	});
	it('safeRedirect blocks open redirects and API paths', () => {
		expect(safeRedirect('/project/abc?task=1')).toBe('/project/abc?task=1');
		for (const bad of ['https://evil.example', '//evil.example', '/\\evil', 'javascript:alert(1)', '/v1/tasks', '/oauth/authorize', '/mcp', null, '', '/a\nb'])
			expect(safeRedirect(bad as string)).toBe('/');
		expect(safeRedirect('x', '/today')).toBe('/today');
	});
	it('login redirect accepts only same-origin paths from ?redirect=', () => {
		expect(loginRedirectTarget('?redirect=%2Fproject%2Fabc%2Fboard%3Ftask%3D1')).toBe('/project/abc/board?task=1');
		for (const bad of ['', '?x=1', '?redirect=', '?redirect=https%3A%2F%2Fevil.example', '?redirect=%2F%2Fevil.example', '?redirect=%2Fv1%2Ftasks', '?redirect=%2F', '?redirect=javascript%3Aalert(1)'])
			expect(loginRedirectTarget(bad)).toBeNull();
	});
});

describe('legacy German paths redirect to English ones', () => {
	const redirect = (p: string) => buildPath(parseRoute(p));
	it('top level views', () => {
		const pairs: Record<string, string> = {
			'/fuer-dich': '/for-you', '/heute': '/today', '/eingang': '/inbox', '/anstehend': '/upcoming', '/als-naechstes': '/up-next', '/suche': '/search',
			'/ueberblick': '/overview', '/aktivitaet': '/activity', '/agenten': '/agents', '/einstellungen': '/settings', '/hilfe': '/help', '/konto': '/settings'
		};
		for (const [old, now] of Object.entries(pairs)) expect(redirect(old), old).toBe(now);
	});
	it('project subpages and tasks keep the id and ?task=', () => {
		expect(redirect(`/projekt/${id}`)).toBe(`/project/${id}`);
		expect(redirect(`/projekt/${id}/liste`)).toBe(`/project/${id}/list`);
		expect(redirect(`/projekt/${id}/ueberblick`)).toBe(`/project/${id}/overview`);
		expect(parseRoute(`/projekt/${id}/kommentare`, `?task=${id}`)).toMatchObject({ view: 'project', sub: 'comments', taskID: id });
		expect(redirect(`/aufgabe/${id}`)).toBe(`/today?task=${id}`);
	});
	it('settings and help areas', () => {
		expect(redirect('/einstellungen/verwaltung-mail')).toBe('/settings/admin-mail');
		expect(redirect('/einstellungen/benachrichtigungen')).toBe('/settings/notifications');
		expect(redirect('/konto/berechtigungen')).toBe('/settings/permissions');
		expect(parseRoute('/settings/admin-mail').area).toBe('verwaltung-mail');
		expect(redirect('/hilfe/erste-schritte')).toBe('/help/getting-started');
		expect(parseRoute('/help/agent-manual').area).toBe('agentenhandbuch');
	});
});
