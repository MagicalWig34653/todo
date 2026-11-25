import { describe, expect, it } from 'vitest';
import type { NowBlock, NowDone, OverviewBuild, OverviewNow, OverviewProject } from '../src/lib/api';
import { blockOf, defaultExpanded, groupBuilds, isExpanded, notListed, nowTiles, projectStats } from '../src/lib/now';
import { previewText } from '../src/lib/previewText';

const REF = new Date('2026-11-25T12:00:00Z');
const ago = (ms: number) => new Date(REF.getTime() - ms).toISOString();
const MIN = 60_000;
const HOUR = 60 * MIN;

describe('previewText (Markdown out of the two-line preview)', () => {
	it('drops emphasis and joins list items of a multi-line text', () => {
		expect(previewText('**Neu:** Kalender\n- eins\n- zwei')).toBe('Neu: Kalender · eins · zwei');
		expect(previewText('Wochenplan\n\n* `Mo` bis Fr\n+ __Sa__ und So')).toBe('Wochenplan · Mo bis Fr · Sa und So');
	});
	it('handles text the server already flattened to one line', () => {
		expect(previewText('## Rate-Limit fertig * 60 Anfragen * Antwort 429 mit `Retry-After`')).toBe('Rate-Limit fertig · 60 Anfragen · Antwort 429 mit Retry-After');
		expect(previewText('**Neu:** Freigaben - Rollen erben - 214 Tests')).toBe('Neu: Freigaben · Rollen erben · 214 Tests');
	});
	it('removes headings, quotes, checkboxes, rules and code fences, keeps the numbers of a numbered list', () => {
		expect(previewText('# Titel\n> Hinweis\n- [x] fertig\n- [ ] offen\n1. erstens\n---')).toBe('Titel Hinweis · fertig · offen · 1. erstens');
		expect(previewText('Befehl:\n```sh\nnpm test\n```')).toBe('Befehl: npm test');
		expect(previewText('---')).toBe('');
	});
	it('shows the text of links and images', () => {
		expect(previewText('[Beschreibung](https://example.invalid/x) und ![Bild](a.png) ansehen')).toBe('Beschreibung und Bild ansehen');
	});
	it('removes single emphasis and strike marks, also unclosed ones from a cut-off text', () => {
		expect(previewText('*wirklich* _sehr_ ~~alt~~ neu')).toBe('wirklich sehr alt neu');
		expect(previewText('**Wichtig: der Rest ist abgeschnitten …')).toBe('Wichtig: der Rest ist abgeschnitten …');
		expect(previewText('Siehe `config')).toBe('Siehe config');
	});
	it('leaves identifiers, code spans and ordinary signs alone', () => {
		expect(previewText('Feld snake_case_name und `__init__` prüfen')).toBe('Feld snake_case_name und __init__ prüfen');
		expect(previewText('Karte #12 in C# mit E-Mail')).toBe('Karte #12 in C# mit E-Mail');
		expect(previewText('')).toBe('');
	});
});

const build = (id: string, buildID: string, minutes: number, over: Partial<OverviewBuild> = {}): OverviewBuild => ({
	id, taskID: 't', buildID, platform: 'web', createdAt: ago(minutes * MIN), ...over
});

describe('groupBuilds (one line per build, not per file)', () => {
	it('groups by build and platform, newest first, and counts the files', () => {
		const groups = groupBuilds([
			build('a', '564a6b4', 30, { label: 'Web 564a6b4', status: 'building' }),
			build('b', 'ios-42', 5, { platform: 'ios', label: 'iOS 42' }),
			build('c', '564a6b4', 20, { label: 'Web 564a6b4', status: 'succeeded', commit: '564a6b4' }),
			build('d', '564a6b4', 10),
			build('e', '564a6b4', 40, { platform: 'ios' })
		]);
		expect(groups.map((g) => [g.buildID, g.platform, g.files])).toEqual([['ios-42', 'ios', 1], ['564a6b4', 'web', 3], ['564a6b4', 'ios', 1]]);
		expect(groups[1]).toMatchObject({ label: 'Web 564a6b4', status: 'succeeded', commit: '564a6b4', createdAt: ago(10 * MIN) });
	});
	it('takes the status of the newest file that reports one', () => {
		const [g] = groupBuilds([build('a', 'x', 30, { status: 'succeeded' }), build('b', 'x', 20, { status: 'failed' }), build('c', 'x', 1)]);
		expect(g!.status).toBe('failed');
		expect(groupBuilds([build('a', 'y', 1)])[0]!.status).toBeNull();
	});
	it('keeps keys unique, also without ids from an old server', () => {
		const groups = groupBuilds([build('a', 'x', 1, { platform: null }), build('b', 'x', 1, { platform: '' }), build('c', 'x|', 1, { platform: null })]);
		expect(groups.map((g) => g.files)).toEqual([2, 1]);
		expect(new Set(groups.map((g) => g.key)).size).toBe(groups.length);
	});
	it('counts builds, not files, in the project numbers', () => {
		const p: OverviewProject = {
			projectID: 'p', projectName: 'P', lastActivityAt: ago(MIN), runningTasks: [], sessions: [], agentJobs: [], openQuestions: [], pendingReviews: [], recentActivity: [],
			builds: [build('a', 'x', 1), build('b', 'x', 2), build('c', 'y', 3)]
		};
		expect(projectStats(p).builds).toBe(2);
	});
});

const done = (id: string, ms: number): NowDone => ({ taskID: id, title: id, projectID: 'p', projectName: 'P', doneAt: ago(ms) });
const block = (over: Partial<NowBlock> = {}): NowBlock => ({
	counts: { running: 0, waiting: 0, recentlyDone: 0, silent: 0 }, running: [], waiting: [], recentlyDone: [], silent: [], ...over
});

describe('nowTiles (the four numbers on top)', () => {
	it('takes the totals of the server, waiting first', () => {
		expect(nowTiles(block({ counts: { running: 7, waiting: 12, recentlyDone: 6, silent: 1 } }))).toEqual([
			{ id: 'waiting', count: 12 }, { id: 'running', count: 7 }, { id: 'done', count: 6 }, { id: 'silent', count: 1 }
		]);
	});
	it('lowers "done" only for entries that left the 6 hour window since the answer, not for the cut to five', () => {
		const list = [1, 2, 3, 4, 5, 6, 7].map((n) => done(`d${n}`, n * 10 * MIN));
		const data = (recentlyDone: NowDone[], count: number): OverviewNow => ({ serverTime: REF.toISOString(), now: block({ recentlyDone, counts: { running: 0, waiting: 0, recentlyDone: count, silent: 0 } }) });
		const all = blockOf(data(list, 9), REF)!;
		expect(all.recentlyDone).toHaveLength(5);
		expect(all.counts.recentlyDone).toBe(9);
		const aged = blockOf(data([...list.slice(0, 2), done('old', 7 * HOUR)], 3), REF)!;
		expect(aged.counts.recentlyDone).toBe(2);
		expect(blockOf(data([done('old', 7 * HOUR)], 0), REF)!.counts.recentlyDone).toBe(0);
	});
});

describe('notListed', () => {
	it('is the number counted but not delivered, never negative', () => {
		expect(notListed(12, 9)).toBe(3);
		expect(notListed(9, 9)).toBe(0);
		expect(notListed(2, 5)).toBe(0);
	});
});

describe('project rows default to closed below the block', () => {
	it('keeps active projects open only when there is no block (old server)', () => {
		expect(defaultExpanded(false, false)).toBe(true);
		expect(defaultExpanded(false, true)).toBe(false);
		expect(defaultExpanded(true, false)).toBe(false);
		expect(isExpanded({}, 'a', false, true)).toBe(false);
		expect(isExpanded({ a: true }, 'a', false, true)).toBe(true);
		expect(isExpanded({ a: false }, 'a', false, false)).toBe(false);
	});
});
