import { beforeEach, describe, expect, it } from 'vitest';
import { createApi, type CommandCard, type CommandCenter, type Progress } from '../src/lib/api';
import {
	LANE_ORDER,
	VIEW_KEY,
	attentionCount,
	cardsOf,
	decisionNeedsNote,
	isEmptyOverview,
	loadView,
	orderedLanes,
	percentOf,
	progressCounter,
	questionsOf,
	saveView,
	sortUpdates,
	updateKind,
	validateAnswer
} from '../src/lib/commandCenter';

const progress = (over: Partial<Progress> = {}): Progress => ({
	percent: 0, source: 'none', subtasksDone: 0, subtasksTotal: 0, criteriaDone: 0, criteriaTotal: 0, ...over
});
const card = (id: string, over: Partial<CommandCard> = {}): CommandCard => ({
	task: { id, title: id, status: 'open', version: 1 },
	project: { id: 'p', name: 'P' },
	kind: 'task', isFeature: false, lane: 'ready', progress: progress(), openQuestionCount: 0, questions: [],
	blockedBy: [], builds: [], buildCount: 0, priority: 0, subtasks: [], ...over
});
const q = (id: string, createdAt: string) => ({ id, prompt: id, options: [], blocking: true, askedByType: 'Run' as const, createdAt });

function memoryStorage() {
	const m = new Map<string, string>();
	return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
}

describe('progress', () => {
	it('clamps and rounds the percentage', () => {
		expect(percentOf(progress({ percent: 49.6 }))).toBe(50);
		expect(percentOf(progress({ percent: 140 }))).toBe(100);
		expect(percentOf(progress({ percent: -3 }))).toBe(0);
		expect(percentOf(null)).toBe(0);
		expect(percentOf({ percent: Number.NaN })).toBe(0);
	});
	it('shows a counter only for countable sources', () => {
		expect(progressCounter(progress({ source: 'subtasks', subtasksDone: 1, subtasksTotal: 4 }))).toEqual({ kind: 'subtasks', done: 1, total: 4 });
		expect(progressCounter(progress({ source: 'criteria', criteriaDone: 2, criteriaTotal: 3 }))).toEqual({ kind: 'criteria', done: 2, total: 3 });
		expect(progressCounter(progress({ source: 'agent', percent: 40 }))).toBeNull();
		expect(progressCounter(progress({ source: 'subtasks' }))).toBeNull();
	});
});

describe('lanes and cards', () => {
	it('keeps the fixed lane order and fills missing lanes', () => {
		const lanes = orderedLanes(
			[{ key: 'review', title: 'x', count: 1, truncated: false, cards: [card('a')] }, { key: 'running', title: 'x', count: 0, truncated: false, cards: [] }],
			(k) => k
		);
		expect(lanes.map((l) => l.key)).toEqual(LANE_ORDER);
		expect(lanes.find((l) => l.key === 'review')!.cards).toHaveLength(1);
		expect(orderedLanes(null, (k) => k)).toHaveLength(6);
	});
	it('flattens either response shape and detects an empty overview', () => {
		const base = { generatedAt: '', scope: 'account' as const, view: 'kanban' as const, summary: {} as never, updates: [] as never[], builds: [] as never[] };
		const kanban: CommandCenter = { ...base, lanes: [{ key: 'ready', title: '', count: 1, truncated: false, cards: [card('a')] }] };
		const list: CommandCenter = { ...base, view: 'list', items: [card('b'), card('c')] };
		expect(cardsOf(kanban).map((c) => c.task.id)).toEqual(['a']);
		expect(cardsOf(list).map((c) => c.task.id)).toEqual(['b', 'c']);
		expect(cardsOf(null)).toEqual([]);
		expect(isEmptyOverview({ ...base, lanes: [] })).toBe(true);
		expect(isEmptyOverview(kanban)).toBe(false);
	});
	it('collects open questions newest first without duplicates', () => {
		const a = card('a', { questions: [q('q1', '2026-10-01T00:00:00Z'), q('q2', '2026-10-03T00:00:00Z')] });
		const b = card('b', { questions: [q('q2', '2026-10-03T00:00:00Z'), q('q3', '2026-10-02T00:00:00Z')] });
		expect(questionsOf([a, b]).map((x) => x.question.id)).toEqual(['q2', 'q3', 'q1']);
	});
	it('adds up the sidebar attention number', () => {
		expect(attentionCount({ openQuestions: 2, pendingReviews: 3 })).toBe(5);
		expect(attentionCount(null)).toBe(0);
	});
});

describe('answers and decisions', () => {
	it('accepts only listed options when options exist', () => {
		expect(validateAnswer(['Ja', 'Nein'], 'Ja')).toBe('Ja');
		expect(validateAnswer(['Ja', 'Nein'], 'Vielleicht')).toBeNull();
		expect(validateAnswer([], '  frei  ')).toBe('frei');
		expect(validateAnswer([], '   ')).toBeNull();
		expect(validateAnswer([], 'x'.repeat(10001))).toBeNull();
	});
	it('demands a note only for change requests', () => {
		expect(decisionNeedsNote('request_changes', '  ')).toBe(true);
		expect(decisionNeedsNote('request_changes', 'Bitte Farben prüfen')).toBe(false);
		expect(decisionNeedsNote('accept', '')).toBe(false);
	});
});

describe('updates', () => {
	it('maps backend activity kinds to display groups', () => {
		expect(updateKind('progress.posted')).toBe('progress');
		expect(updateKind('agent.question')).toBe('asked');
		expect(updateKind('review.changes_requested')).toBe('changes');
		expect(updateKind('agent.accept')).toBe('accepted');
		expect(updateKind('build.added')).toBe('build');
		expect(updateKind('agent.fail')).toBe('agent');
	});
	it('sorts newest first without mutating', () => {
		const items = [
			{ id: '1', createdAt: '2026-10-01T00:00:00Z' },
			{ id: '2', createdAt: '2026-10-02T00:00:00Z' }
		] as never[];
		expect(sortUpdates(items).map((u: { id: string }) => u.id)).toEqual(['2', '1']);
		expect((items[0] as { id: string }).id).toBe('1');
	});
});

describe('remembered view', () => {
	beforeEach(() => {
		Object.defineProperty(globalThis, 'localStorage', { value: memoryStorage(), configurable: true });
	});
	it('defaults to kanban and remembers the list view', () => {
		expect(loadView()).toBe('kanban');
		saveView('list');
		expect(localStorage.getItem(VIEW_KEY)).toBe('"list"');
		expect(loadView()).toBe('list');
		saveView('kanban');
		expect(loadView()).toBe('kanban');
	});
});

describe('api requests', () => {
	const calls: { url: string; init?: RequestInit }[] = [];
	const api = createApi(async (url, init) => {
		calls.push({ url, init });
		return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } });
	});
	beforeEach(() => (calls.length = 0));
	it('builds the command center query', async () => {
		await api.commandCenter({ scope: 'project', projectID: 'p1', view: 'list', lane: 'review', hasQuestion: true, sort: 'updated', limit: 20 });
		expect(calls[0].url).toBe('/v1/command-center?scope=project&projectID=p1&view=list&lane=review&hasQuestion=true&sort=updated&limit=20');
		await api.commandCenter({ scope: 'account' });
		expect(calls[1].url).toBe('/v1/command-center?scope=account');
	});
	it('answers, decides and writes the brief', async () => {
		await api.answerQuestion('q1', 'Ja');
		expect(calls[0].url).toBe('/v1/questions/q1/answer');
		expect(JSON.parse(String(calls[0].init?.body))).toEqual({ answer: 'Ja' });
		await api.decideReview('t1', 'request_changes', 'Mehr Kontrast');
		expect(calls[1].url).toBe('/v1/tasks/t1/review/decision');
		expect(JSON.parse(String(calls[1].init?.body))).toEqual({ decision: 'request_changes', note: 'Mehr Kontrast' });
		await api.decideReview('t1', 'accept');
		expect(JSON.parse(String(calls[2].init?.body))).toEqual({ decision: 'accept' });
		await api.putAgentBrief('p1', '## Goals', 0);
		expect(calls[3].init?.method).toBe('PUT');
		expect(JSON.parse(String(calls[3].init?.body))).toEqual({ text: '## Goals', version: 0 });
		await api.listQuestions({ projectID: 'p1', includeSubprojects: true });
		expect(calls[4].url).toBe('/v1/questions?projectID=p1&state=open&includeSubprojects=true');
	});
});
