import { describe, expect, it } from 'vitest';
import { createApi, type OverviewProject } from '../src/lib/api';
import {
	EXPANDED_KEY, QUIET_AFTER_MS, allowRefetch, buildSummary, buildCommit, buildStatusOf, shortCommit, defaultExpanded, groupProjects, isEmptyNow, isExpanded, isOrphaned, isQuiet,
	loadExpanded, percentOf, projectStats, saveExpanded, buildEventHead
} from '../src/lib/now';
import { t } from '../src/lib/i18n/index';

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


describe('waiting projects are never quiet', () => {
	const old = QUIET_AFTER_MS * 3;
	it('keeps an old project with an open question or review in the active group', () => {
		const g = groupProjects([
			project('q', { lastActivityAt: ago(old), openQuestions: [open('q1')] }),
			project('r', { lastActivityAt: ago(old), pendingReviews: [open('r1')] }),
			project('z', { lastActivityAt: ago(old) })
		], NOW);
		expect(g.active.map((p) => p.projectID).sort()).toEqual(['q', 'r']);
		expect(g.quiet.map((p) => p.projectID)).toEqual(['z']);
	});
	it('keeps a project with a fresh session active, an old session does not', () => {
		const ses = (age: number) => [{ sessionName: 's', activity: 'a', updatedAt: ago(age * 1000), ageSeconds: age, orphaned: false }];
		const g = groupProjects([
			project('fresh', { lastActivityAt: ago(old), sessions: ses(3600) }),
			project('stale', { lastActivityAt: ago(old), sessions: ses(QUIET_AFTER_MS / 1000 + 5) })
		], NOW);
		expect(g.active.map((p) => p.projectID)).toEqual(['fresh']);
		expect(g.quiet.map((p) => p.projectID)).toEqual(['stale']);
	});
	it('sorts waiting projects first, by waiting count and then by activity, before newer calm projects', () => {
		const g = groupProjects([
			project('new', { lastActivityAt: ago(1000) }),
			project('w1-old', { lastActivityAt: ago(old), pendingReviews: [open('a')] }),
			project('w2-old', { lastActivityAt: ago(old * 2), openQuestions: [open('b'), open('c')] }),
			project('w1-new', { lastActivityAt: ago(5000), openQuestions: [open('d')] })
		], NOW);
		expect(g.active.map((p) => p.projectID)).toEqual(['w2-old', 'w1-new', 'w1-old', 'new']);
	});
	it('expands waiting projects by default and lets the stored user choice win', () => {
		const p = project('w', { lastActivityAt: ago(old), pendingReviews: [open('a')] });
		const quiet = groupProjects([p], NOW).quiet.includes(p);
		expect(quiet).toBe(false);
		expect(isExpanded({}, 'w', quiet)).toBe(true);
		expect(isExpanded({ w: false }, 'w', quiet)).toBe(false);
	});
});

describe('build commit', () => {
	it('shows the first 7 characters only when present', () => {
		const b = { taskID: '1', buildID: 'b', createdAt: '' };
		expect(buildCommit(b)).toBeNull();
		expect(buildCommit({ ...b, commit: '' })).toBeNull();
		expect(buildCommit({ ...b, commit: 'abcdef0123456789' })).toBe('abcdef0');
		expect(buildCommit({ ...b, commit: ' abc ' })).toBe('abc');
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

describe('build status', () => {
	it('maps known statuses to a message key and tone, nothing without status', () => {
		expect(buildStatusOf('building')).toEqual({ key: 'build.status.building', tone: 'info' });
		expect(buildStatusOf('succeeded')).toEqual({ key: 'build.status.succeeded', tone: 'ok' });
		expect(buildStatusOf('failed')).toEqual({ key: 'build.status.failed', tone: 'danger' });
		expect(buildStatusOf(undefined)).toBeNull();
		expect(buildStatusOf(null)).toBeNull();
		expect(buildStatusOf('weird')).toBeNull();
	});
	it('shortens commits to 7 characters', () => {
		expect(shortCommit('abcdef0123456789')).toBe('abcdef0');
		expect(shortCommit('  ')).toBeNull();
		expect(shortCommit(undefined)).toBeNull();
	});
	it('does not change the quiet rule: a failed build alone keeps a project quiet', () => {
		const p = { ...project('x', { lastActivityAt: ago(3 * 24 * 3600 * 1000) }), builds: [{ taskID: '1', buildID: 'b', createdAt: '', status: 'failed' as const }] };
		expect(isQuiet(p, NOW)).toBe(true);
	});
});

describe('build status event', () => {
	it('heads the line with "Build <label>:" or "Build:" without a label', () => {
		expect(t(...buildEventHead('iOS 42'))).toBe('Build iOS 42:');
		expect(t(...buildEventHead('  '))).toBe('Build:');
		expect(t(...buildEventHead(null))).toBe('Build:');
		expect(t(...buildEventHead(undefined))).toBe('Build:');
	});
	it('accepts the new optional event fields', () => {
		const e: import('../src/lib/api').OverviewEvent = { taskID: '1', taskTitle: 'T', kind: 'build.status_changed', actorType: 'integration', createdAt: '', label: 'Web 1', platform: 'web', status: 'failed' };
		expect(buildStatusOf(e.status)?.tone).toBe('danger');
	});
});
