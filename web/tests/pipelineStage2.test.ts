import { describe, expect, it, vi } from 'vitest';
import { ApiError, createApi, type FetchLike } from '../src/lib/api';
import { describeError } from '../src/lib/errors';
import { de } from '../src/lib/i18n/de';
import {
	EFFORTS,
	PIPELINE_ROLES,
	PIPELINE_STEPS,
	awaitingApproval,
	canDecide,
	createPipelineController,
	effortKey,
	eventText,
	emptyPipelineView,
	isEmptyPipeline,
	offSteps,
	pipelineReasonKey,
	retryErrorKey,
	retryOffer,
	roleLine,
	stepCounts,
	stepOn,
	type PipelineApi,
	type PipelineStep,
	type PipelineStepName,
	type PipelineStepState,
	type TaskPipeline
} from '../src/lib/pipeline';

// Card B926E7D8 (pipeline stage 2): the card tab shows switched-off steps, model and effort per role and retries a failed step.
const step = (name: PipelineStepName, state: PipelineStepState = 'pending', over: Partial<PipelineStep> = {}): PipelineStep => ({ step: name, state, enabled: true, ...over });
const pipeline = (over: Partial<TaskPipeline> = {}, steps: PipelineStep[] = PIPELINE_STEPS.map((s) => step(s))): TaskPipeline => ({
	taskID: 't1',
	plan: { version: 2, body: 'Plan', state: 'approved' },
	steps,
	events: [],
	fixRounds: { used: 1, max: 3, remaining: 2 },
	...over
});
const failedTester = () => pipeline({}, PIPELINE_STEPS.map((s) => (s === 'tester' ? step(s, 'failed', { note: '2 Tests rot' }) : s === 'developer' ? step(s, 'done') : step(s))));

describe('switched-off steps', () => {
	it('treats a missing enabled flag (older server) as on', () => {
		expect(stepOn({ step: 'tester', state: 'pending' })).toBe(true);
		expect(stepOn(step('tester', 'pending', { enabled: false }))).toBe(false);
	});

	it('lists the steps that are off in the fixed order, from the step flags or the effective settings', () => {
		const p = pipeline({}, PIPELINE_STEPS.map((s) => step(s, 'pending', { enabled: s !== 'review' && s !== 'tester' })));
		expect(offSteps(p)).toEqual(['tester', 'review']);
		const onlySettings: TaskPipeline = {
			taskID: 't', steps: [], events: [],
			settings: { revision: 1, maxFixRounds: 3, notifyOnWaitingApproval: true, steps: { planner: false, approval: false, developer: true, validation: true, tester: true, review: true }, roles: {} }
		};
		expect(offSteps(onlySettings)).toEqual(['planner', 'approval']);
		expect(offSteps(null)).toEqual([]);
	});

	it('counts only the steps that are on; passed (done or skipped) steps count as finished', () => {
		const steps = PIPELINE_STEPS.map((s) =>
			s === 'planner' || s === 'approval' ? step(s, 'done') : s === 'validation' ? step(s, 'skipped') : s === 'tester' ? step(s, 'pending', { enabled: false }) : step(s)
		);
		expect(stepCounts(pipeline({}, steps))).toEqual({ done: 3, total: 5, off: 1 });
		expect(stepCounts(null)).toEqual({ done: 0, total: 0, off: 0 });
	});

	it('is still empty when nothing happened and only switched-off steps differ', () => {
		const steps = PIPELINE_STEPS.map((s) => step(s, s === 'tester' || s === 'review' ? 'skipped' : 'pending', { enabled: s !== 'tester' && s !== 'review' }));
		expect(isEmptyPipeline({ taskID: 't', steps, events: [] })).toBe(true);
		// An agent that really skipped a step that is on is activity.
		expect(isEmptyPipeline({ taskID: 't', steps: [step('validation', 'skipped')], events: [] })).toBe(false);
	});
});

describe('waiting for approval', () => {
	it('uses the server flag when present and the plan state otherwise', () => {
		const proposed = { version: 1, body: 'x', state: 'proposed' as const };
		expect(awaitingApproval(pipeline({ plan: proposed, waitingApproval: true }))).toBe(true);
		expect(awaitingApproval(pipeline({ plan: proposed, waitingApproval: false }))).toBe(false);
		expect(awaitingApproval(pipeline({ plan: proposed }))).toBe(true);
		expect(awaitingApproval(pipeline({ waitingApproval: true, plan: null }))).toBe(true);
		expect(awaitingApproval(pipeline())).toBe(false);
	});

	it('still decides by the plan state, never by the flag alone', () => {
		expect(canDecide(pipeline({ plan: { version: 1, body: 'x', state: 'proposed' }, waitingApproval: false }), true)).toBe(true);
		expect(canDecide(pipeline({ plan: { version: 1, body: 'x', state: 'approved' }, waitingApproval: true }), true)).toBe(false);
	});
});

describe('model and effort per role', () => {
	it('shows the settings of the role steps and nothing for validation and approval', () => {
		expect(roleLine(step('developer', 'pending', { role: { model: 'sonnet', effort: 'high' } }))).toEqual({ model: 'sonnet', effort: 'high' });
		expect(roleLine(step('tester', 'pending', { role: {} }))).toEqual({ model: null, effort: null });
		expect(roleLine(step('tester', 'pending', { role: { model: null, effort: null } }))).toEqual({ model: null, effort: null });
		expect(roleLine(step('validation'))).toBeNull();
		expect(roleLine(step('approval'))).toBeNull();
	});

	it('shows no role line for a step that is off', () => {
		expect(roleLine(step('tester', 'skipped', { enabled: false, role: { model: 'haiku' } }))).toBeNull();
	});

	it('names the five efforts in German and never shows an unknown code', () => {
		expect(EFFORTS).toEqual(['low', 'medium', 'high', 'xhigh', 'max']);
		expect(EFFORTS.map((e) => de[effortKey(e)])).toEqual(['Niedrig', 'Mittel', 'Hoch', 'Sehr hoch', 'Maximal']);
		expect(de[effortKey('turbo')]).toBe('Unbekannt');
		expect(de[effortKey(null)]).toBe('Standard');
	});

	it('knows the four roles', () => {
		expect(PIPELINE_ROLES).toEqual(['planner', 'developer', 'tester', 'reviewer']);
	});
});

describe('offer to retry a failed step', () => {
	it('is offered only at a failed step that is on, to people who may edit', () => {
		expect(retryOffer(failedTester(), 'tester', true)).toEqual({ kind: 'ready', round: 2, max: 3 });
		expect(retryOffer(failedTester(), 'tester', false)).toEqual({ kind: 'hidden' });
		expect(retryOffer(failedTester(), 'developer', true)).toEqual({ kind: 'hidden' });
		expect(retryOffer(failedTester(), 'review', true)).toEqual({ kind: 'hidden' });
		expect(retryOffer(null, 'tester', true)).toEqual({ kind: 'hidden' });
	});

	it('never offers it for the approval or for a step that is switched off', () => {
		const steps = PIPELINE_STEPS.map((s) => step(s, 'failed', { enabled: s !== 'review' }));
		const p = pipeline({}, steps);
		expect(retryOffer(p, 'approval', true)).toEqual({ kind: 'hidden' });
		expect(retryOffer(p, 'review', true)).toEqual({ kind: 'hidden' });
		expect(retryOffer(p, 'developer', true).kind).toBe('ready');
	});

	it('counts the round of the retry: the first retry is round 1, the last allowed one is round max', () => {
		expect(retryOffer(pipeline({ fixRounds: { used: 0, max: 3, remaining: 3 } }, [step('tester', 'failed')]), 'tester', true)).toEqual({ kind: 'ready', round: 1, max: 3 });
		expect(retryOffer(pipeline({ fixRounds: { used: 2, max: 3, remaining: 1 } }, [step('tester', 'failed')]), 'tester', true)).toEqual({ kind: 'ready', round: 3, max: 3 });
	});

	it('is exhausted when all rounds are used or none are allowed', () => {
		expect(retryOffer(pipeline({ fixRounds: { used: 3, max: 3, remaining: 0 } }, [step('tester', 'failed')]), 'tester', true)).toEqual({ kind: 'exhausted', max: 3 });
		expect(retryOffer(pipeline({ fixRounds: { used: 0, max: 0, remaining: 0 } }, [step('tester', 'failed')]), 'tester', true)).toEqual({ kind: 'exhausted', max: 0 });
		// Defensive: more used than allowed (the limit was lowered afterwards).
		expect(retryOffer(pipeline({ fixRounds: { used: 5, max: 3, remaining: -2 } }, [step('tester', 'failed')]), 'tester', true)).toEqual({ kind: 'exhausted', max: 3 });
	});

	it('is not offered by a server that does not know fix rounds (stage 1)', () => {
		expect(retryOffer(pipeline({ fixRounds: undefined }, [step('tester', 'failed')]), 'tester', true)).toEqual({ kind: 'hidden' });
	});
});

describe('German messages for the new refusals', () => {
	const codes = ['step_disabled', 'step_not_failed', 'fix_rounds_exhausted', 'plan_changed', 'revision_conflict', 'invalid_model', 'invalid_effort', 'invalid_pipeline_settings'];

	it('maps all eight new codes to a message without the raw code', () => {
		for (const code of codes) {
			const key = pipelineReasonKey(code);
			expect(key, code).not.toBeNull();
			expect(de[key!], code).toBeTruthy();
			expect(de[key!], code).not.toContain(code);
		}
		expect(pipelineReasonKey('something_else')).toBeNull();
		expect(pipelineReasonKey(undefined)).toBeNull();
	});

	it('explains the retry refusals', () => {
		const key = (status: number, reason?: string) => retryErrorKey(new ApiError(status, reason));
		expect(de[key(409, 'step_disabled')]).toContain('ausgeschaltet');
		expect(de[key(409, 'step_not_failed')]).toContain('nicht fehlgeschlagen');
		expect(de[key(409, 'fix_rounds_exhausted')]).toContain('Fix-Runden');
		expect(de[key(409, 'plan_changed')]).toContain('Plan');
		expect(key(409, 'plan_not_approved')).toBe('pipeline.error.planNotApproved');
		expect(key(409, 'step_managed')).toBe('pipeline.error.generic');
		expect(key(403)).toBe('pipeline.error.forbidden');
		expect(key(401)).toBe('error.unauthorized');
		expect(key(0, 'network')).toBe('pipeline.error.networkRetry');
		expect(key(500)).toBe('pipeline.error.generic');
		expect(retryErrorKey(new Error('x'))).toBe('pipeline.error.generic');
	});

	it('shows the German message for these codes wherever a request fails (for example the feed actions)', () => {
		for (const code of codes) {
			const text = describeError(new ApiError(409, code));
			expect(text, code).not.toBe(de['error.generic']);
			expect(text, code).not.toBe(de['conflict.body']);
			expect(text, code).not.toContain(code);
		}
		expect(describeError(new ApiError(400, 'invalid_model'))).toContain('Modell');
		expect(describeError(new ApiError(409, 'plan_not_pending'))).toBe(de['pipeline.error.notPending']);
	});
});

describe('history of the card', () => {
	it('describes a retry in German with the round', () => {
		const e = { id: 'e', actorType: 'person', actorLabel: 'Ada', createdAt: '2026-11-25T08:00:00Z', action: 'step_retried', step: 'tester', planVersion: 2 };
		expect(eventText(e)).toBe('Tester wiederholt (Plan Version 2)');
		expect(eventText({ ...e, step: 'unknown_step' })).toBe('Weiterer Schritt wiederholt (Plan Version 2)');
		expect('activity.kind.pipeline.step' in de).toBe(true);
	});
});

describe('retry API call', () => {
	const recorder = () => {
		const calls: { url: string; init?: RequestInit }[] = [];
		const fetchFn: FetchLike = async (url, init) => (calls.push({ url, init }), Response.json(pipeline()));
		return { calls, api: createApi(fetchFn) };
	};

	it('posts the shown plan version and the optional note to the step', async () => {
		const { calls, api } = recorder();
		await api.retryPipelineStep('t1', 'tester', { planVersion: 2 });
		await api.retryPipelineStep('t1', 'developer', { planVersion: 3, note: ' Nochmal ' });
		expect(calls.map((c) => c.url)).toEqual(['/v1/tasks/t1/pipeline/steps/tester/retry', '/v1/tasks/t1/pipeline/steps/developer/retry']);
		expect(calls[0]!.init?.method).toBe('POST');
		expect(JSON.parse(calls[0]!.init?.body as string)).toEqual({ planVersion: 2 });
		expect(JSON.parse(calls[1]!.init?.body as string)).toEqual({ planVersion: 3, note: 'Nochmal' });
	});

	it('omits the plan version when the card has no plan', async () => {
		const { calls, api } = recorder();
		await api.retryPipelineStep('t1', 'planner', {});
		expect(JSON.parse(calls[0]!.init?.body as string)).toEqual({});
	});

	it('sets a step with the plan version it was based on', async () => {
		const { calls, api } = recorder();
		await api.setPipelineStep('t1', 'tester', { state: 'running', planVersion: 4 });
		expect(calls[0]!.url).toBe('/v1/tasks/t1/pipeline/steps/tester');
		expect(calls[0]!.init?.method).toBe('PUT');
		expect(JSON.parse(calls[0]!.init?.body as string)).toEqual({ state: 'running', planVersion: 4 });
	});
});

function setup(initial: TaskPipeline = failedTester()) {
	const server = { current: initial };
	const api = {
		taskPipeline: vi.fn<PipelineApi['taskPipeline']>(async () => structuredClone(server.current)),
		decidePlan: vi.fn<PipelineApi['decidePlan']>(async () => server.current),
		retryPipelineStep: vi.fn<PipelineApi['retryPipelineStep']>(async () => pipeline({ fixRounds: { used: 2, max: 3, remaining: 1 } }, PIPELINE_STEPS.map((s) => step(s))))
	};
	const view = emptyPipelineView();
	return { server, api, view, ctl: createPipelineController(view, api) };
}

describe('retry controller', () => {
	it('retries the failed step with the shown plan version and shows the new state', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('t1');
		expect(await ctl.retry('tester', true)).toBe('done');
		expect(api.retryPipelineStep).toHaveBeenCalledWith('t1', 'tester', { planVersion: 2 });
		expect(view.data?.steps.find((s) => s.step === 'tester')?.state).toBe('pending');
		expect(view.data?.fixRounds?.used).toBe(2);
		expect(view.feedback).toEqual({ tone: 'success', key: 'pipeline.feedback.retried', params: { step: 'Tester' } });
		expect(view.retrying).toBeNull();
	});

	it('never retries without permission, at a step that did not fail, when exhausted, or twice at once', async () => {
		const { view, ctl, api, server } = setup();
		await ctl.open('t1');
		expect(await ctl.retry('tester', false)).toBe('ignored');
		expect(await ctl.retry('developer', true)).toBe('ignored');
		server.current = pipeline({ fixRounds: { used: 3, max: 3, remaining: 0 } }, [step('tester', 'failed')]);
		await ctl.refresh();
		expect(await ctl.retry('tester', true)).toBe('ignored');
		expect(api.retryPipelineStep).not.toHaveBeenCalled();
		server.current = failedTester();
		await ctl.refresh();
		let release!: () => void;
		api.retryPipelineStep.mockImplementationOnce(() => new Promise((resolve) => (release = () => resolve(pipeline()))));
		const one = ctl.retry('tester', true);
		expect(view.retrying).toBe('tester');
		expect(await ctl.retry('tester', true)).toBe('ignored');
		release();
		await one;
		expect(api.retryPipelineStep).toHaveBeenCalledTimes(1);
	});

	for (const reason of ['plan_changed', 'step_not_failed', 'step_disabled', 'fix_rounds_exhausted']) {
		it(`${reason}: reads the card again, says what happened and does not send again`, async () => {
			const { view, ctl, api, server } = setup();
			await ctl.open('t1');
			api.retryPipelineStep.mockRejectedValueOnce(new ApiError(409, reason));
			server.current = pipeline({ plan: { version: 3, body: 'Neu', state: 'approved' }, fixRounds: { used: 0, max: 3, remaining: 3 } }, [step('tester', 'pending')]);
			expect(await ctl.retry('tester', true)).toBe('failed');
			expect(view.data?.plan?.version).toBe(3);
			expect(view.feedback?.tone).toBe('error');
			expect(view.feedback?.key).toBe(retryErrorKey(new ApiError(409, reason)));
			expect(api.retryPipelineStep).toHaveBeenCalledTimes(1);
			expect(view.retrying).toBeNull();
		});
	}

	it('keeps the shown state on a network error and allows another try', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('t1');
		api.retryPipelineStep.mockRejectedValueOnce(new ApiError(0, 'network'));
		expect(await ctl.retry('tester', true)).toBe('failed');
		expect(view.feedback).toEqual({ tone: 'error', key: 'pipeline.error.networkRetry' });
		expect(view.data?.steps.find((s) => s.step === 'tester')?.state).toBe('failed');
		expect(await ctl.retry('tester', true)).toBe('done');
	});

	it('reads the card again when the answer is no pipeline', async () => {
		const { view, ctl, api, server } = setup();
		await ctl.open('t1');
		api.retryPipelineStep.mockResolvedValueOnce({} as TaskPipeline);
		server.current = pipeline({ fixRounds: { used: 2, max: 3, remaining: 1 } }, [step('tester', 'pending')]);
		expect(await ctl.retry('tester', true)).toBe('done');
		expect(view.data?.fixRounds?.used).toBe(2);
	});

	it('drops the answer of a card that was left', async () => {
		const { view, ctl, api, server } = setup();
		await ctl.open('t1');
		let release!: () => void;
		api.retryPipelineStep.mockImplementationOnce(() => new Promise((resolve) => (release = () => resolve(pipeline()))));
		const pending = ctl.retry('tester', true);
		server.current = pipeline({ taskID: 't2' }, [step('tester', 'running')]);
		await ctl.open('t2');
		release();
		expect(await pending).toBe('ignored');
		expect(view.data?.taskID).toBe('t2');
		expect(view.feedback).toBeNull();
		expect(view.retrying).toBeNull();
	});

	it('forgets a retry message when another card opens', async () => {
		const { view, ctl } = setup();
		await ctl.open('t1');
		await ctl.retry('tester', true);
		await ctl.open('t2');
		expect(view.feedback).toBeNull();
	});
});
