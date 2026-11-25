import { describe, expect, it, vi } from 'vitest';
import { ApiError, createApi, type FetchLike } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import { parseMarkdown } from '../src/lib/miniMarkdown';
import {
	PIPELINE_STEPS,
	awaitingApproval,
	canDecide,
	createPipelineController,
	decisionErrorKey,
	decisionProblem,
	emptyPipelineView,
	eventText,
	isEmptyPipeline,
	orderedSteps,
	planStateKey,
	stepNameKey,
	stepStateKey,
	type PipelineApi,
	type PipelineStepState,
	type TaskPipeline,
	type TaskPlan
} from '../src/lib/pipeline';

const plan = (over: Partial<TaskPlan> = {}): TaskPlan => ({ version: 1, body: 'Plan', state: 'proposed', authorType: 'integration', authorLabel: 'claude-code', writtenAt: '2026-11-25T08:00:00Z', ...over });
const pipeline = (over: Partial<TaskPipeline> = {}): TaskPipeline => ({
	taskID: 't1',
	steps: PIPELINE_STEPS.map((step) => ({ step, state: 'pending' as PipelineStepState })),
	events: [],
	...over
});
const proposed = (over: Partial<TaskPlan> = {}) => pipeline({ plan: plan(over) });

describe('pipeline rules', () => {
	it('knows the six steps in the fixed order', () => {
		expect(PIPELINE_STEPS).toEqual(['planner', 'approval', 'developer', 'validation', 'tester', 'review']);
	});

	it('shows steps in the fixed order and fills missing ones as pending', () => {
		const steps = orderedSteps(pipeline({ steps: [{ step: 'tester', state: 'running', note: 'n' }, { step: 'planner', state: 'done' }] }));
		expect(steps.map((s) => s.step)).toEqual([...PIPELINE_STEPS]);
		expect(steps.map((s) => s.state)).toEqual(['done', 'pending', 'pending', 'pending', 'running', 'pending']);
		expect(steps[4]!.note).toBe('n');
	});

	it('is empty only without a plan and with every step pending; missing and null plan are the same', () => {
		expect(isEmptyPipeline(null)).toBe(true);
		expect(isEmptyPipeline(pipeline())).toBe(true);
		expect(isEmptyPipeline(pipeline({ plan: null }))).toBe(true);
		expect(isEmptyPipeline(proposed())).toBe(false);
		expect(isEmptyPipeline(pipeline({ steps: [{ step: 'planner', state: 'running' }] }))).toBe(false);
		expect(isEmptyPipeline(pipeline({ steps: [{ step: 'planner', state: 'failed' }] }))).toBe(false);
	});

	it('waits for approval only while the plan is proposed', () => {
		expect(awaitingApproval(null)).toBe(false);
		expect(awaitingApproval(pipeline())).toBe(false);
		expect(awaitingApproval(proposed())).toBe(true);
		expect(awaitingApproval(proposed({ state: 'approved' }))).toBe(false);
		expect(awaitingApproval(proposed({ state: 'changes_requested' }))).toBe(false);
	});

	it('offers the decision only for a proposed plan and with edit permission', () => {
		expect(canDecide(proposed(), true)).toBe(true);
		expect(canDecide(proposed(), false)).toBe(false);
		expect(canDecide(proposed({ state: 'approved' }), true)).toBe(false);
		expect(canDecide(proposed({ state: 'changes_requested' }), true)).toBe(false);
		expect(canDecide(pipeline(), true)).toBe(false);
		expect(canDecide(null, true)).toBe(false);
	});

	it('names every step and state in German; unknown values never show raw codes', () => {
		expect(PIPELINE_STEPS.map((s) => de[stepNameKey(s)])).toEqual(['Planer', 'Freigabe', 'Entwickler', 'Validierung', 'Tester', 'Review']);
		const states = ['pending', 'running', 'waiting', 'changes_requested', 'done', 'failed', 'skipped'] as const;
		expect(states.map((s) => de[stepStateKey(s)])).toEqual(['Offen', 'Läuft', 'Wartet auf Freigabe', 'Änderungen angefragt', 'Fertig', 'Fehlgeschlagen', 'Übersprungen']);
		expect(de[stepStateKey('paused')]).toBe('Unbekannt');
		expect(de[stepNameKey('deploy')]).toBe('Weiterer Schritt');
		expect(de[planStateKey('proposed')]).toBe('Wartet auf Freigabe');
		expect(de[planStateKey('approved')]).toBe('Freigegeben');
		expect(de[planStateKey('changes_requested')]).toBe('Änderungen angefragt');
		expect(de[planStateKey('x')]).toBe('Unbekannt');
	});

	it('describes history events in German', () => {
		const e = { id: 'e', actorType: 'person', actorLabel: 'Ada', createdAt: '2026-11-25T08:00:00Z' };
		expect(eventText({ ...e, action: 'plan_written', planVersion: 2 })).toBe('Plan Version 2 geschrieben');
		expect(eventText({ ...e, action: 'plan_approved', planVersion: 2 })).toBe('Plan Version 2 freigegeben');
		expect(eventText({ ...e, action: 'plan_changes_requested', planVersion: 1 })).toBe('Änderungen zu Plan Version 1 angefragt');
		expect(eventText({ ...e, action: 'step_changed', step: 'developer', state: 'running' })).toBe('Entwickler: Läuft');
		expect(eventText({ ...e, action: 'something_new' })).toBe('Pipeline geändert');
	});

	it('requires a comment only for changes and limits its length', () => {
		expect(decisionProblem('approve', '')).toBeNull();
		expect(decisionProblem('request_changes', '  \n ')).toBe('comment_required');
		expect(decisionProblem('request_changes', 'Bitte kürzer')).toBeNull();
		expect(decisionProblem('approve', 'a'.repeat(4001))).toBe('invalid_comment');
		expect(decisionProblem('request_changes', 'a'.repeat(4000))).toBeNull();
	});

	it('maps every refusal of the server to a clear German message', () => {
		const key = (status: number, reason?: string) => decisionErrorKey(new ApiError(status, reason));
		expect(key(409, 'plan_changed')).toBe('pipeline.error.planChanged');
		expect(key(409, 'plan_not_pending')).toBe('pipeline.error.notPending');
		expect(key(409, 'no_plan')).toBe('pipeline.error.noPlan');
		expect(key(404, 'no_plan')).toBe('pipeline.error.noPlan');
		expect(key(400, 'comment_required')).toBe('pipeline.error.commentRequired');
		expect(key(400, 'invalid_comment')).toBe('pipeline.error.invalidComment');
		expect(key(403, 'brain_mandate_required')).toBe('pipeline.error.forbidden');
		expect(key(403)).toBe('pipeline.error.forbidden');
		expect(key(0, 'network')).toBe('pipeline.error.network');
		expect(key(500)).toBe('pipeline.error.generic');
		expect(decisionErrorKey(new Error('x'))).toBe('pipeline.error.generic');
	});

	it('has activity labels for the new card events', () => {
		for (const kind of ['plan.written', 'plan.approved', 'plan.changes_requested', 'pipeline.step']) expect(`activity.kind.${kind}` in de, kind).toBe(true);
	});
});

describe('plan markdown', () => {
	it('keeps numbered steps apart when ordered lists are requested, and leaves other views unchanged', () => {
		const src = 'Ablauf:\n\n1. Lesen\n2. Bauen\n\n- Punkt';
		expect(parseMarkdown(src, { ordered: true })).toEqual([
			{ kind: 'paragraph', inline: [{ kind: 'text', text: 'Ablauf:' }] },
			{ kind: 'list', ordered: true, start: 1, items: [[{ kind: 'text', text: 'Lesen' }], [{ kind: 'text', text: 'Bauen' }]] },
			{ kind: 'list', items: [[{ kind: 'text', text: 'Punkt' }]] }
		]);
		expect(parseMarkdown('1. a\n2. b')).toEqual([{ kind: 'paragraph', inline: [{ kind: 'text', text: '1. a 2. b' }] }]);
	});
	it('starts a new list when the list type changes and keeps the first number', () => {
		const blocks = parseMarkdown('- a\n3) b', { ordered: true });
		expect(blocks).toHaveLength(2);
		expect(blocks[1]).toMatchObject({ kind: 'list', ordered: true, start: 3 });
	});
});

describe('pipeline API calls', () => {
	const recorder = (response: () => Response) => {
		const calls: { url: string; init?: RequestInit }[] = [];
		const fetchFn: FetchLike = async (url, init) => (calls.push({ url, init }), response());
		return { calls, api: createApi(fetchFn) };
	};

	it('reads the pipeline of a task', async () => {
		const { calls, api } = recorder(() => Response.json(pipeline()));
		await api.taskPipeline('t1');
		expect(calls[0]!.url).toBe('/v1/tasks/t1/pipeline');
		expect(calls[0]!.init?.method).toBe('GET');
	});

	it('sends the decision with the shown version; an empty comment is omitted', async () => {
		const { calls, api } = recorder(() => Response.json(pipeline()));
		await api.decidePlan('t1', { decision: 'approve', version: 3, comment: '' });
		await api.decidePlan('t1', { decision: 'request_changes', version: 4, comment: 'Anders' });
		expect(calls.map((c) => c.url)).toEqual(['/v1/tasks/t1/plan/decision', '/v1/tasks/t1/plan/decision']);
		expect(calls[0]!.init?.method).toBe('POST');
		expect(JSON.parse(calls[0]!.init?.body as string)).toEqual({ decision: 'approve', version: 3 });
		expect(JSON.parse(calls[1]!.init?.body as string)).toEqual({ decision: 'request_changes', version: 4, comment: 'Anders' });
	});
});

function deferred<T>() {
	let resolve!: (v: T) => void;
	let reject!: (e: unknown) => void;
	const promise = new Promise<T>((res, rej) => ((resolve = res), (reject = rej)));
	return { promise, resolve, reject };
}
function setup(initial: TaskPipeline | (() => Promise<TaskPipeline>) = proposed()) {
	const server = { current: initial };
	const api = {
		taskPipeline: vi.fn<PipelineApi['taskPipeline']>(async () => (typeof server.current === 'function' ? server.current() : structuredClone(server.current))),
		decidePlan: vi.fn<PipelineApi['decidePlan']>(async () => proposed({ state: 'approved' }))
	};
	const view = emptyPipelineView();
	return { server, api, view, ctl: createPipelineController(view, api) };
}

describe('pipeline controller', () => {
	it('loads on open and shows the pipeline', async () => {
		const { view, ctl, api } = setup();
		const done = ctl.open('t1');
		expect(view.status).toBe('loading');
		await done;
		expect(api.taskPipeline).toHaveBeenCalledWith('t1');
		expect(view.status).toBe('ready');
		expect(view.data?.plan?.version).toBe(1);
	});

	it('treats a server without the endpoint (404) as an empty pipeline, not as an error', async () => {
		const { view, ctl } = setup(() => Promise.reject(new ApiError(404)));
		await ctl.open('t1');
		expect(view.status).toBe('ready');
		expect(view.data).toBeNull();
		expect(view.feedback).toBeNull();
	});

	it('reports a failed first load and recovers on the next refresh; later failures keep the shown data', async () => {
		const { view, ctl, server } = setup(() => Promise.reject(new ApiError(500)));
		await ctl.open('t1');
		expect(view.status).toBe('failed');
		server.current = proposed();
		await ctl.refresh();
		expect(view.status).toBe('ready');
		server.current = () => Promise.reject(new ApiError(0, 'network'));
		await ctl.refresh();
		expect(view.status).toBe('ready');
		expect(view.data?.plan?.version).toBe(1);
	});

	it('keeps the same object on an identical refresh (no re-render)', async () => {
		const { view, ctl } = setup();
		await ctl.open('t1');
		const before = view.data;
		await ctl.refresh();
		expect(view.data).toBe(before);
	});

	it('keeps the typed comment across a refresh and announces a rewritten plan', async () => {
		const { view, ctl, server } = setup();
		await ctl.open('t1');
		view.comment = 'halb getippt';
		server.current = proposed({ version: 2, body: 'Neu' });
		await ctl.refresh();
		expect(view.comment).toBe('halb getippt');
		expect(view.data?.plan?.version).toBe(2);
		expect(view.feedback).toEqual({ tone: 'info', key: 'pipeline.feedback.newVersion', params: { version: 2 } });
	});

	it('resets comment and message when another card is opened and drops late answers of the old one', async () => {
		const first = deferred<TaskPipeline>();
		const { view, ctl, server } = setup(() => first.promise);
		const old = ctl.open('t1');
		view.comment = 'alt';
		server.current = pipeline({ taskID: 't2' });
		await ctl.open('t2');
		first.resolve(proposed());
		await old;
		expect(view.comment).toBe('');
		expect(view.data?.taskID).toBe('t2');
	});

	it('approves the shown version, clears the comment and confirms', async () => {
		const { view, ctl, api } = setup(proposed({ version: 3 }));
		await ctl.open('t1');
		view.comment = '  passt  ';
		expect(await ctl.decide('approve', true)).toBe('done');
		expect(api.decidePlan).toHaveBeenCalledWith('t1', { decision: 'approve', version: 3, comment: 'passt' });
		expect(view.data?.plan?.state).toBe('approved');
		expect(view.comment).toBe('');
		expect(view.busy).toBeNull();
		expect(view.feedback).toEqual({ tone: 'success', key: 'pipeline.feedback.approved' });
	});

	it('does not send changes without a comment and says what is missing', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('t1');
		expect(await ctl.decide('request_changes', true)).toBe('invalid');
		expect(api.decidePlan).not.toHaveBeenCalled();
		expect(view.problem).toBe('comment_required');
		ctl.type('x');
		expect(view.comment).toBe('x');
		expect(view.problem).toBeNull();
		await ctl.decide('request_changes', true);
		expect(view.feedback?.key).toBe('pipeline.feedback.changesRequested');
	});

	it('never decides without permission, without a proposed plan or twice at once', async () => {
		const slow = deferred<TaskPipeline>();
		const { view, ctl, api } = setup();
		await ctl.open('t1');
		expect(await ctl.decide('approve', false)).toBe('ignored');
		api.decidePlan.mockImplementation(() => slow.promise);
		const one = ctl.decide('approve', true);
		expect(view.busy).toBe('approve');
		expect(await ctl.decide('approve', true)).toBe('ignored');
		expect(await ctl.decide('request_changes', true)).toBe('ignored');
		slow.resolve(proposed({ state: 'approved' }));
		await one;
		expect(await ctl.decide('approve', true)).toBe('ignored'); // not pending any more
		expect(api.decidePlan).toHaveBeenCalledTimes(1);
	});

	it('on plan_changed reloads the plan, keeps the comment, explains it and does not decide again', async () => {
		const { view, ctl, api, server } = setup();
		await ctl.open('t1');
		view.comment = 'mein Kommentar';
		api.decidePlan.mockRejectedValue(new ApiError(409, 'plan_changed'));
		server.current = proposed({ version: 2 });
		expect(await ctl.decide('approve', true)).toBe('failed');
		expect(view.data?.plan?.version).toBe(2);
		expect(view.comment).toBe('mein Kommentar');
		expect(view.feedback).toEqual({ tone: 'error', key: 'pipeline.error.planChanged' });
		expect(api.decidePlan).toHaveBeenCalledTimes(1);
		expect(view.busy).toBeNull();
	});

	it('keeps the plan_changed message while a decision is still open and drops it once someone else decided', async () => {
		const { view, ctl, api, server } = setup();
		await ctl.open('t1');
		api.decidePlan.mockRejectedValue(new ApiError(409, 'plan_changed'));
		server.current = proposed({ version: 2 });
		await ctl.decide('approve', true);
		server.current = proposed({ version: 3 });
		await ctl.refresh();
		expect(view.feedback?.key).toBe('pipeline.error.planChanged');
		server.current = proposed({ version: 3, state: 'approved' });
		await ctl.refresh();
		expect(view.feedback).toBeNull();
	});

	it('keeps the comment and the plan on other errors and allows a retry', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('t1');
		view.comment = 'bleibt';
		api.decidePlan.mockRejectedValueOnce(new ApiError(0, 'network'));
		await ctl.decide('approve', true);
		expect(view.comment).toBe('bleibt');
		expect(view.feedback?.key).toBe('pipeline.error.network');
		expect(api.taskPipeline).toHaveBeenCalledTimes(1);
		expect(await ctl.decide('approve', true)).toBe('done');
	});

	it('a read started before the decision cannot bring the old state back', async () => {
		const { view, ctl, server } = setup();
		await ctl.open('t1');
		const stale = deferred<TaskPipeline>();
		server.current = () => stale.promise;
		const reading = ctl.refresh();
		await ctl.decide('approve', true);
		stale.resolve(proposed());
		await reading;
		expect(view.data?.plan?.state).toBe('approved');
	});

	it('an answer for a card that was left changes nothing', async () => {
		const slow = deferred<TaskPipeline>();
		const { view, ctl, api, server } = setup();
		await ctl.open('t1');
		api.decidePlan.mockImplementation(() => slow.promise);
		const deciding = ctl.decide('approve', true);
		server.current = pipeline({ taskID: 't2' });
		await ctl.open('t2');
		slow.resolve(proposed({ state: 'approved' }));
		expect(await deciding).toBe('ignored');
		expect(view.data?.taskID).toBe('t2');
		expect(view.feedback).toBeNull();
		expect(view.busy).toBeNull();
	});
});
