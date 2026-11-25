import { describe, expect, it, vi } from 'vitest';
import { ApiError, createApi, type FetchLike } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import {
	PIPELINE_STEPS,
	createPipelineController,
	emptyPipelineView,
	eventActor,
	eventText,
	isEmptyPipeline,
	type PipelineApi,
	type PipelineEvent,
	type PipelineStep,
	type PipelineStepName,
	type PipelineStepState,
	type TaskPipeline
} from '../src/lib/pipeline';
import {
	executionErrorKey,
	executionSection,
	executionStateKey,
	isActiveExecution,
	isBudgetHold,
	jobStateKey,
	liveStep,
	nothingToRun,
	pauseReasonKey,
	retryHintKey,
	type ExecutionApi,
	type PipelineExecution
} from '../src/lib/pipelineExecution';

// Card F5DD1C00 (pipeline stage 3, docs/PLAN-PIPELINE-STUFE-3.md sections 2, 3 and 6): the card tab starts, shows, continues and stops
// the execution of the pipeline on a runner.
const step = (name: PipelineStepName, state: PipelineStepState = 'pending', over: Partial<PipelineStep> = {}): PipelineStep => ({ step: name, state, enabled: true, ...over });
const execution = (over: Partial<PipelineExecution> = {}): PipelineExecution => ({
	id: 'e1',
	state: 'running',
	step: 'developer',
	bindingID: 'b1',
	bindingLabel: 'todo-repo',
	deviceLabel: 'Mac Studio',
	runnerSupportsPipeline: true,
	jobID: 'j1',
	jobState: 'running',
	jobProgress: 'Baut das Formular',
	...over
});
const pipeline = (over: Partial<TaskPipeline> = {}, steps: PipelineStep[] = PIPELINE_STEPS.map((s) => step(s))): TaskPipeline => ({
	taskID: 't1',
	plan: { version: 2, body: 'Plan', state: 'approved' },
	steps,
	events: [],
	fixRounds: { used: 0, max: 3, remaining: 3 },
	...over
});
const binding = { id: 'b1', projectID: 'p1', deviceID: 'd1', repositoryKey: 'k', label: 'todo-repo', deviceLabel: 'Mac Studio' };
const devices = [
	{ id: 'd1', label: 'Mac Studio', paired: true, activeRunCount: 0, bindings: [{ id: 'b1', projectID: 'p1', deviceID: 'd1', repositoryKey: 'k', label: 'todo-repo' }, { id: 'bx', projectID: 'p2', deviceID: 'd1', repositoryKey: 'k', label: 'other' }] },
	{ id: 'd2', label: 'MacBook', paired: true, activeRunCount: 0, bindings: [{ id: 'b2', projectID: 'p1', deviceID: 'd2', repositoryKey: 'k', label: 'laptop' }] },
	{ id: 'd3', label: 'Alt', paired: true, revokedAt: '2026-11-01T00:00:00Z', activeRunCount: 0, bindings: [{ id: 'b3', projectID: 'p1', deviceID: 'd3', repositoryKey: 'k', label: 'alt' }] }
];

describe('execution rules', () => {
	it('counts running, waiting, blocked and paused as active; completed and stopped as ended', () => {
		expect((['running', 'waiting_approval', 'blocked', 'paused'] as const).map((state) => isActiveExecution(execution({ state })))).toEqual([true, true, true, true]);
		expect((['completed', 'stopped'] as const).map((state) => isActiveExecution(execution({ state })))).toEqual([false, false]);
		expect(isActiveExecution(null)).toBe(false);
		expect(isActiveExecution(undefined)).toBe(false);
	});

	it('names every state and pause reason in German and never shows a code', () => {
		expect((['running', 'waiting_approval', 'blocked', 'paused', 'completed', 'stopped'] as const).map((s) => de[executionStateKey(s)])).toEqual([
			'Läuft',
			'Wartet auf Freigabe',
			'Blockiert',
			'Angehalten',
			'Abgeschlossen',
			'Gestoppt'
		]);
		expect(de[executionStateKey('exploded')]).toBe('Unbekannt');
		expect(de[pauseReasonKey('plan_needs_owner')]).toContain('Plan');
		expect(de[pauseReasonKey('task_changed')]).toContain('Titel oder Beschreibung');
		expect(de[pauseReasonKey('continue_required')]).toContain('Wiederholen');
		expect(de[pauseReasonKey('something_new')]).toContain('angehalten');
		expect(de[pauseReasonKey(null)]).not.toContain('_');
	});

	it('names the job states like the agents page does', () => {
		expect(de[jobStateKey('queued')]).toBe('Wartet');
		expect(de[jobStateKey('waiting_for_answer')]).toBe('Wartet auf Antwort');
		expect(de[jobStateKey('melting')]).toBe('Unbekannt');
	});

	it('recognises a budget hold only on a waiting job', () => {
		expect(isBudgetHold(execution({ jobState: 'queued', jobProgress: 'Kontingent-Bremse: Wochenlimit 92 %' }))).toBe(true);
		expect(isBudgetHold(execution({ jobState: 'running', jobProgress: 'Kontingent-Bremse: alt' }))).toBe(false);
		expect(isBudgetHold(execution({ jobState: 'queued', jobProgress: 'Wartet auf den Ordner' }))).toBe(false);
		expect(isBudgetHold(execution({ jobState: 'queued', jobProgress: null }))).toBe(false);
	});

	it('marks the running step with a line that says what the job does', () => {
		const line = (over: Partial<PipelineExecution>) => liveStep(pipeline({ execution: execution(over) }));
		expect(line({})).toEqual({ step: 'developer', tone: 'running', key: 'pipeline.exec.live.running', progress: 'Baut das Formular' });
		expect(line({ jobState: 'queued', jobProgress: '' })).toEqual({ step: 'developer', tone: 'waiting', key: 'pipeline.exec.live.queued', progress: null });
		expect(line({ jobState: 'claimed', jobProgress: null })).toMatchObject({ tone: 'running', key: 'pipeline.exec.live.claimed' });
		expect(line({ jobState: 'waiting_for_answer', jobProgress: null })).toMatchObject({ tone: 'warning', key: 'pipeline.exec.live.answer' });
		expect(line({ jobState: 'queued', jobProgress: 'Kontingent-Bremse: rot' })).toEqual({ step: 'developer', tone: 'warning', key: 'pipeline.exec.live.held', progress: 'Kontingent-Bremse: rot' });
		for (const state of ['waiting_approval', 'blocked', 'paused', 'completed', 'stopped'] as const) expect(line({ state })).toBeNull();
		expect(line({ step: null })).toBeNull();
		expect(liveStep(pipeline())).toBeNull();
		expect(liveStep(null)).toBeNull();
	});

	it('knows when no work step is left', () => {
		const steps = (state: PipelineStepState, over: Partial<Record<PipelineStepName, PipelineStepState>> = {}) => PIPELINE_STEPS.map((s) => step(s, over[s] ?? state));
		expect(nothingToRun(pipeline({}, steps('done')))).toBe(true);
		expect(nothingToRun(pipeline({}, steps('done', { tester: 'skipped' })))).toBe(true);
		expect(nothingToRun(pipeline({}, steps('done', { review: 'pending' })))).toBe(false);
		expect(nothingToRun(pipeline())).toBe(false);
		// A switched-off step is not work that is left.
		expect(nothingToRun(pipeline({}, PIPELINE_STEPS.map((s) => (s === 'review' ? step(s, 'pending', { enabled: false }) : step(s, 'done')))))).toBe(true);
		expect(nothingToRun(null)).toBe(false);
	});

	it('looks like stage 2 without an execution and without a binding', () => {
		expect(executionSection(pipeline(), [], true)).toEqual({ show: false, start: false });
		expect(executionSection(pipeline(), [binding], false)).toEqual({ show: false, start: false });
		expect(executionSection(null, [binding], true)).toEqual({ show: false, start: false });
	});

	it('offers the start to the person allowed to start, never beside an active execution', () => {
		expect(executionSection(pipeline(), [binding], true)).toEqual({ show: true, start: true });
		for (const state of ['running', 'waiting_approval', 'blocked', 'paused'] as const) expect(executionSection(pipeline({ execution: execution({ state }) }), [binding], true)).toEqual({ show: true, start: false });
		for (const state of ['completed', 'stopped'] as const) expect(executionSection(pipeline({ execution: execution({ state }) }), [binding], true)).toEqual({ show: true, start: true });
		// The status is for everybody who sees the card.
		expect(executionSection(pipeline({ execution: execution() }), [], false)).toEqual({ show: true, start: false });
		const finished = pipeline({}, PIPELINE_STEPS.map((s) => step(s, 'done')));
		expect(executionSection(finished, [binding], true)).toEqual({ show: true, start: false });
	});

	it('an execution is activity: the card is not "empty" any more', () => {
		expect(isEmptyPipeline(pipeline({ plan: null }))).toBe(true);
		expect(isEmptyPipeline(pipeline({ plan: null, execution: execution() }))).toBe(false);
	});

	it('says at the retry that the step runs again, or that the owner has to continue', () => {
		expect(retryHintKey(pipeline({ execution: execution({ state: 'blocked' }) }), true)).toBe('pipeline.exec.retryRuns');
		expect(retryHintKey(pipeline({ execution: execution({ state: 'blocked' }) }), false)).toBe('pipeline.exec.retryNeedsOwner');
		expect(retryHintKey(pipeline({ execution: execution({ state: 'stopped' }) }), true)).toBeNull();
		expect(retryHintKey(pipeline(), true)).toBeNull();
		expect(de['pipeline.exec.retryRuns']).toContain('erneut');
	});

	it('has a German message for every refusal', () => {
		const message = (status: number, reason?: string) => de[executionErrorKey(new ApiError(status, reason))];
		for (const reason of ['execution_id_conflict', 'execution_active', 'nothing_to_run', 'no_execution', 'plan_changed']) {
			expect(message(409, reason)).toBeTruthy();
			expect(message(409, reason)).not.toBe(message(409, 'whatever'));
			expect(message(409, reason)).not.toContain(reason);
		}
		expect(message(403)).toContain('Projekteigentümer');
		expect(message(404)).toContain('nicht gefunden');
		expect(message(0)).toContain('nicht erreichbar');
		expect(message(401)).toBe(de['error.unauthorized']);
	});
});

describe('history and activity of the execution', () => {
	const event = (action: string, over: Partial<PipelineEvent> = {}): PipelineEvent => ({ id: action, action, ...over });
	it('names the four audit actions', () => {
		expect(['execution_started', 'execution_continued', 'execution_stopped', 'execution_completed'].map((a) => eventText(event(a)))).toEqual([
			'Ausführung gestartet',
			'Ausführung fortgesetzt',
			'Ausführung gestoppt',
			'Ausführung abgeschlossen'
		]);
	});

	it('calls a run without a name "Runner"', () => {
		expect(eventActor(event('step_changed', { actorType: 'run' }))).toBe('Runner');
		expect(eventActor(event('step_changed', { actorType: 'run', actorLabel: 'Runner' }))).toBe('Runner');
		expect(eventActor(event('execution_started', { actorType: 'user', actorLabel: 'Kim' }))).toBe('Kim');
		expect(eventActor(event('plan_written'))).toBe(de['cc.update.anonymous']);
	});

	it('labels the card activity', () => {
		expect((de as Record<string, string>)['activity.kind.pipeline.execution']).toBe('Pipeline-Ausführung geändert');
	});
});

describe('API', () => {
	it('uses the three execution routes', async () => {
		const calls: { url: string; method?: string; body: unknown }[] = [];
		const fetcher: FetchLike = async (url, init) => {
			calls.push({ url: String(url), method: init?.method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
			return new Response(JSON.stringify(pipeline()), { status: 200, headers: { 'Content-Type': 'application/json' } });
		};
		const api = createApi(fetcher);
		await api.startPipelineExecution('t1', { id: 'e1', bindingID: 'b1' });
		await api.continuePipelineExecution('t1', { planVersion: 3 });
		await api.stopPipelineExecution('t1');
		expect(calls).toEqual([
			{ url: '/v1/tasks/t1/pipeline/execution', method: 'POST', body: { id: 'e1', bindingID: 'b1' } },
			{ url: '/v1/tasks/t1/pipeline/execution/continue', method: 'POST', body: { planVersion: 3 } },
			{ url: '/v1/tasks/t1/pipeline/execution/stop', method: 'POST', body: {} }
		]);
	});
});

type FullApi = PipelineApi & ExecutionApi;
const fakeApi = (over: Partial<FullApi> = {}) => ({
	taskPipeline: vi.fn(async () => pipeline()),
	decidePlan: vi.fn(async () => pipeline()),
	retryPipelineStep: vi.fn(async () => pipeline()),
	listDevices: vi.fn(async () => devices),
	startPipelineExecution: vi.fn(async () => pipeline({ execution: execution({ jobState: 'queued' }) })),
	continuePipelineExecution: vi.fn(async () => pipeline({ execution: execution() })),
	stopPipelineExecution: vi.fn(async () => pipeline({ execution: execution({ state: 'stopped', jobState: 'cancelled' }) })),
	...over
});
async function opened(api = fakeApi(), mayStart = true) {
	const view = emptyPipelineView();
	const controller = createPipelineController(view, api);
	await controller.open('t1');
	await controller.loadBindings('p1', mayStart);
	return { view, controller, api };
}

describe('bindings of the person', () => {
	it('lists the own bindings of the project on devices that may still work and preselects the first', async () => {
		const { view } = await opened();
		expect(view.bindings.map((b) => [b.id, b.deviceLabel])).toEqual([
			['b1', 'Mac Studio'],
			['b2', 'MacBook']
		]);
		expect(view.bindingID).toBe('b1');
	});

	it('keeps the chosen binding over a reload', async () => {
		const { view, controller } = await opened();
		controller.choose('b2');
		await controller.loadBindings('p1', true);
		await controller.refresh();
		expect(view.bindingID).toBe('b2');
	});

	it('does not even ask for people who may not start', async () => {
		const { view, api } = await opened(fakeApi(), false);
		expect(api.listDevices).not.toHaveBeenCalled();
		expect(view.bindings).toEqual([]);
	});

	it('treats a refusal (403) or any failure as "no binding"', async () => {
		const { view } = await opened(fakeApi({ listDevices: vi.fn(async () => Promise.reject(new ApiError(403, 'forbidden'))) }));
		expect(view.bindings).toEqual([]);
		expect(view.bindingID).toBe('');
		expect(view.feedback).toBeNull();
	});

	it('drops the answer for a card that was left', async () => {
		let release = (_: typeof devices) => {};
		const api = fakeApi({ listDevices: vi.fn(() => new Promise<typeof devices>((r) => (release = r))) });
		const view = emptyPipelineView();
		const controller = createPipelineController(view, api);
		await controller.open('t1');
		const late = controller.loadBindings('p1', true);
		await controller.open('t2');
		release(devices);
		await late;
		expect(view.bindings).toEqual([]);
	});
});

describe('start', () => {
	it('sends one request with a fresh id and the chosen binding and shows the running execution', async () => {
		const { view, controller, api } = await opened();
		controller.choose('b2');
		const first = controller.startExecution(true);
		expect(view.acting).toBe('start');
		expect(await controller.startExecution(true)).toBe('ignored');
		expect(await first).toBe('done');
		expect(api.startPipelineExecution).toHaveBeenCalledTimes(1);
		const [taskID, input] = (api.startPipelineExecution as ReturnType<typeof vi.fn>).mock.calls[0]!;
		expect(taskID).toBe('t1');
		expect(input.bindingID).toBe('b2');
		expect(input.id).toMatch(/^[0-9a-f-]{36}$/i);
		expect(view.data?.execution?.state).toBe('running');
		expect(view.acting).toBeNull();
		expect(view.feedback).toMatchObject({ tone: 'success', key: 'pipeline.exec.feedback.started' });
	});

	it('does nothing without the right, without a binding or beside an active execution', async () => {
		const a = await opened();
		expect(await a.controller.startExecution(false)).toBe('ignored');
		const b = await opened(fakeApi({ listDevices: vi.fn(async () => []) }));
		expect(await b.controller.startExecution(true)).toBe('ignored');
		const c = await opened(fakeApi({ taskPipeline: vi.fn(async () => pipeline({ execution: execution() })) }));
		expect(await c.controller.startExecution(true)).toBe('ignored');
		for (const x of [a, b, c]) expect(x.api.startPipelineExecution).not.toHaveBeenCalled();
	});

	it('repeats the same id after a lost connection and takes a new one after a refusal', async () => {
		let answers: (ApiError | null)[] = [new ApiError(0), new ApiError(409, 'execution_id_conflict'), null];
		const start = vi.fn(async (_task: string, _input: { id: string; bindingID: string }) => {
			const next = answers.shift();
			if (next) throw next;
			return pipeline({ execution: execution() });
		});
		const { view, controller } = await opened(fakeApi({ startPipelineExecution: start }));
		expect(await controller.startExecution(true)).toBe('failed');
		expect(view.feedback).toMatchObject({ tone: 'error', key: 'pipeline.exec.error.network' });
		expect(await controller.startExecution(true)).toBe('failed');
		expect(await controller.startExecution(true)).toBe('done');
		const ids = start.mock.calls.map((c) => c[1].id);
		expect(ids[1]).toBe(ids[0]);
		expect(ids[2]).not.toBe(ids[1]);
	});

	it('reads the card again when somebody else already started', async () => {
		const read = vi.fn().mockResolvedValueOnce(pipeline()).mockResolvedValue(pipeline({ execution: execution() }));
		const { view, controller } = await opened(fakeApi({ taskPipeline: read, startPipelineExecution: vi.fn(async () => Promise.reject(new ApiError(409, 'execution_active'))) }));
		expect(await controller.startExecution(true)).toBe('failed');
		expect(view.data?.execution?.state).toBe('running');
		expect(view.feedback).toMatchObject({ tone: 'error', key: 'pipeline.exec.error.active' });
	});

	it('loads the bindings again when the chosen one is gone', async () => {
		const { api, controller } = await opened(fakeApi({ startPipelineExecution: vi.fn(async () => Promise.reject(new ApiError(404, 'binding_not_found'))) }));
		await controller.startExecution(true);
		expect(api.listDevices).toHaveBeenCalledTimes(2);
	});

	it('never accepts a plan version nobody has seen with the first click', async () => {
		const read = vi.fn().mockResolvedValueOnce(pipeline()).mockResolvedValue(pipeline({ plan: { version: 3, body: 'Neu', state: 'approved' } }));
		const { view, controller, api } = await opened(fakeApi({ taskPipeline: read }));
		await controller.refresh();
		expect(await controller.startExecution(true)).toBe('unread');
		expect(api.startPipelineExecution).not.toHaveBeenCalled();
		expect(view.confirmExecution).toBe('start');
		expect(view.feedback).toMatchObject({ key: 'pipeline.exec.feedback.readFirst', params: { version: 3 } });
		expect(await controller.startExecution(true)).toBe('done');
		expect(view.confirmExecution).toBeNull();
		expect(view.unread).toBe(false);
	});
});

describe('continue and stop', () => {
	const paused = () => pipeline({ execution: execution({ state: 'paused', reason: 'task_changed', jobState: null, jobID: null }) });

	it('continues with the plan version the person sees', async () => {
		const { view, controller, api } = await opened(fakeApi({ taskPipeline: vi.fn(async () => paused()) }));
		expect(await controller.continueExecution(true)).toBe('done');
		expect(api.continuePipelineExecution).toHaveBeenCalledWith('t1', { planVersion: 2 });
		expect(view.data?.execution?.state).toBe('running');
		expect(view.feedback).toMatchObject({ tone: 'success', key: 'pipeline.exec.feedback.continued' });
	});

	it('sends no version without a plan', async () => {
		const { controller, api } = await opened(fakeApi({ taskPipeline: vi.fn(async () => ({ ...paused(), plan: null })) }));
		await controller.continueExecution(true);
		expect(api.continuePipelineExecution).toHaveBeenCalledWith('t1', {});
	});

	it('continues only a paused execution and only with the right', async () => {
		const a = await opened(fakeApi({ taskPipeline: vi.fn(async () => paused()) }));
		expect(await a.controller.continueExecution(false)).toBe('ignored');
		const b = await opened(fakeApi({ taskPipeline: vi.fn(async () => pipeline({ execution: execution() })) }));
		expect(await b.controller.continueExecution(true)).toBe('ignored');
		expect(a.api.continuePipelineExecution).not.toHaveBeenCalled();
		expect(b.api.continuePipelineExecution).not.toHaveBeenCalled();
	});

	it('asks to read a replaced plan first and shows it after "plan_changed"', async () => {
		const newer = { ...paused(), plan: { version: 3, body: 'Neu', state: 'approved' as const } };
		const read = vi.fn().mockResolvedValueOnce(paused()).mockResolvedValue(newer);
		const refusing = vi.fn(async () => Promise.reject(new ApiError(409, 'plan_changed')));
		const { view, controller } = await opened(fakeApi({ taskPipeline: read, continuePipelineExecution: refusing }));
		expect(await controller.continueExecution(true)).toBe('failed');
		expect(view.data?.plan?.version).toBe(3);
		expect(view.feedback).toMatchObject({ tone: 'error', key: 'pipeline.exec.error.planChanged' });
		expect(await controller.continueExecution(true)).toBe('unread');
		expect(refusing).toHaveBeenCalledTimes(1);
	});

	it('stops an active execution once', async () => {
		const { view, controller, api } = await opened(fakeApi({ taskPipeline: vi.fn(async () => pipeline({ execution: execution() })) }));
		expect(await controller.stopExecution(false)).toBe('ignored');
		const first = controller.stopExecution(true);
		expect(await controller.stopExecution(true)).toBe('ignored');
		expect(await first).toBe('done');
		expect(api.stopPipelineExecution).toHaveBeenCalledTimes(1);
		expect(view.data?.execution?.state).toBe('stopped');
		expect(view.feedback).toMatchObject({ tone: 'success', key: 'pipeline.exec.feedback.stopped' });
		expect(await controller.stopExecution(true)).toBe('ignored');
	});

	it('explains a stop that came too late and shows the state', async () => {
		const read = vi.fn().mockResolvedValueOnce(pipeline({ execution: execution() })).mockResolvedValue(pipeline({ execution: execution({ state: 'completed' }) }));
		const { view, controller } = await opened(fakeApi({ taskPipeline: read, stopPipelineExecution: vi.fn(async () => Promise.reject(new ApiError(409, 'no_execution'))) }));
		expect(await controller.stopExecution(true)).toBe('failed');
		expect(view.data?.execution?.state).toBe('completed');
		expect(view.feedback).toMatchObject({ tone: 'error', key: 'pipeline.exec.error.none' });
	});

	it('says after a retry whether the step runs again or waits for the owner', async () => {
		const blocked = pipeline({ execution: execution({ state: 'blocked', step: 'tester' }) }, PIPELINE_STEPS.map((s) => step(s, s === 'tester' ? 'failed' : 'pending')));
		for (const [after, key] of [
			[execution({ state: 'running', step: 'tester', jobState: 'queued' }), 'pipeline.exec.feedback.retriedRunning'],
			[execution({ state: 'paused', reason: 'continue_required' }), 'pipeline.exec.feedback.retriedPaused']
		] as const) {
			const { view, controller } = await opened(fakeApi({ taskPipeline: vi.fn(async () => blocked), retryPipelineStep: vi.fn(async () => pipeline({ execution: after })) }));
			await controller.retryStep('tester', true);
			expect(view.feedback).toMatchObject({ tone: 'success', key, params: { step: 'Tester' } });
		}
	});

	it('drops a message about the execution when its state or step changes later', async () => {
		for (const later of [execution({ state: 'completed' }), execution({ step: 'validation' })]) {
			const read = vi.fn().mockResolvedValueOnce(pipeline()).mockResolvedValue(pipeline({ execution: later }));
			const { view, controller } = await opened(fakeApi({ taskPipeline: read }));
			await controller.startExecution(true);
			await controller.refresh();
			expect(view.feedback).toBeNull();
		}
	});
});
