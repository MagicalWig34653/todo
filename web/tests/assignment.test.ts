import { describe, expect, it } from 'vitest';
import { ApiError, type ForMe, type Question, type Review, type Task } from '../src/lib/api';
import {
	candidatesFor, defaultSegment, forMeCount, lacksResponsibility, mayDecideReview, mayHandOverQuestion, mayHandOverReview, minePlans, mineOnly,
	needResponsibility, responsibleName, settleForMe
} from '../src/lib/assignment';
import { createDraftTask, type CardDraft } from '../src/lib/cardDraft';
import { attentionCount } from '../src/lib/commandCenter';
import type { ForYouNeed } from '../src/lib/forYou';
import { t } from '../src/lib/i18n/index';

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
	it('keeps cards added while the filter is on, whoever is responsible', () => {
		expect(mineOnly(tasks, 'me', new Set(['3'])).map((x) => x.id)).toEqual(['1', '3']);
		expect(mineOnly(tasks, 'me', new Set(['unknown'])).map((x) => x.id)).toEqual(['1']);
	});
	it('does not claim that something older is missing when the list is cut off', () => {
		expect(t('forYou.mineTruncated')).toBe('Nicht alle Einträge werden angezeigt.');
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

const need = (over: Partial<ForYouNeed>): ForYouNeed => ({
	id: 'n', kind: 'plan', projectID: 'p', projectName: 'P', taskID: 't1', taskTitle: 'T', taskVersion: 1, title: 'x', options: [], blocking: false, actions: [], ...over
});
const forMe = { generatedAt: '', tasks: [{ id: 't1' }], questions: [{ id: 'q' }], reviews: [], truncated: false } as unknown as ForMe;

describe('"Für mich" beside the feed', () => {
	it('passes the answer on', async () => {
		expect(await settleForMe(Promise.resolve(forMe))).toEqual({ own: forMe });
	});
	it('knows a server without it', async () => {
		expect(await settleForMe(Promise.reject(new ApiError(404)))).toEqual({ own: null });
	});
	it('reports any other failure and says nothing about the content, so the shown one stays', async () => {
		for (const failure of [new ApiError(500), new TypeError('Failed to fetch')]) {
			const result = await settleForMe(Promise.reject(failure));
			expect(result.own).toBeUndefined();
			expect(result.failure).toBe(failure);
		}
	});
	it('takes the waiting plans of own cards that concern the account, and counts them', () => {
		const needs = [
			need({ id: 'own', concernsMe: true }),
			need({ id: 'others', concernsMe: false }),
			need({ id: 'foreignCard', taskID: 't2', concernsMe: true }),
			need({ id: 'oldServer' }),
			need({ id: 'blocked', kind: 'blocked', concernsMe: true })
		];
		expect(minePlans(needs, forMe).map((n) => n.id)).toEqual(['own']);
		expect(minePlans(needs, null)).toEqual([]);
		expect(forMeCount(forMe, minePlans(needs, forMe))).toBe(3);
		expect(forMeCount(null, [])).toBe(0);
	});
});

describe('responsibility of a feed entry', () => {
	const review = { id: 'r', reviewerID: 'a', assigneeName: 'Anna', agentJobID: 'job' } as unknown as Review;
	const question = { id: 'q', assigneeID: 'b', agentQuestionID: null } as unknown as Question;

	it('uses the listed review or question', () => {
		expect(needResponsibility(need({ kind: 'review', reviewID: 'r' }), undefined, review)).toEqual({ kind: 'review', id: 'r', assigneeID: 'a', assigneeName: 'Anna', runner: true });
		expect(needResponsibility(need({ kind: 'question', questionID: 'q', assigneeName: 'Ben' }), question)).toEqual({ kind: 'question', id: 'q', assigneeID: 'b', assigneeName: 'Ben', runner: false });
	});
	it('falls back to the feed when the capped list does not reach an old entry', () => {
		const old = need({ kind: 'review', reviewID: 'old', concernsMe: false, assigneeID: 'a', assigneeName: 'Anna', actor: { type: 'Integration', id: 'i' } });
		expect(needResponsibility(old)).toEqual({ kind: 'review', id: 'old', assigneeID: 'a', assigneeName: 'Anna', runner: false });
		const run = need({ kind: 'question', questionID: 'rq', concernsMe: true, actor: { type: 'Run', id: 'r' } });
		expect(needResponsibility(run)).toEqual({ kind: 'question', id: 'rq', assigneeID: undefined, assigneeName: undefined, runner: true });
	});
	it('knows nothing from the feed of an older server, and nothing about other kinds', () => {
		expect(needResponsibility(need({ kind: 'review', reviewID: 'r' }))).toBeNull();
		expect(needResponsibility(need({ kind: 'plan', concernsMe: true }))).toBeNull();
	});
});

describe('server without responsibility', () => {
	const missing = () => Promise.reject(new ApiError(404));
	it('needs both routes to be missing', async () => {
		expect(await lacksResponsibility(new ApiError(404), missing)).toBe(true);
	});
	it('takes a 404 of the people list alone as an invisible project', async () => {
		expect(await lacksResponsibility(new ApiError(404), async () => forMe)).toBe(false);
	});
	it('draws no conclusion from other failures', async () => {
		let asked = 0;
		expect(await lacksResponsibility(new ApiError(500), () => (asked++, missing()))).toBe(false);
		expect(asked).toBe(0);
		expect(await lacksResponsibility(new ApiError(404), () => Promise.reject(new ApiError(500)))).toBe(false);
	});
});
