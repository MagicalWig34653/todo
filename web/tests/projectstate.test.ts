import { describe, expect, it } from 'vitest';
import { ApiError, createApi, type FetchLike, type Project, type ProjectPrefs } from '../src/lib/api';
import { buildTree, compareSiblings, planDrop, planMoveTo, planStep, siblingsOf } from '../src/lib/projectTree';
import { projectColor } from '../src/lib/boardLogic';
import {
	displayChangeToPrefs,
	favoriteProjects,
	hasLegacyState,
	importLegacyState,
	prefsToDisplay,
	savePrefs,
	type LegacyStorage
} from '../src/lib/projectState';

function recorder(...responses: Response[]) {
	const calls: { url: string; init?: RequestInit }[] = [];
	let i = 0;
	const fetchFn: FetchLike = async (url, init) => {
		calls.push({ url, init });
		return responses[Math.min(i++, responses.length - 1)].clone();
	};
	return { calls, api: createApi(fetchFn) };
}
const body = (c: { init?: RequestInit }) => JSON.parse(c.init?.body as string);
const p = (id: string, parentID: string | null = null, o: Partial<Project> = {}): Project => ({ id, parentID, name: id, version: 1, ...o });

describe('project state api', () => {
	it('patches prefs with the revision and renames showCompleted', async () => {
		const { calls, api } = recorder(Response.json({}));
		await api.patchProjectPrefs('p1', 3, { view: 'board', showCompleted: false });
		expect(calls[0].url).toBe('/v1/me/project-prefs/p1');
		expect(calls[0].init?.method).toBe('PATCH');
		expect(body(calls[0])).toEqual({ revision: 3, view: 'board', showCompleted: false });
	});
	it('sends only index for own order and parentID plus version for re-parenting', async () => {
		const { calls, api } = recorder(Response.json({}));
		await api.putProjectPosition(p('a', null, { version: 4 }), 2);
		await api.putProjectPosition(p('a', null, { version: 4 }), 0, null);
		expect(calls[0].url).toBe('/v1/projects/a/position');
		expect(body(calls[0])).toEqual({ index: 2 });
		expect(body(calls[1])).toEqual({ index: 0, parentID: null, version: 4 });
	});
	it('updates description and colour with the project version; empty string clears', async () => {
		const { calls, api } = recorder(Response.json({}));
		await api.updateProject(p('a', null, { version: 7 }), { description: '', color: '#2470E0' });
		expect(body(calls[0])).toEqual({ version: 7, description: '', color: '#2470E0' });
	});
	it('sets the idempotency key on project comments and lists the feed with cursor', async () => {
		const { calls, api } = recorder(Response.json({ items: [] }));
		await api.createProjectComment('a', 'hi', 'key-1');
		expect((calls[0].init?.headers as Record<string, string>)['Idempotency-Key']).toBe('key-1');
		await api.feed({ projectID: 'a', before: '123:x', limit: 30 });
		expect(calls[1].url).toBe('/v1/activity?projectID=a&before=123%3Ax&limit=30');
		await api.listJobs({ state: 'running' });
		expect(calls[2].url).toBe('/v1/agents/jobs?state=running');
		await api.listJobs({ state: '' });
		expect(calls[3].url).toBe('/v1/agents/jobs');
	});
	it('recognises revision conflicts', () => {
		expect(new ApiError(409, 'revision_conflict').isRevisionConflict).toBe(true);
		expect(new ApiError(409, 'version_conflict').isRevisionConflict).toBe(false);
	});
});

describe('prefs mapping and revision handling', () => {
	it('maps between server and ui names', () => {
		expect(prefsToDisplay(undefined)).toEqual({ view: 'list', sort: 'manual', grouping: 'column', showDone: true });
		expect(displayChangeToPrefs({ showDone: false, view: 'board' })).toEqual({ view: 'board', showCompleted: false });
		const stored: ProjectPrefs = { projectID: 'a', view: 'board', sort: 'due', grouping: 'none', showCompleted: false, revision: 2 };
		expect(prefsToDisplay(stored)).toEqual({ view: 'board', sort: 'due', grouping: 'none', showDone: false });
	});
	it('retries once with the fresh revision after revision_conflict', async () => {
		const calls: string[] = [];
		const fake = {
			patchProjectPrefs: async (id: string, revision: number) => {
				calls.push(`patch:${revision}`);
				if (revision === 1) throw new ApiError(409, 'revision_conflict');
				return { projectID: id, view: 'board', sort: 'manual', grouping: 'column', showCompleted: true, revision: revision + 1 } as ProjectPrefs;
			},
			getProjectPrefs: async (id: string) => (calls.push('get'), { projectID: id, revision: 5 } as ProjectPrefs)
		};
		const saved = await savePrefs(fake, { projectID: 'a', view: 'list', sort: 'manual', grouping: 'column', showCompleted: true, revision: 1 }, { view: 'board' });
		expect(calls).toEqual(['patch:1', 'get', 'patch:5']);
		expect(saved.revision).toBe(6);
	});
	it('does not swallow other errors', async () => {
		const fake = {
			patchProjectPrefs: async () => {
				throw new ApiError(403);
			},
			getProjectPrefs: async () => ({}) as ProjectPrefs
		};
		await expect(savePrefs(fake, { projectID: 'a', revision: 0 } as ProjectPrefs, { view: 'board' })).rejects.toMatchObject({ status: 403 });
	});
});

describe('favourites and colour', () => {
	it('orders favourites by position', () => {
		const list = [p('a', null, { isFavorite: true, favoritePosition: 1 }), p('b'), p('c', null, { isFavorite: true, favoritePosition: 0 })];
		expect(favoriteProjects(list).map((x) => x.id)).toEqual(['c', 'a']);
	});
	it('prefers the chosen colour over the derived one', () => {
		expect(projectColor('x', '#112233')).toBe('#112233');
		expect(projectColor('x', 'nonsense')).toBe(projectColor('x'));
		expect(projectColor('x', null)).toBe(projectColor('x'));
	});
});

describe('sibling order and drop planning', () => {
	const projects = [
		p('a', null, { position: 1 }),
		p('b', null, { position: 0 }),
		p('c', null),
		p('a1', 'a', { position: 0 }),
		p('a2', 'a', { position: 1 }),
		p('orphan', 'hidden-parent', { createdAt: '2026-01-01T00:00:00Z' })
	];
	it('sorts by position, then createdAt, then id; unpositioned last', () => {
		expect(buildTree(projects).map((n) => n.project.id)).toEqual(['b', 'a', 'orphan', 'c'].sort((x, y) => compareSiblings(projects.find((q) => q.id === x)!, projects.find((q) => q.id === y)!)));
		expect(buildTree(projects)[0].project.id).toBe('b');
		expect(siblingsOf(projects, 'a').map((x) => x.id)).toEqual(['a1', 'a2']);
		// a parent that is not visible counts as top level
		expect(siblingsOf(projects, null).map((x) => x.id)).toContain('orphan');
	});
	it('plans reorders among siblings without re-parenting', () => {
		expect(planDrop(projects, 'c', 'b', 'before')).toEqual({ parentID: null, index: 0, reparent: false });
		expect(planDrop(projects, 'b', 'a', 'after')).toEqual({ parentID: null, index: 1, reparent: false });
		expect(planDrop(projects, 'b', 'b', 'before')).toBeNull();
		// dropping right where it already is
		expect(planDrop(projects, 'b', 'a', 'before')).toBeNull();
	});
	it('plans moves under another parent and blocks cycles', () => {
		expect(planDrop(projects, 'c', 'a', 'into')).toEqual({ parentID: 'a', index: 2, reparent: true });
		expect(planDrop(projects, 'c', 'a1', 'before')).toEqual({ parentID: 'a', index: 0, reparent: true });
		expect(planDrop(projects, 'a', 'a1', 'into')).toBeNull();
		expect(planDrop(projects, 'a', 'a2', 'after')).toBeNull();
	});
	it('plans menu steps and "move to"', () => {
		expect(planStep(projects, 'b', -1)).toBeNull();
		expect(planStep(projects, 'b', 1)).toEqual({ parentID: null, index: 1, reparent: false });
		expect(planMoveTo(projects, 'c', 'a')).toEqual({ parentID: 'a', index: 2, reparent: true });
		expect(planMoveTo(projects, 'a1', 'a')).toBeNull();
		expect(planMoveTo(projects, 'a1', null)).toEqual({ parentID: null, index: 4, reparent: true });
	});
});

describe('legacy localStorage import', () => {
	function storage(initial: Record<string, string>) {
		const data = { ...initial };
		const s: LegacyStorage & { data: Record<string, string> } = {
			data,
			getItem: (k) => data[k] ?? null,
			removeItem: (k) => void delete data[k]
		};
		return s;
	}
	function fakeApi(fail?: (op: string, id: string) => Error | undefined) {
		const log: string[] = [];
		const step = (op: string, id: string, extra = '') => {
			const err = fail?.(op, id);
			if (err) throw err;
			log.push(`${op}:${id}${extra}`);
		};
		return {
			log,
			api: {
				putFavorite: async (id: string) => (step('fav', id), { items: [] }),
				updateProject: async (proj: Project, c: { description?: string }) => (step('desc', proj.id, `=${c.description}`), proj),
				patchProjectPrefs: async (id: string, rev: number, c: object) => (step('prefs', id, JSON.stringify(c)), { revision: rev + 1 } as ProjectPrefs)
			}
		};
	}
	const legacy = () =>
		storage({
			'todo.favorites': JSON.stringify(['a', 'gone', 'b']),
			'todo.projectDescriptions': JSON.stringify({ a: ' Hello ', b: 'Keep server', gone: 'x' }),
			'todo.projectDisplay': JSON.stringify({ a: { view: 'board', sort: 'title', grouping: 'none', showDone: false }, b: { view: 'board' }, bad: { view: 'x' } })
		});

	it('uploads once, respects server state and clears the keys', async () => {
		const s = legacy();
		const { api, log } = fakeApi();
		const projects = [p('a'), p('b', null, { description: 'server text' })];
		const prefs = [{ projectID: 'b', revision: 2 } as ProjectPrefs];
		expect(hasLegacyState(s)).toBe(true);
		const r = await importLegacyState(api, s, projects, prefs);
		expect(log).toEqual([
			'fav:a',
			'fav:b',
			'desc:a=Hello',
			'prefs:a{"view":"board","sort":"title","grouping":"none","showCompleted":false}'
		]);
		expect(r).toMatchObject({ favorites: 2, descriptions: 1, display: 1, cleared: true });
		expect(s.data).toEqual({});
		expect(hasLegacyState(s)).toBe(false);
	});
	it('skips favourites when the account already has some', async () => {
		const s = legacy();
		const { api, log } = fakeApi();
		await importLegacyState(api, s, [p('a', null, { isFavorite: true }), p('b')], []);
		expect(log.some((l) => l.startsWith('fav:'))).toBe(false);
		expect(s.data).toEqual({});
	});
	it('keeps the keys after a transient failure and skips permanent per-item failures', async () => {
		const s = legacy();
		const down = fakeApi((op) => (op === 'desc' ? new ApiError(0, 'network') : undefined));
		const r1 = await importLegacyState(down.api, s, [p('a'), p('b')], []);
		expect(r1.cleared).toBe(false);
		expect(Object.keys(s.data)).toHaveLength(3);

		const s2 = legacy();
		const denied = fakeApi((op, id) => (op === 'desc' && id === 'a' ? new ApiError(403) : undefined));
		const r2 = await importLegacyState(denied.api, s2, [p('a'), p('b')], []);
		expect(r2.cleared).toBe(true);
		expect(s2.data).toEqual({});
	});
	it('tolerates broken JSON', async () => {
		const s = storage({ 'todo.favorites': '{oops', 'todo.projectDisplay': '[]' });
		const { api, log } = fakeApi();
		const r = await importLegacyState(api, s, [p('a')], []);
		expect(log).toEqual([]);
		expect(r.cleared).toBe(true);
	});
});

describe('project mode (classic | management)', () => {
	it('defaults to classic without stored prefs and honours the server-derived value', async () => {
		const { modeOfPrefs, defaultPrefs } = await import('../src/lib/projectState.js');
		expect(modeOfPrefs(undefined)).toBe('classic');
		expect(modeOfPrefs(defaultPrefs('a'))).toBe('classic');
		expect(modeOfPrefs({ mode: 'management' })).toBe('management');
		expect(modeOfPrefs({ mode: 'classic' })).toBe('classic');
		// Servers that predate the field keep the full feature set.
		expect(modeOfPrefs({})).toBe('management');
	});
	it('marks an explicit choice as user-chosen and sends only mode', async () => {
		const { applyPrefsChange, defaultPrefs, displayChangeToPrefs } = await import('../src/lib/projectState.js');
		const next = applyPrefsChange(defaultPrefs('a'), { mode: 'management' });
		expect(next.mode).toBe('management');
		expect(next.modeSource).toBe('user');
		expect(displayChangeToPrefs({ view: 'board' })).toEqual({ view: 'board' });
	});
	it('collects descendants breadth first and survives cycles', async () => {
		const { descendantIDs } = await import('../src/lib/projectState.js');
		const ps = [
			{ id: 'r', parentID: null },
			{ id: 'a', parentID: 'r' },
			{ id: 'b', parentID: 'a' },
			{ id: 'x', parentID: 'b' },
			{ id: 'o', parentID: null }
		];
		expect(descendantIDs(ps, 'r')).toEqual(['a', 'b', 'x']);
		expect(descendantIDs([{ id: 'p', parentID: 'q' }, { id: 'q', parentID: 'p' }], 'p')).toEqual(['q']);
		expect(descendantIDs(ps, 'o')).toEqual([]);
	});
});
