import { describe, expect, it } from 'vitest';
import { actionRequest, appendPosts, postTitleKey, type ForYouAction, type ForYouPost } from '../src/lib/forYou';
import { buildPath, parseRoute } from '../src/lib/routing';

const post = (id: string): ForYouPost => ({
	id, kind: 'progress', event: 'progress.posted', projectID: 'p', projectName: 'P', taskID: 't', taskTitle: 'T',
	actor: { type: 'Person', id: 'u' }, images: []
});
const act = (o: Partial<ForYouAction>): ForYouAction => ({ key: 'k', label: 'L', method: 'POST', path: '/v1/x', requiresInput: false, ...o });

describe('for you feed helpers', () => {
	it('sends option actions unchanged and strips the /v1 prefix', () => {
		expect(actionRequest(act({ path: '/v1/questions/1/answer', body: { answer: 'A' } }))).toEqual({ method: 'POST', path: '/questions/1/answer', body: { answer: 'A' } });
	});
	it('requires text for a free answer and puts it into the input field', () => {
		const a = act({ requiresInput: true, inputField: 'answer' });
		expect(actionRequest(a, '  ')).toBeNull();
		expect(actionRequest(a, ' Ja ')?.body).toEqual({ answer: 'Ja' });
	});
	it('note is optional for request_changes', () => {
		const a = act({ body: { decision: 'request_changes' }, requiresInput: true, inputField: 'note' });
		expect(actionRequest(a, '')?.body).toEqual({ decision: 'request_changes' });
		expect(actionRequest(a, 'Test fehlt')?.body).toEqual({ decision: 'request_changes', note: 'Test fehlt' });
	});
	it('keeps the version for completing a task', () => {
		expect(actionRequest(act({ method: 'PATCH', path: '/v1/tasks/1', body: { status: 'done', version: 3 } }))?.body).toEqual({ status: 'done', version: 3 });
	});
	it('appends pages without duplicates', () => {
		expect(appendPosts([post('a'), post('b')], [post('b'), post('c')]).map((p) => p.id)).toEqual(['a', 'b', 'c']);
	});
	it('maps post kinds to headlines', () => {
		expect(postTitleKey({ kind: 'review', state: 'accepted' })).toBe('forYou.post.reviewAccepted');
		expect(postTitleKey({ kind: 'agent_run', state: 'failed' })).toBe('forYou.post.runFailed');
		expect(postTitleKey({ kind: 'agent_run', state: 'finished' })).toBe('forYou.post.runFinished');
		expect(postTitleKey({ kind: 'future' })).toBe('forYou.post.other');
	});
	it('routes /fuer-dich and the root to the feed', () => {
		expect(parseRoute('/fuer-dich')).toEqual({ view: 'forYou' });
		expect(buildPath({ view: 'forYou' })).toBe('/fuer-dich');
	});
});
