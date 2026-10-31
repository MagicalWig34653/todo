import { describe, expect, it } from 'vitest';
import { buildPath, loginRedirectTarget, parseRoute, safeRedirect } from '../src/lib/routing';

const id = '0DCBB03D-997B-4C08-80CB-9FBD69226644';
describe('routing', () => {
	it('maps simple views both ways', () => {
		for (const p of ['/heute', '/eingang', '/anstehend', '/suche', '/ueberblick', '/aktivitaet', '/agenten', '/teams', '/filter', '/konto']) {
			expect(buildPath(parseRoute(p))).toBe(p);
		}
		expect(parseRoute('/')).toEqual({ view: 'today' });
	});
	it('project with sub path and task query', () => {
		const r = parseRoute(`/projekt/${id}/board`, `?task=${id}`);
		expect(r).toEqual({ view: 'project', projectID: id, sub: 'board', taskID: id });
		expect(buildPath(r)).toBe(`/projekt/${id}/board?task=${id}`);
		expect(parseRoute(`/projekt/${id}`).sub).toBeUndefined();
	});
	it('label, filter, account area, task deep link', () => {
		expect(parseRoute(`/labels/${id}`)).toEqual({ view: 'search', labelID: id });
		expect(buildPath({ view: 'search', filterID: id })).toBe(`/filter/${id}`);
		expect(parseRoute('/konto/passkeys').area).toBe('passkeys');
		expect(parseRoute(`/aufgabe/${id}`).taskID).toBe(id);
	});
	it('unknown or malformed paths are notfound', () => {
		for (const p of ['/nix', '/projekt', `/projekt/${id}/foo`, '/projekt/%E0%A4', '/heute/x', '/projekt/a b']) expect(parseRoute(p).view).toBe('notfound');
	});
	it('safeRedirect blocks open redirects and API paths', () => {
		expect(safeRedirect('/projekt/abc?task=1')).toBe('/projekt/abc?task=1');
		for (const bad of ['https://evil.example', '//evil.example', '/\\evil', 'javascript:alert(1)', '/v1/tasks', '/oauth/authorize', '/mcp', null, '', '/a\nb'])
			expect(safeRedirect(bad as string)).toBe('/');
		expect(safeRedirect('x', '/heute')).toBe('/heute');
	});
	it('login redirect accepts only same-origin paths from ?redirect=', () => {
		expect(loginRedirectTarget('?redirect=%2Fprojekt%2Fabc%2Fboard%3Ftask%3D1')).toBe('/projekt/abc/board?task=1');
		for (const bad of ['', '?x=1', '?redirect=', '?redirect=https%3A%2F%2Fevil.example', '?redirect=%2F%2Fevil.example', '?redirect=%2Fv1%2Ftasks', '?redirect=%2F', '?redirect=javascript%3Aalert(1)'])
			expect(loginRedirectTarget(bad)).toBeNull();
	});
});
