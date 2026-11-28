import { describe, expect, it } from 'vitest';
import type { Task } from '../src/lib/api';
import { candidatesFor, defaultSegment, mayDecideReview, mayHandOverQuestion, mayHandOverReview, mineOnly, responsibleName } from '../src/lib/assignment';
import { createDraftTask, type CardDraft } from '../src/lib/cardDraft';
import { attentionCount } from '../src/lib/commandCenter';

const people = [
	{ userID: 'a', displayName: 'Anna', assignableTo: ['task', 'question', 'review'] as const, isMe: false },
	{ userID: 'r', displayName: 'Rita', assignableTo: ['task'] as const, isMe: false },
	{ userID: 'c', displayName: 'Carl', assignableTo: ['task', 'question'] as const, isMe: true }
];

describe('responsible person', () => {
	it('prefers the server name, then the list of people, then the own name', () => {
		expect(responsibleName('a', 'Anna Server', people)).toBe('Anna Server');
		expect(responsibleName('a', undefined, people)).toBe('Anna');
		expect(responsibleName('me', null, [], { id: 'me', displayName: 'Ich' })).toBe('Ich');
	});
	it('knows nothing about other people without name or list (neutral label)', () => {
		expect(responsibleName('x', null, people, { id: 'me', displayName: 'Ich' })).toBeNull();
		expect(responsibleName(null, 'Anna', people)).toBeNull();
	});
	it('offers only people who may hold the kind', () => {
		expect(candidatesFor(people, 'review').map((p) => p.userID)).toEqual(['a']);
		expect(candidatesFor(people, 'question').map((p) => p.userID)).toEqual(['a', 'c']);
		expect(candidatesFor(people, 'task')).toHaveLength(3);
	});
});

describe('who may decide or hand over', () => {
	it('keeps a named review with that person and the project management', () => {
		expect(mayDecideReview('a', 'a', 'edit')).toBe(true);
		expect(mayDecideReview('a', 'b', 'edit')).toBe(false);
		expect(mayDecideReview('a', 'b', 'manage')).toBe(true);
	});
	it('leaves an unnamed review as before (the server decides about rights)', () => {
		expect(mayDecideReview(null, 'b', 'edit')).toBe(true);
		expect(mayDecideReview(undefined, 'b', 'read')).toBe(true);
	});
	it('hands a review over with edit; a named one only by that person or the management; runner items never', () => {
		expect(mayHandOverReview({ reviewerID: null, meID: 'b', role: 'edit' })).toBe(true);
		expect(mayHandOverReview({ reviewerID: null, meID: 'b', role: 'comment' })).toBe(false);
		expect(mayHandOverReview({ reviewerID: 'a', meID: 'b', role: 'edit' })).toBe(false);
		expect(mayHandOverReview({ reviewerID: 'a', meID: 'a', role: 'edit' })).toBe(true);
		expect(mayHandOverReview({ reviewerID: 'a', meID: 'b', role: 'manage' })).toBe(true);
		expect(mayHandOverReview({ reviewerID: 'a', meID: 'a', role: 'comment' })).toBe(false);
		expect(mayHandOverReview({ reviewerID: null, meID: 'b', role: 'manage', runner: true })).toBe(false);
	});
	it('hands a question over with edit only, runner questions never', () => {
		expect(mayHandOverQuestion('edit')).toBe(true);
		expect(mayHandOverQuestion('comment')).toBe(false);
		expect(mayHandOverQuestion('manage', true)).toBe(false);
	});
});

describe('"Meine" and "Für mich"', () => {
	const tasks = [{ id: '1', assigneeID: 'me' }, { id: '2', assigneeID: 'a' }, { id: '3' }] as Task[];
	it('keeps only the own cards', () => {
		expect(mineOnly(tasks, 'me').map((x) => x.id)).toEqual(['1']);
		expect(mineOnly(tasks, undefined)).toEqual([]);
	});
	it('preselects "Für mich" only when it is not empty', () => {
		expect(defaultSegment(2)).toBe('mine');
		expect(defaultSegment(0)).toBe('all');
	});
});

describe('navigation counter', () => {
	it('counts what concerns the account when the server says so', () => {
		expect(attentionCount({ openQuestions: 5, pendingReviews: 4, plansWaiting: 3, concerningQuestions: 1, concerningReviews: 0, concerningPlans: 2, pendingConfirmations: 1, pendingAccessRequests: 1 })).toBe(5);
	});
	it('falls back to the old fields one by one on older servers', () => {
		expect(attentionCount({ openQuestions: 5, pendingReviews: 4, plansWaiting: 3, concerningReviews: 1 })).toBe(9);
	});
});

describe('draft', () => {
	const draft: CardDraft = { title: 'Neu', description: '', projectID: 'p', columnID: null, priority: 0, due: '', labelIDs: [], files: [], assigneeID: 'b' };
	const fake = (fail = false) => {
		const calls: string[] = [];
		const api = {
			createTask: async () => (calls.push('create'), { id: 't' }) as Task,
			putPlanning: async () => ({}),
			addTaskLabel: async () => undefined,
			setTaskAssignee: async (id: string, who: string | null) => {
				calls.push(`assign ${id} ${who}`);
				if (fail) throw new Error('x');
				return {};
			}
		} as unknown as Parameters<typeof createDraftTask>[0];
		return { api, calls };
	};
	it('assigns with a second call after creating', async () => {
		const { api, calls } = fake();
		const out = await createDraftTask(api, draft, async () => undefined);
		expect(calls).toEqual(['create', 'assign t b']);
		expect(out.failed).toEqual([]);
	});
	it('sends nothing for "Niemand" and reports a failed assignment without losing the card', async () => {
		const none = fake();
		await createDraftTask(none.api, { ...draft, assigneeID: '' }, async () => undefined);
		expect(none.calls).toEqual(['create']);
		const out = await createDraftTask(fake(true).api, draft, async () => undefined);
		expect(out.failed).toEqual(['assignee']);
	});
});
