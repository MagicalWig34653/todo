import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { createApi, type FetchLike, type ProjectSyncEntry } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import { LIVE_REFRESH_MS, newerThan, sameList, startLiveRefresh } from '../src/lib/liveRefresh';
import { canEditSync, filterSync, parseStaleAfter, sortSync, syncChip, syncCounts } from '../src/lib/syncState';

const entry = (projectID: string, state: 'fresh' | 'stale' | 'never', daysSince?: number): ProjectSyncEntry => ({
	projectID, name: projectID, sync: { state, daysSince, lastSyncedAt: state === 'never' ? null : '2026-10-01T00:00:00Z' }
});

describe('sync chip and filters', () => {
	it('maps states to tone and days', () => {
		expect(syncChip({ state: 'fresh', daysSince: 1 })).toEqual({ state: 'fresh', tone: 'success', days: 1 });
		expect(syncChip({ state: 'stale', daysSince: 7.9 })).toEqual({ state: 'stale', tone: 'warning', days: 7 });
		expect(syncChip({ state: 'never' })).toEqual({ state: 'never', tone: 'default', days: 0 });
		expect(syncChip(null).state).toBe('never');
		expect(syncChip({ state: 'weird' as never }).state).toBe('never');
	});
	it('filters and orders: stale (oldest first), never, fresh', () => {
		const all = [entry('f', 'fresh', 0), entry('n', 'never'), entry('s2', 'stale', 9), entry('s1', 'stale', 4)];
		expect(filterSync(all, 'all')).toHaveLength(4);
		expect(filterSync(all, 'attention').map((e) => e.projectID)).toEqual(['n', 's2', 's1']);
		expect(filterSync(all, 'stale')).toHaveLength(2);
		expect(filterSync(all, 'never')).toHaveLength(1);
		expect(filterSync(null, 'stale')).toEqual([]);
		expect(sortSync(all).map((e) => e.projectID)).toEqual(['s2', 's1', 'n', 'f']);
		expect(syncCounts(all)).toEqual({ fresh: 1, stale: 2, never: 1 });
	});
	it('validates the threshold (1-365 whole days)', () => {
		expect(parseStaleAfter('3')).toBe(3);
		expect(parseStaleAfter(' 365 ')).toBe(365);
		for (const bad of ['0', '366', '-1', '1.5', '', 'abc', '1e2']) expect(parseStaleAfter(bad)).toBeNull();
	});
	it('allows threshold edits from the edit role up', () => {
		expect(canEditSync('edit')).toBe(true);
		expect(canEditSync('manage')).toBe(true);
		expect(canEditSync('comment')).toBe(false);
		expect(canEditSync(null)).toBe(false);
	});
	it('uses localized texts with the day count', () => {
		expect(de['sync.stale'].replace('{days}', '5')).toBe('Abgleich veraltet (5 Tage)');
		expect(de['sync.never']).toBe('Nie abgeglichen');
	});
});

describe('sync api (mocked fetch)', () => {
	it('reads the detail and changes the threshold with PUT', async () => {
		const calls: { url: string; init?: RequestInit }[] = [];
		const fetchFn: FetchLike = async (url, init) => {
			calls.push({ url, init });
			return new Response(JSON.stringify({ bound: true, state: 'stale', staleAfterDays: 5, lastSummary: 'x' }), { status: 200 });
		};
		const api = createApi(fetchFn);
		expect((await api.getProjectSync('p1')).lastSummary).toBe('x');
		await api.putProjectSync('p1', { staleAfterDays: 5 });
		expect(calls[0].url).toBe('/v1/projects/p1/sync');
		expect(calls[1].init?.method).toBe('PUT');
		expect(JSON.parse(calls[1].init!.body as string)).toEqual({ staleAfterDays: 5 });
	});
	it('surfaces 403 for missing rights', async () => {
		const api = createApi(async () => new Response(JSON.stringify({ reason: 'forbidden' }), { status: 403 }));
		await expect(api.putProjectSync('p1', { staleAfterDays: 2 })).rejects.toMatchObject({ status: 403 });
	});
});

describe('live refresh', () => {
	function fakeEnv(visible = true) {
		const doc = { visibilityState: visible ? 'visible' : 'hidden', handlers: new Map<string, () => void>(),
			addEventListener(n: string, h: () => void) { this.handlers.set(n, h); }, removeEventListener(n: string) { this.handlers.delete(n); } };
		const win = { handlers: new Map<string, () => void>(),
			addEventListener(n: string, h: () => void) { this.handlers.set(n, h); }, removeEventListener(n: string) { this.handlers.delete(n); } };
		return { doc, win };
	}
	it('refreshes on the interval while visible, on focus and on visibility, not while hidden', async () => {
		vi.useFakeTimers();
		const { doc, win } = fakeEnv();
		const fn = vi.fn(async () => {});
		const stop = startLiveRefresh(fn, { doc: doc as never, win: win as never });
		await vi.advanceTimersByTimeAsync(LIVE_REFRESH_MS);
		expect(fn).toHaveBeenCalledTimes(1);
		win.handlers.get('focus')!();
		await vi.advanceTimersByTimeAsync(0);
		doc.handlers.get('visibilitychange')!();
		await vi.advanceTimersByTimeAsync(0);
		expect(fn).toHaveBeenCalledTimes(3);
		doc.visibilityState = 'hidden';
		await vi.advanceTimersByTimeAsync(LIVE_REFRESH_MS * 2);
		expect(fn).toHaveBeenCalledTimes(3);
		stop();
		expect(win.handlers.size + doc.handlers.size).toBe(0);
		doc.visibilityState = 'visible';
		await vi.advanceTimersByTimeAsync(LIVE_REFRESH_MS * 2);
		expect(fn).toHaveBeenCalledTimes(3);
		vi.useRealTimers();
	});
	it('skips overlapping runs and swallows errors', async () => {
		vi.useFakeTimers();
		const { doc, win } = fakeEnv();
		let release!: () => void;
		const fn = vi.fn(() => new Promise<void>((res, rej) => { release = () => rej(new Error('boom')); void res; }));
		startLiveRefresh(fn, { doc: doc as never, win: win as never });
		await vi.advanceTimersByTimeAsync(LIVE_REFRESH_MS * 3);
		expect(fn).toHaveBeenCalledTimes(1);
		release();
		await vi.advanceTimersByTimeAsync(LIVE_REFRESH_MS);
		expect(fn).toHaveBeenCalledTimes(2);
		vi.useRealTimers();
	});
	it('detects unchanged lists and merges newer entries', () => {
		expect(sameList([{ a: 1 }], [{ a: 1 }])).toBe(true);
		expect(sameList([{ a: 1 }], [{ a: 2 }])).toBe(false);
		const e = (id: string) => ({ id });
		expect(newerThan([e('3'), e('2')], [e('4'), e('3'), e('2')])).toEqual({ fresh: [e('4')], gap: false });
		expect(newerThan([e('3')], [e('3')])).toEqual({ fresh: [], gap: false });
		expect(newerThan([], [e('1')])).toEqual({ fresh: [e('1')], gap: false });
		expect(newerThan([e('1')], [e('9'), e('8')]).gap).toBe(true);
	});
});

describe('dark mode tokens', () => {
	const css = readFileSync(join(__dirname, '../src/routes/layout.css'), 'utf8');
	const block = (sel: string) => {
		const start = css.indexOf(`${sel} {`);
		const body = css.slice(start, css.indexOf('\n}', start));
		return new Set([...body.matchAll(/^\s*(--[\w-]+):/gm)].map((m) => m[1]));
	};
	it('defines every colour token of :root also in .dark', () => {
		const light = block(':root');
		const dark = block('.dark');
		const missing = [...light].filter((k) => !dark.has(k) && !k.startsWith('--radius'));
		expect(missing).toEqual([]);
	});
	it('board and overview components use theme tokens only (no fixed palette colours)', () => {
		const dir = join(__dirname, '../src/lib/components');
		const files = ['BoardView.svelte', 'ProjectBoard.svelte', 'ProjectItem.svelte', 'TaskChips.svelte', 'AgentsView.svelte',
			...readdirSync(join(dir, 'overview')).map((f) => join('overview', f))];
		const fixed = /\b(?:bg|text|border)-(?:white|black|gray|zinc|slate|neutral|stone|red|green|blue|amber|yellow)(?:-\d+)?\b|#[0-9a-fA-F]{3,8}\b/;
		const offenders = files.filter((f) => fixed.test(readFileSync(join(dir, f), 'utf8')));
		expect(offenders).toEqual([]);
	});
});
