import { describe, expect, it } from 'vitest';
import { createApi, type NowActive, type NowBlock, type NowDone, type NowWaiting, type OverviewNow, type OverviewProject } from '../src/lib/api';
import {
	NOW_DONE_LIMIT, blockOf, cleanBlock, dueInfo, durationText, isEmptyNow, isEndedText, isQuiet, lifeSignText, nowEntry, nowEntryLabel, projectStats, recentDone, serverClock,
	showEmptyPage, sinceText, visibleSessions, waitingCard
} from '../src/lib/now';

const REF = new Date('2026-11-24T12:00:00Z');
const ago = (ms: number) => new Date(REF.getTime() - ms).toISOString();
const MIN = 60_000;
const HOUR = 60 * MIN;

const active = (over: Partial<NowActive> = {}): NowActive => ({
	kind: 'task', projectID: 'p', projectName: 'P', taskID: 't', title: 'T', text: 'Tests laufen', lastSignAt: ago(3 * MIN), ageSeconds: 180, ...over
});
const waiting = (over: Partial<NowWaiting> = {}): NowWaiting => ({
	kind: 'question', id: 'q1', projectID: 'p', projectName: 'P', taskID: 't1', taskTitle: 'T', text: 'Frage?', createdAt: ago(MIN), ...over
});
const done = (id: string, ms: number): NowDone => ({ taskID: id, title: id, projectID: 'p', projectName: 'P', doneAt: ago(ms) });
const block = (over: Partial<NowBlock> = {}): NowBlock => ({
	counts: { running: 0, waiting: 0, recentlyDone: 0, silent: 0 }, running: [], waiting: [], recentlyDone: [], silent: [], ...over
});
const project = (over: Partial<OverviewProject> = {}): OverviewProject => ({
	projectID: 'p', projectName: 'P', lastActivityAt: ago(MIN), runningTasks: [], sessions: [], agentJobs: [], builds: [], openQuestions: [], pendingReviews: [], recentActivity: [], ...over
});
const session = (activity: string) => ({ sessionName: 's', activity, updatedAt: ago(MIN), ageSeconds: 60, orphaned: false });

describe('isEndedText', () => {
	it('matches sentences that start with "Beendet", case-insensitive and after trim', () => {
		expect(isEndedText('Beendet')).toBe(true);
		expect(isEndedText('  beendet: alles erledigt')).toBe(true);
		expect(isEndedText('BEENDET.')).toBe(true);
		expect(isEndedText('Nicht beendet')).toBe(false);
		expect(isEndedText('Arbeit beendet')).toBe(false);
		expect(isEndedText('')).toBe(false);
		expect(isEndedText(undefined)).toBe(false);
	});
});

describe('project session lists hide ended sentences', () => {
	it('drops "Beendet" sessions from the list, the stats and the quiet rule', () => {
		const p = project({ sessions: [session('Beendet: fertig'), session('Prüft Migration')], lastActivityAt: ago(3 * 24 * HOUR) });
		expect(visibleSessions(p).map((s) => s.activity)).toEqual(['Prüft Migration']);
		expect(projectStats(p).sessions).toBe(1);
		expect(isQuiet(p, REF)).toBe(false);
		const onlyEnded = project({ sessions: [session('beendet')], lastActivityAt: ago(3 * 24 * HOUR) });
		expect(projectStats(onlyEnded).sessions).toBe(0);
		expect(isQuiet(onlyEnded, REF)).toBe(true);
	});
});

describe('durationText', () => {
	it('uses minutes, hours and days', () => {
		expect(durationText(5)).toBe('weniger als 1 Min.');
		expect(durationText(60)).toBe('1 Min.');
		expect(durationText(59 * 60)).toBe('59 Min.');
		expect(durationText(3 * 3600 + 20)).toBe('3 Std.');
		expect(durationText(2 * 86400 + 5)).toBe('2 Tg.');
		expect(durationText(-30)).toBe('weniger als 1 Min.');
	});
});

describe('life sign and since texts (relative to the server clock)', () => {
	it('writes "Lebenszeichen vor ..." and "gerade eben" for a fresh sign', () => {
		expect(lifeSignText(active({ lastSignAt: ago(12 * MIN) }), REF)).toBe('Lebenszeichen vor 12 Min.');
		expect(lifeSignText(active({ lastSignAt: ago(10_000) }), REF)).toBe('Lebenszeichen gerade eben');
		expect(lifeSignText(active({ lastSignAt: ago(2 * HOUR) }), REF)).toBe('Lebenszeichen vor 2 Std.');
	});
	it('falls back to ageSeconds when the timestamp is unreadable', () => {
		expect(lifeSignText(active({ lastSignAt: 'nope', ageSeconds: 600 }), REF)).toBe('Lebenszeichen vor 10 Min.');
	});
	it('writes "seit ..." only when a start is known', () => {
		expect(sinceText(active({ since: ago(95 * MIN) }), REF)).toBe('seit 1 Std.');
		expect(sinceText(active({ since: ago(20 * MIN) }), REF)).toBe('seit 20 Min.');
		expect(sinceText(active(), REF)).toBe('');
		expect(sinceText(active({ since: 'kaputt' }), REF)).toBe('');
	});
	it('keeps the server clock running between fetches', () => {
		const fetchedAt = 1_000_000;
		expect(serverClock('2026-11-24T12:00:00Z', fetchedAt, fetchedAt + 90_000).toISOString()).toBe('2026-11-24T12:01:30.000Z');
		expect(serverClock('garbage', fetchedAt, fetchedAt + 5).getTime()).toBe(fetchedAt + 5);
	});
});

describe('dueInfo', () => {
	it('is null without a due date', () => {
		expect(dueInfo(undefined, REF)).toBeNull();
		expect(dueInfo('nope', REF)).toBeNull();
	});
	it('shows the date for a future due date and "Überfällig seit ..." afterwards', () => {
		const future = dueInfo('2026-11-25T09:30:00Z', REF);
		expect(future?.overdue).toBe(false);
		expect(future?.text).toBe('Frist 25.11., 10:30');
		const late = dueInfo(ago(2 * 86400_000 + HOUR), REF);
		expect(late).toEqual({ overdue: true, text: 'Überfällig seit 2 Tg.' });
	});
});

describe('recentDone', () => {
	it('keeps only the last 6 hours, newest first, at most 5', () => {
		const list = [done('a', 7 * HOUR), done('b', 5 * HOUR + 59 * MIN), ...['c', 'd', 'e', 'f', 'g', 'h'].map((id, i) => done(id, (i + 1) * 10 * MIN))];
		const out = recentDone(list, REF).map((d) => d.taskID);
		expect(out).toEqual(['c', 'd', 'e', 'f', 'g']);
		expect(NOW_DONE_LIMIT).toBe(5);
		expect(recentDone([done('a', 7 * HOUR), done('b', 5 * HOUR + 59 * MIN)], REF).map((d) => d.taskID)).toEqual(['b']);
	});
});

describe('cleanBlock / blockOf', () => {
	it('returns null for an old server without `now`', () => {
		expect(blockOf(null, REF)).toBeNull();
		expect(blockOf({ serverTime: REF.toISOString(), projects: [] }, REF)).toBeNull();
	});
	it('removes "Beendet" sessions from running and silent and lowers the counts, tasks stay', () => {
		const b = block({
			counts: { running: 2, waiting: 0, recentlyDone: 0, silent: 2 },
			running: [active({ kind: 'session', text: 'Beendet: fertig', taskID: undefined }), active({ title: 'Karte' })],
			silent: [active({ kind: 'session', text: ' beendet ', taskID: undefined }), active({ kind: 'session', text: 'Wartet auf CI', taskID: undefined })]
		});
		const c = cleanBlock(b);
		expect(c.running.map((x) => x.title)).toEqual(['Karte']);
		expect(c.silent.map((x) => x.text)).toEqual(['Wartet auf CI']);
		expect(c.counts).toEqual({ running: 1, waiting: 0, recentlyDone: 0, silent: 1 });
		expect(b.running).toHaveLength(2);
	});
	it('limits the done list on its way into the view', () => {
		const b = block({ recentlyDone: [done('x', 8 * HOUR), done('y', HOUR)] });
		const data: OverviewNow = { serverTime: REF.toISOString(), now: b };
		expect(blockOf(data, REF)?.recentlyDone.map((d) => d.taskID)).toEqual(['y']);
	});
});

describe('showEmptyPage', () => {
	it('shows the old empty state when no project and no block content exist', () => {
		expect(showEmptyPage({ serverTime: '', projects: [] }, null)).toBe(true);
		expect(showEmptyPage({ serverTime: '', projects: [project()] }, null)).toBe(false);
		expect(showEmptyPage({ serverTime: '', projects: [] }, block())).toBe(true);
		expect(showEmptyPage({ serverTime: '', projects: [] }, block({ counts: { running: 0, waiting: 1, recentlyDone: 0, silent: 0 }, waiting: [waiting()] }))).toBe(false);
		expect(showEmptyPage({ serverTime: '', projects: [project()] }, block())).toBe(false);
	});
	it('treats a compact answer without projects like an empty list', () => {
		expect(isEmptyNow(undefined)).toBe(true);
		expect(showEmptyPage({ serverTime: '' }, null)).toBe(true);
	});
});

describe('waitingCard', () => {
	it('links questions to the question and reviews to the review of the card', () => {
		expect(waitingCard(waiting())).toEqual({ type: 'question', id: 'q1' });
		expect(waitingCard(waiting({ kind: 'review', id: 'r1', taskID: 't9' }))).toEqual({ type: 'review', id: 't9' });
	});
});

describe('nowEntry (shortcut from the start page)', () => {
	it('uses the running count and reports waiting items; nothing for an old server', () => {
		expect(nowEntry(undefined)).toEqual({ running: null, waiting: null });
		expect(nowEntry(block({ counts: { running: 2, waiting: 1, recentlyDone: 0, silent: 3 } }))).toEqual({ running: 2, waiting: 1 });
	});
	it('counts as waiting only what concerns the account when the summary says so', () => {
		const b = block({ counts: { running: 2, waiting: 4, recentlyDone: 0, silent: 0 } });
		const summary = { concerningQuestions: 1, concerningReviews: 2 };
		expect(nowEntry(b, summary)).toEqual({ running: 2, waiting: 3 });
		expect(nowEntry(b, { concerningQuestions: 0, concerningReviews: 0 })).toEqual({ running: 2, waiting: 0 });
		// Older servers (no such counters, or not loaded yet) keep the number of the block.
		expect(nowEntry(b, {})).toEqual({ running: 2, waiting: 4 });
		expect(nowEntry(b, null)).toEqual({ running: 2, waiting: 4 });
		expect(nowEntry(undefined, summary)).toEqual({ running: null, waiting: null });
	});
	it('labels running entries, singular and zero', () => {
		expect(nowEntryLabel({ running: null, waiting: null })).toBe('');
		expect(nowEntryLabel({ running: 0, waiting: 0 })).toBe('nichts läuft');
		expect(nowEntryLabel({ running: 1, waiting: 0 })).toBe('1 läuft');
		expect(nowEntryLabel({ running: 3, waiting: 0 })).toBe('3 laufen');
	});
});

describe('api.overviewNow with the compact flag', () => {
	const run = async (opts?: { compact?: boolean; limit?: number }) => {
		let url = '';
		const api = createApi(async (u) => {
			url = String(u);
			return new Response(JSON.stringify({ serverTime: REF.toISOString(), now: block() }), { status: 200 });
		});
		const res = await api.overviewNow(opts);
		return { url, res };
	};
	it('stays unchanged without options', async () => {
		expect((await run()).url).toBe('/v1/overview/now');
	});
	it('adds compact and limit as query parameters', async () => {
		const r = await run({ compact: true, limit: 1 });
		expect(r.url).toBe('/v1/overview/now?compact=true&limit=1');
		expect(r.res.now?.counts.running).toBe(0);
		expect(r.res.projects).toBeUndefined();
	});
});
