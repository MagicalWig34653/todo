import { describe, expect, it } from 'vitest';
import { createApi, type OverviewProject } from '../src/lib/api';
import {
	EXPANDED_KEY, QUIET_AFTER_MS, allowRefetch, buildSummary, defaultExpanded, groupProjects, isEmptyNow, isExpanded, isOrphaned,
	loadExpanded, percentOf, projectStats, saveExpanded
} from '../src/lib/now';

const NOW = new Date('2026-11-18T12:00:00Z');
const ago = (ms: number) => new Date(NOW.getTime() - ms).toISOString();
const project = (id: string, over: Partial<OverviewProject> = {}): OverviewProject => ({
	projectID: id, projectName: id, lastActivityAt: ago(60_000), runningTasks: [], sessions: [], agentJobs: [], builds: [],
	openQuestions: [], pendingReviews: [], recentActivity: [], ...over
});
const open = (id: string) => ({ id, taskID: 't' + id, taskTitle: 'T', text: 'x', createdAt: ago(1000) });
function memoryStorage() {
	const m = new Map<string, string>();
	return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
}

describe('projectStats', () => {
	it('counts running cards, sessions, waiting items and builds', () => {
		const p = project('a', {
			runningTasks: [{ taskID: '1', title: 'x', ageSeconds: 5 }],
			sessions: [{ sessionName: 's', activity: 'a', updatedAt: ago(1), ageSeconds: 1, orphaned: false }],
			openQuestions: [open('q')], pendingReviews: [open('r1'), open('r2')],
			builds: [{ taskID: '1', buildID: 'b', createdAt: ago(1) }]
		});
		expect(projectStats(p)).toEqual({ running: 1, sessions: 1, waiting: 3, builds: 1 });
	});
});

describe('groupProjects', () => {
	it('sorts by last activity and moves projects older than 24 h to quiet', () => {
		const g = groupProjects([
			project('old', { lastActivityAt: ago(QUIET_AFTER_MS + 1000) }),
			project('older', { lastActivityAt: ago(QUIET_AFTER_MS * 3) }),
			project('b', { lastActivityAt: ago(60_000) }),
			project('a', { lastActivityAt: ago(5_000) })
		], NOW);
		expect(g.active.map((p) => p.projectID)).toEqual(['a', 'b']);
		expect(g.quiet.map((p) => p.projectID)).toEqual(['old', 'older']);
	});
	it('keeps an old project in the active group while a card is running', () => {
		const g = groupProjects([project('x', { lastActivityAt: ago(QUIET_AFTER_MS * 2), runningTasks: [{ taskID: '1', title: 't', ageSeconds: 1 }] })], NOW);
		expect(g.active).toHaveLength(1);
		expect(g.quiet).toHaveLength(0);
	});
	it('treats an invalid date as quiet', () => {
		expect(groupProjects([project('x', { lastActivityAt: 'nope' })], NOW).quiet).toHaveLength(1);
	});
});

describe('expanded state', () => {
	it('defaults to open for active and closed for quiet projects', () => {
		expect(defaultExpanded(false)).toBe(true);
		expect(defaultExpanded(true)).toBe(false);
		expect(isExpanded({}, 'a', true)).toBe(false);
		expect(isExpanded({ a: true }, 'a', true)).toBe(true);
		expect(isExpanded({ a: false }, 'a', false)).toBe(false);
	});
	it('round-trips through storage and survives broken storage', () => {
		const s = memoryStorage();
		saveExpanded({ a: true, b: false }, s);
		expect(loadExpanded(s)).toEqual({ a: true, b: false });
		s.setItem(EXPANDED_KEY, '{broken');
		expect(loadExpanded(s)).toEqual({});
		s.setItem(EXPANDED_KEY, '[1]');
		expect(loadExpanded(s)).toEqual({});
		const throwing = { getItem: () => { throw new Error('denied'); }, setItem: () => { throw new Error('denied'); } };
		expect(loadExpanded(throwing)).toEqual({});
		expect(() => saveExpanded({ a: true }, throwing)).not.toThrow();
		expect(loadExpanded(null)).toEqual({});
	});
});

describe('details', () => {
	it('flags sessions as orphaned from the server flag or after 30 minutes', () => {
		expect(isOrphaned({ sessionName: 's', activity: '', updatedAt: '', ageSeconds: 10, orphaned: true })).toBe(true);
		expect(isOrphaned({ sessionName: 's', activity: '', updatedAt: '', ageSeconds: 1801, orphaned: false })).toBe(true);
		expect(isOrphaned({ sessionName: 's', activity: '', updatedAt: '', ageSeconds: 1800, orphaned: false })).toBe(false);
	});
	it('reads an optional percentage defensively', () => {
		expect(percentOf({ taskID: '1', title: 't', ageSeconds: 1 })).toBeNull();
		expect(percentOf({ taskID: '1', title: 't', ageSeconds: 1, percent: 49.6 })).toBe(50);
		expect(percentOf({ taskID: '1', title: 't', ageSeconds: 1, percent: 140 })).toBe(100);
		expect(percentOf({ taskID: '1', title: 't', ageSeconds: 1, percent: -4 })).toBe(0);
	});
	it('summarises a build from label and platform only', () => {
		expect(buildSummary({ taskID: '1', buildID: 'abc', label: 'CI 5', platform: 'ios', createdAt: '' })).toBe('CI 5 · ios');
		expect(buildSummary({ taskID: '1', buildID: 'abc', label: null, platform: null, createdAt: '' })).toBe('abc');
	});
	it('detects the empty state', () => {
		expect(isEmptyNow([])).toBe(true);
		expect(isEmptyNow([project('a')])).toBe(false);
	});
});

describe('allowRefetch', () => {
	it('never refetches faster than every 30 s in polling mode, but follows live hints at once', () => {
		expect(allowRefetch(1000, 1000 + 5_000, 'poll')).toBe(false);
		expect(allowRefetch(1000, 1000 + 30_000, 'poll')).toBe(true);
		expect(allowRefetch(1000, 1000 + 2_000, 'live')).toBe(true);
		expect(allowRefetch(null, 5, 'poll')).toBe(true);
	});
});

describe('api.overviewNow', () => {
	it('reads GET /v1/overview/now', async () => {
		let url = '';
		const api = createApi(async (u) => {
			url = String(u);
			return new Response(JSON.stringify({ serverTime: NOW.toISOString(), projects: [] }), { status: 200 });
		});
		expect((await api.overviewNow()).projects).toEqual([]);
		expect(url).toBe('/v1/overview/now');
	});
});
