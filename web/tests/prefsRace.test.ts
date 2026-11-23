import { beforeEach, describe, expect, it, vi } from 'vitest';

// Card 188D611F: a read of the project preferences that was started before a local write (the view taken from /project/<id>/board)
// and answered after it must not overwrite the optimistic value. Seen on a slow CI runner: GET prefs at 6803 ms, PATCH at 6804 ms,
// the board URL ended in the list view.
type Deferred<T> = { promise: Promise<T>; resolve: (v: T) => void };
function deferred<T>(): Deferred<T> {
	let resolve!: (v: T) => void;
	const promise = new Promise<T>((r) => (resolve = r));
	return { promise, resolve };
}
const prefs = (view: string, revision: number) => ({ projectID: 'p1', revision, view, mode: 'classic', modeSource: 'user' }) as never;

describe('project preferences: late reads versus local writes', () => {
	beforeEach(() => vi.resetModules());

	async function load(read: () => Promise<unknown>, patch: () => Promise<unknown>) {
		vi.stubGlobal('localStorage', { getItem: () => null, setItem: () => undefined, removeItem: () => undefined });
		vi.doMock('../src/lib/api', async () => {
			const real = await vi.importActual<typeof import('../src/lib/api')>('../src/lib/api');
			return { ...real, api: { listProjectPrefs: read, patchProjectPrefs: patch, getProjectPrefs: async () => prefs('list', 1) } };
		});
		const { workspace } = await import('../src/lib/workspace.svelte');
		return workspace;
	}

	it('refreshPrefs answered after the write keeps the written view', async () => {
		const late = deferred<{ items: unknown[] }>();
		const workspace = await load(() => late.promise, async () => prefs('board', 1));
		const refreshing = workspace.refreshPrefs();
		// The URL applies the board view while the read is still in flight.
		await workspace.setDisplay('p1', { view: 'board' });
		expect(workspace.prefs['p1'].view).toBe('board');
		// The server answered the read before it had the write.
		late.resolve({ items: [prefs('list', 0)] });
		await refreshing;
		expect(workspace.prefs['p1'].view).toBe('board');
	});

	it('other projects still take the answer of a read that overlapped a write', async () => {
		const late = deferred<{ items: unknown[] }>();
		const workspace = await load(() => late.promise, async () => prefs('board', 1));
		const refreshing = workspace.refreshPrefs();
		await workspace.setDisplay('p1', { view: 'board' });
		late.resolve({ items: [prefs('list', 0), { ...(prefs('list', 4) as object), projectID: 'p2' } as never] });
		await refreshing;
		expect(workspace.prefs['p1'].view).toBe('board');
		expect(workspace.prefs['p2'].revision).toBe(4);
	});
});
