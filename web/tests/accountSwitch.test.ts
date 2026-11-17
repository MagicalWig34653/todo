import { beforeEach, describe, expect, it, vi } from 'vitest';

type Deferred<T> = { promise: Promise<T>; resolve: (v: T) => void };
function deferred<T>(): Deferred<T> {
	let resolve!: (v: T) => void;
	const promise = new Promise<T>((r) => (resolve = r));
	return { promise, resolve };
}

const project = (id: string) => ({ id, name: id }) as never;
const task = (id: string) => ({ id, title: id }) as never;

describe('account switch in the same SPA', () => {
	let fail: boolean;
	let projects: () => Promise<unknown>;
	beforeEach(() => {
		vi.resetModules();
		fail = false;
		projects = async () => [project('a-project')];
	});

	async function load() {
		vi.stubGlobal('localStorage', { getItem: () => null, setItem: () => undefined, removeItem: () => undefined });
		vi.doMock('../src/lib/api', async () => {
			const real = await vi.importActual<typeof import('../src/lib/api')>('../src/lib/api');
			const ok = (v: unknown) => async () => {
				if (fail) throw new real.ApiError(503, 'unavailable');
				return v;
			};
			return {
				...real,
				api: {
					listProjects: () => (fail ? Promise.reject(new real.ApiError(503, 'unavailable')) : projects()),
					listTasks: ok([task('a-task')]),
					listTeams: ok([]),
					teamInvitations: ok([]),
					listLabels: ok({ items: [] }),
					listFilters: ok({ items: [] }),
					listProjectPrefs: ok({ items: [] }),
					commandCenter: ok({ summary: null }),
					logout: async () => undefined,
					passwordLogin: async () => ({ user: { id: 'b' } })
				}
			};
		});
		const { workspace } = await import('../src/lib/workspace.svelte');
		const { auth } = await import('../src/lib/auth.svelte');
		return { workspace, auth };
	}

	it('does not show account A data after B signs in and B lists fail', async () => {
		const { workspace, auth } = await load();
		auth.user = { id: 'a' } as never;
		await workspace.reloadProjects();
		await workspace.reloadTasks();
		expect(workspace.projects).toHaveLength(1);

		await auth.logout();
		expect(workspace.projects).toEqual([]);
		expect(workspace.tasks).toEqual([]);

		fail = true;
		await auth.loginWithPassword('b', 'pw');
		await workspace.reloadAll().catch(() => undefined);
		expect(workspace.projects).toEqual([]);
		expect(workspace.tasks).toEqual([]);
		expect(workspace.projectsLoaded).toBe(false);
	});

	it('resets when the user changes without a logout (session expiry, 401 handlers)', async () => {
		const { workspace, auth } = await load();
		auth.user = { id: 'a' } as never;
		await workspace.reloadTasks();
		auth.user = { id: 'b' } as never;
		expect(workspace.tasks).toEqual([]);
	});

	it('discards a late answer of an A request after the switch', async () => {
		const { workspace, auth } = await load();
		auth.user = { id: 'a' } as never;
		const late = deferred<unknown>();
		projects = () => late.promise;
		const pending = workspace.reloadProjects();
		await auth.logout();
		auth.user = { id: 'b' } as never;
		late.resolve([project('a-project')]);
		await pending;
		expect(workspace.projects).toEqual([]);
		expect(workspace.projectsLoaded).toBe(false);
	});
});
