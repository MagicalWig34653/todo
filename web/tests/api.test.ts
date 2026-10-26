import { describe, expect, it } from 'vitest';
import { ApiError, createApi, type FetchLike } from '../src/lib/api';
import { buildTree, selfAndDescendants } from '../src/lib/projectTree';

function recorder(response: Response) {
	const calls: { url: string; init?: RequestInit }[] = [];
	const fetchFn: FetchLike = async (url, init) => {
		calls.push({ url, init });
		return response;
	};
	return { calls, api: createApi(fetchFn) };
}

describe('api client', () => {
	it('sends JSON content type and version on PATCH', async () => {
		const { calls, api } = recorder(Response.json({ id: 'p', parentID: null, name: 'x', version: 2 }));
		await api.renameProject({ id: 'p', parentID: null, name: 'a', version: 1 }, 'x');
		expect(calls[0].url).toBe('/v1/projects/p');
		expect(calls[0].init?.method).toBe('PATCH');
		expect((calls[0].init?.headers as Record<string, string>)['Content-Type']).toBe('application/json');
		expect(JSON.parse(calls[0].init?.body as string)).toEqual({ version: 1, name: 'x' });
	});

	it('uses moveToRoot when moving to the top level', async () => {
		const { calls, api } = recorder(Response.json({}));
		await api.moveProject({ id: 'p', parentID: 'q', name: 'a', version: 3 }, null);
		expect(JSON.parse(calls[0].init?.body as string)).toEqual({ version: 3, moveToRoot: true });
	});

	it('maps 409 version_conflict to a conflict error', async () => {
		const { api } = recorder(Response.json({ error: true, reason: 'version_conflict' }, { status: 409 }));
		const error = await api.deleteTask('t').catch((e) => e);
		expect(error).toBeInstanceOf(ApiError);
		expect(error.isConflict).toBe(true);
	});

	it('returns undefined for 204 and reports network failure as status 0', async () => {
		const { api } = recorder(new Response(null, { status: 204 }));
		expect(await api.logout()).toBeUndefined();
		const failing = createApi(async () => {
			throw new TypeError('offline');
		});
		await expect(failing.me()).rejects.toMatchObject({ status: 0 });
	});
});

describe('project tree', () => {
	const projects = [
		{ id: 'a', parentID: null, name: 'A', version: 1 },
		{ id: 'b', parentID: 'a', name: 'B', version: 1 },
		{ id: 'c', parentID: 'b', name: 'C', version: 1 },
		{ id: 'd', parentID: null, name: 'D', version: 1 }
	];
	it('nests children', () => {
		const tree = buildTree(projects);
		expect(tree.map((n) => n.project.id)).toEqual(['a', 'd']);
		expect(tree[0].children[0].children[0].project.id).toBe('c');
	});
	it('collects descendants as invalid move targets', () => {
		expect([...selfAndDescendants(projects, 'a')].sort()).toEqual(['a', 'b', 'c']);
	});
});
