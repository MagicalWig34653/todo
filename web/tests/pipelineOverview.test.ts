import { describe, expect, it } from 'vitest';
import { cardOfNeed, cardOfPost, cardTabOfNeed, cardTabOfPost } from '../src/lib/cardRef';
import { attentionCount, updateKind } from '../src/lib/commandCenter';
import {
	actionRequest,
	needInputKind,
	needKindKey,
	postTitleKey,
	type ForYouAction,
	type ForYouNeed,
	type ForYouPost
} from '../src/lib/forYou';
import { de } from '../src/lib/i18n/de';
import { buildPath, parseRoute } from '../src/lib/routing';

// Card B926E7D8 (pipeline stage 2): "Für dich" and the overview know the plan waiting for approval (docs/PLAN-PIPELINE-STUFE-2.md, section 5).
const ID = '3F23FF45-7A01-4D28-BEF1-8694F9DE23DA';
const act = (o: Partial<ForYouAction>): ForYouAction => ({ key: 'k', label: 'L', method: 'POST', path: '/v1/x', requiresInput: false, ...o });
const planNeed = (over: Partial<ForYouNeed> = {}): ForYouNeed => ({
	id: `plan:${ID}:2`, kind: 'plan', projectID: 'p', projectName: 'P', taskID: ID, taskTitle: 'Karte', taskVersion: 1, title: 'Karte', detail: 'Plan v2 wartet auf Freigabe', options: [], blocking: false,
	actions: [
		{ key: 'approve', label: 'Plan freigeben', method: 'POST', path: `/v1/tasks/${ID}/plan/decision`, body: { decision: 'approve', version: 2 }, requiresInput: false },
		{ key: 'request_changes', label: 'Änderungen', method: 'POST', path: `/v1/tasks/${ID}/plan/decision`, body: { decision: 'request_changes', version: 2 }, requiresInput: true, inputField: 'comment' }
	],
	...over
});
const post = (over: Partial<ForYouPost>): ForYouPost => ({
	id: 'x', kind: 'plan', event: 'plan.written', projectID: 'p', projectName: 'P', taskID: ID, taskTitle: 'T', actor: { type: 'Integration', id: 'i', name: 'claude-code' }, images: [], ...over
});

describe('needs-you entry of kind plan', () => {
	it('has a German label; unknown kinds get a neutral label instead of a raw code or nothing', () => {
		expect(de[needKindKey('plan')]).toBe('Plan wartet');
		expect(de[needKindKey('question')]).toBe('Rückfrage');
		expect(de[needKindKey('review')]).toBe('Review');
		expect(de[needKindKey('overdue')]).toBe('Überfällig');
		expect(de[needKindKey('something_new')]).toBe('Hinweis');
	});

	it('approves with the version the server named, without text', () => {
		const [approve] = planNeed().actions;
		expect(actionRequest(approve!)).toEqual({ method: 'POST', path: `/tasks/${ID}/plan/decision`, body: { decision: 'approve', version: 2 } });
		expect(needInputKind(approve!)).toBeNull();
	});

	it('requires a comment for changes and puts it into the comment field', () => {
		const changes = planNeed().actions[1]!;
		expect(needInputKind(changes)).toBe('comment');
		expect(actionRequest(changes, '')).toBeNull();
		expect(actionRequest(changes, '   ')).toBeNull();
		expect(actionRequest(changes, ' Bitte Tests zuerst ')).toEqual({
			method: 'POST', path: `/tasks/${ID}/plan/decision`, body: { decision: 'request_changes', version: 2, comment: 'Bitte Tests zuerst' }
		});
	});

	it('keeps the other input kinds as they were', () => {
		expect(needInputKind(act({ requiresInput: true, inputField: 'note' }))).toBe('note');
		expect(needInputKind(act({ requiresInput: true, inputField: 'answer' }))).toBe('answer');
		expect(needInputKind(act({ requiresInput: false, inputField: 'note' }))).toBeNull();
		expect(actionRequest(act({ requiresInput: true, inputField: 'note', body: { decision: 'request_changes' } }), '')?.body).toEqual({ decision: 'request_changes' });
	});

	it('opens the task on the Pipeline tab', () => {
		expect(cardOfNeed(planNeed())).toEqual({ type: 'task', id: ID });
		expect(cardTabOfNeed(planNeed())).toBe('pipeline');
		expect(cardTabOfNeed({ kind: 'review' })).toBeUndefined();
		expect(cardTabOfNeed({ kind: 'question' })).toBeUndefined();
	});
});

describe('feed posts of kind plan', () => {
	it('reads in German for each event', () => {
		expect(de[postTitleKey(post({ event: 'plan.written' })) as keyof typeof de]).toBe('hat einen Plan geschrieben');
		expect(de[postTitleKey(post({ event: 'plan.approved' })) as keyof typeof de]).toBe('hat den Plan freigegeben');
		expect(de[postTitleKey(post({ event: 'plan.changes_requested' })) as keyof typeof de]).toBe('hat Änderungen am Plan angefragt');
		expect(de[postTitleKey(post({ event: 'plan.future' })) as keyof typeof de]).toBe('hat den Plan geändert');
	});

	it('keeps unknown kinds readable', () => {
		expect(postTitleKey({ kind: 'future' })).toBe('forYou.post.other');
		expect(de['forYou.post.other']).toBe('Aktivität');
	});

	it('opens the task on the Pipeline tab', () => {
		expect(cardOfPost(post({}))).toEqual({ type: 'task', id: ID });
		expect(cardTabOfPost(post({}))).toBe('pipeline');
		expect(cardTabOfPost(post({ kind: 'progress' }))).toBeUndefined();
	});
});

describe('overview', () => {
	it('names plan updates in German', () => {
		expect(updateKind('plan.written')).toBe('planWritten');
		expect(updateKind('plan.approved')).toBe('planApproved');
		expect(updateKind('plan.changes_requested')).toBe('planChanges');
		expect(updateKind('pipeline.step')).toBe('agent');
		expect(de['cc.update.planWritten']).toContain('Plan');
		expect(de['cc.update.planApproved']).toContain('Plan');
		expect(de['cc.update.planChanges']).toContain('Plan');
	});

	it('counts plans waiting in the attention number', () => {
		expect(attentionCount({ openQuestions: 1, pendingReviews: 1, plansWaiting: 2 })).toBe(4);
		expect(attentionCount({ openQuestions: 1, pendingReviews: 1 })).toBe(2);
	});

	it('has texts for the card marker and the summary', () => {
		expect(de['cc.card.planWaiting']).toBe('Plan wartet auf Freigabe');
		expect(de['cc.summary.plansWaiting']).toContain('{count}');
	});
});

describe('project settings route', () => {
	it('opens the pipeline settings of a project by URL and writes the same path back', () => {
		const r = parseRoute(`/project/${ID}/pipeline`);
		expect(r).toEqual({ view: 'project', projectID: ID, sub: 'pipeline', taskID: undefined });
		expect(buildPath(r)).toBe(`/project/${ID}/pipeline`);
		expect(parseRoute(`/project/${ID}/nonsense`).view).toBe('notfound');
	});
});
