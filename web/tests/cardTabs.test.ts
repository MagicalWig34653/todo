import { describe, expect, it } from 'vitest';
import { buildReport, CARD_TABS, DATA_TABS, parseCardTab, tabAfterKey } from '../src/lib/cardTabs';
import type { Question, Review } from '../src/lib/api';
import { buildPath, parseRoute } from '../src/lib/routing';

const ID = '3F23FF45-7A01-4D28-BEF1-8694F9DE23DA';
const note = (id: string, createdAt: string, percent: number | null = null) => ({ id, taskID: 't', actorType: 'Integration' as const, note: id, percent, createdAt });
const question = (id: string, createdAt: string, state: Question['state']): Question => ({ id, taskID: 't', askedByType: 'Integration', prompt: id, options: [], blocking: false, state, createdAt, version: 1 });
const review = (state: Review['state']): Review => ({ id: 'r', taskID: 't', state, requestedByType: 'Integration', summary: 'S', version: 1 });

describe('card tabs', () => {
	it('knows the six tabs in order, default first', () => {
		expect(CARD_TABS).toEqual(['overview', 'activity', 'report', 'pipeline', 'changes', 'tests']);
		expect(DATA_TABS).toEqual(['pipeline', 'changes', 'tests']);
	});
	it('parses only known tab names', () => {
		expect(parseCardTab('report')).toBe('report');
		for (const bad of ['', 'Report', 'x', '../', null, undefined]) expect(parseCardTab(bad)).toBeNull();
	});
	it('moves with arrows (wrapping), Home and End; ignores other keys', () => {
		expect(tabAfterKey('overview', 'ArrowRight')).toBe('activity');
		expect(tabAfterKey('tests', 'ArrowRight')).toBe('overview');
		expect(tabAfterKey('overview', 'ArrowLeft')).toBe('tests');
		expect(tabAfterKey('report', 'Home')).toBe('overview');
		expect(tabAfterKey('report', 'End')).toBe('tests');
		expect(tabAfterKey('report', 'Enter')).toBeNull();
	});
	it('carries ?tab= next to ?card= in the route, default tab stays out of the URL', () => {
		const r = parseRoute('/for-you', `?card=task:${ID}&tab=activity`);
		expect(r.card).toEqual({ type: 'task', id: ID });
		expect(r.cardTab).toBe('activity');
		expect(buildPath(r)).toBe(`/for-you?card=task:${ID}&tab=activity`);
		expect(buildPath({ ...r, cardTab: 'overview' })).toBe(`/for-you?card=task:${ID}`);
		expect(parseRoute('/for-you', `?card=task:${ID}&tab=nonsense`).cardTab).toBeUndefined();
		expect(parseRoute('/for-you', `?tab=report`).cardTab).toBeUndefined();
	});
});

describe('buildReport', () => {
	it('is empty without notes, questions or review', () => {
		const r = buildReport({ progressNotes: [], questions: [], review: null });
		expect(r.isEmpty).toBe(true);
		expect(r.completion).toBeNull();
	});
	it('orders notes and questions chronologically (oldest first)', () => {
		const r = buildReport({
			progressNotes: [note('b', '2026-11-13T10:00:00Z', 60), note('a', '2026-11-13T09:00:00Z', 30)],
			questions: [question('q2', '2026-11-13T09:30:00Z', 'answered'), question('q1', '2026-11-13T08:30:00Z', 'open')],
			review: null
		});
		expect(r.notes.map((n) => n.id)).toEqual(['a', 'b']);
		expect(r.questions.map((q) => q.id)).toEqual(['q1', 'q2']);
		expect(r.isEmpty).toBe(false);
		expect(r.completion).toBeNull();
	});
	it('keeps notes of the same second in posting order (API lists newest first)', () => {
		const t = '2026-11-13T09:00:00Z';
		const r = buildReport({ progressNotes: [note('second', t), note('first', t)], questions: [], review: null });
		expect(r.notes.map((n) => n.id)).toEqual(['first', 'second']);
	});
	it('offers a completion summary only for an accepted review', () => {
		expect(buildReport({ progressNotes: [], questions: [], review: review('pending') }).completion).toBeNull();
		expect(buildReport({ progressNotes: [], questions: [], review: review('changes_requested') }).completion).toBeNull();
		const done = buildReport({ progressNotes: [note('a', '2026-11-13T09:00:00Z', 100)], questions: [], review: review('accepted') });
		expect(done.completion?.summary).toBe('S');
		expect(done.completion?.lastPercent).toBe(100);
	});
});
