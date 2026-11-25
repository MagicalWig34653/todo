/**
 * Plan approval and pipeline state of a card (card 74EC341D, contracts/pipeline.yaml; stage 2: card B926E7D8, docs/PLAN-PIPELINE-STUFE-2.md):
 * pure rules and the tab's controller.
 */
import type { MessageKey } from './i18n/index.js';
import { t } from './i18n/index.js';
import { bindingsForProject, type ProjectBinding } from './agentsLogic.js';
import { executionErrorKey, executionSection, isActiveExecution, type ExecutionAction, type ExecutionApi, type PipelineExecution } from './pipelineExecution.js';

export const PIPELINE_STEPS = ['planner', 'approval', 'developer', 'validation', 'tester', 'review'] as const;
export type PipelineStepName = (typeof PIPELINE_STEPS)[number];
const STEP_STATES = ['pending', 'running', 'waiting', 'changes_requested', 'done', 'failed', 'skipped'] as const;
export type PipelineStepState = (typeof STEP_STATES)[number];
const PLAN_STATES = ['proposed', 'approved', 'changes_requested'] as const;
export type PlanState = (typeof PLAN_STATES)[number];
export type PlanDecision = 'approve' | 'request_changes';
export const PLAN_COMMENT_MAX = 4000;
/** Roles of the project settings; each belongs to a step (the validation runs without an agent, the approval is a person). */
export const PIPELINE_ROLES = ['planner', 'developer', 'tester', 'reviewer'] as const;
export type PipelineRole = (typeof PIPELINE_ROLES)[number];
export const STEP_OF_ROLE: Record<PipelineRole, PipelineStepName> = { planner: 'planner', developer: 'developer', tester: 'tester', reviewer: 'review' };
export const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const;
export type Effort = (typeof EFFORTS)[number];

// The server omits nil fields: every optional field may be missing or null.
export interface TaskPlan {
	version: number;
	body: string;
	state: PlanState;
	authorType?: string | null;
	authorLabel?: string | null;
	writtenAt?: string | null;
	decidedAt?: string | null;
	decidedByLabel?: string | null;
	/** Stage 2: `system` = released automatically because the project has the approval off. */
	decidedByType?: string | null;
	decisionComment?: string | null;
}
/** Model and effort of a role; missing and null both mean "the runner's default". */
export interface RoleSetting {
	model?: string | null;
	effort?: string | null;
}
export interface PipelineStep {
	step: PipelineStepName;
	state: PipelineStepState;
	note?: string | null;
	actorLabel?: string | null;
	updatedAt?: string | null;
	/** Stage 2: false = the project switched the step off; missing (older server) = on. */
	enabled?: boolean;
	/** Stage 2: the plan version the stored state belongs to. */
	planVersion?: number | null;
	/** Stage 2: only the four role steps. */
	role?: RoleSetting | null;
}
/** Stage 2: the fix rounds of the current plan version. */
export interface FixRounds {
	used: number;
	max: number;
	remaining: number;
}
/** Stage 2: the settings in effect, without history. */
export interface EffectiveSettings {
	revision: number;
	steps: Partial<Record<PipelineStepName, boolean>>;
	roles: Partial<Record<PipelineRole, RoleSetting>>;
	maxFixRounds: number;
	notifyOnWaitingApproval: boolean;
}
export interface PipelineEvent {
	id: string;
	action: string;
	planVersion?: number | null;
	step?: string | null;
	state?: string | null;
	note?: string | null;
	actorType?: string | null;
	actorLabel?: string | null;
	createdAt?: string | null;
}
export interface TaskPipeline {
	taskID: string;
	plan?: TaskPlan | null;
	steps: PipelineStep[];
	/** Newest first, at most 50. */
	events: PipelineEvent[];
	settings?: EffectiveSettings | null;
	fixRounds?: FixRounds | null;
	/** True when the plan waits for a decision and the project has the approval on. */
	waitingApproval?: boolean | null;
	/** Stage 3: the execution on a runner; missing without one. */
	execution?: PipelineExecution | null;
}
export interface PlanDecisionInput {
	decision: PlanDecision;
	/** The version the person saw; the server refuses the decision (`plan_changed`) when it is not the current one. */
	version: number;
	comment?: string;
}

/** Always the six steps in the fixed order. */
export function orderedSteps(pipeline: Pick<TaskPipeline, 'steps'>): PipelineStep[] {
	return PIPELINE_STEPS.map((step) => pipeline.steps.find((s) => s.step === step) ?? { step, state: 'pending' });
}
/** Without a plan and without activity; a step that is off (shown as skipped) is no activity. */
export function isEmptyPipeline(p: TaskPipeline | null): boolean {
	return !p || (!p.plan && !p.execution && p.steps.every((s) => s.state === 'pending' || !stepOn(s)));
}
/** The server's flag when it sends one (stage 2), else the plan state (stage 1). */
export const awaitingApproval = (p: TaskPipeline | null): boolean => p?.waitingApproval ?? p?.plan?.state === 'proposed';
/** Only hides the controls; the server decides who may approve. The plan state, not the flag, decides whether there is something to decide. */
export const canDecide = (p: TaskPipeline | null, canEdit: boolean): boolean => canEdit && p?.plan?.state === 'proposed';

/** A step the project switched off; a missing flag (older server) counts as on. */
export const stepOn = (s: Pick<PipelineStep, 'enabled'>): boolean => s.enabled !== false;
/** Names of the steps that are off, in the fixed order (from the step flags, else from the settings in effect). */
export function offSteps(p: Pick<TaskPipeline, 'steps' | 'settings'> | null): PipelineStepName[] {
	if (!p) return [];
	return PIPELINE_STEPS.filter((name) => {
		const s = p.steps.find((x) => x.step === name);
		return s?.enabled !== undefined ? s.enabled === false : p.settings?.steps?.[name] === false;
	});
}
/** Steps that are on and passed (done or skipped by an agent) against all steps that are on; off steps are not counted. */
export function stepCounts(p: Pick<TaskPipeline, 'steps' | 'settings'> | null): { done: number; total: number; off: number } {
	if (!p) return { done: 0, total: 0, off: 0 };
	const off = offSteps(p);
	const on = orderedSteps(p).filter((s) => !off.includes(s.step));
	return { done: on.filter((s) => s.state === 'done' || s.state === 'skipped').length, total: on.length, off: off.length };
}
/** Model and effort of the role behind a step; null for steps without a role and for steps that are off. */
export function roleLine(s: PipelineStep): { model: string | null; effort: string | null } | null {
	if (!s.role || !stepOn(s)) return null;
	return { model: s.role.model || null, effort: s.role.effort || null };
}

export type RetryOffer = { kind: 'hidden' } | { kind: 'ready'; round: number; max: number } | { kind: 'exhausted'; max: number };
/** The retry at a failed step: only for people who may edit, only while fix rounds are left; the server decides in the end. */
export function retryOffer(p: TaskPipeline | null, step: PipelineStepName, canEdit: boolean): RetryOffer {
	const hidden: RetryOffer = { kind: 'hidden' };
	if (!p || !canEdit || step === 'approval' || !p.fixRounds) return hidden;
	const s = p.steps.find((x) => x.step === step);
	if (!s || s.state !== 'failed' || !stepOn(s)) return hidden;
	const { used, max } = p.fixRounds;
	return used >= max ? { kind: 'exhausted', max } : { kind: 'ready', round: used + 1, max };
}

const known = <T extends string>(list: readonly T[], value: string): value is T => (list as readonly string[]).includes(value);
export const stepNameKey = (step: string): MessageKey => (known(PIPELINE_STEPS, step) ? `pipeline.step.${step}` : 'pipeline.step.unknown');
export const stepStateKey = (state: string): MessageKey => (known(STEP_STATES, state) ? `pipeline.state.${state}` : 'pipeline.state.unknown');
export const planStateKey = (state: string): MessageKey => (known(PLAN_STATES, state) ? `pipeline.planState.${state}` : 'pipeline.state.unknown');

export const effortKey = (effort: string | null | undefined): MessageKey => (!effort ? 'pipeline.effort.default' : known(EFFORTS, effort) ? `pipeline.effort.${effort}` : 'pipeline.effort.unknown');

/** Who did it; runs of the runner may come without a name. */
export const eventActor = (e: PipelineEvent): string => e.actorLabel || t(e.actorType === 'run' ? 'pipeline.runner' : 'cc.update.anonymous');

export function eventText(e: PipelineEvent): string {
	const version = e.planVersion ?? '?';
	switch (e.action) {
		case 'plan_written':
			return t('pipeline.event.planWritten', { version });
		case 'plan_approved':
			return t('pipeline.event.planApproved', { version });
		case 'plan_changes_requested':
			return t('pipeline.event.planChanges', { version });
		case 'step_changed':
			return t('pipeline.event.step', { step: t(stepNameKey(e.step ?? '')), state: t(stepStateKey(e.state ?? '')) });
		case 'step_retried':
			return t('pipeline.event.stepRetried', { step: t(stepNameKey(e.step ?? '')), version });
		case 'execution_started':
			return t('pipeline.event.executionStarted');
		case 'execution_continued':
			return t('pipeline.event.executionContinued');
		case 'execution_stopped':
			return t('pipeline.event.executionStopped');
		case 'execution_completed':
			return t('pipeline.event.executionCompleted');
		default:
			return t('pipeline.event.other');
	}
}

export type DecisionProblem = 'comment_required' | 'invalid_comment';
export function decisionProblem(decision: PlanDecision, comment: string): DecisionProblem | null {
	const text = comment.trim();
	if (decision === 'request_changes' && !text) return 'comment_required';
	return text.length > PLAN_COMMENT_MAX ? 'invalid_comment' : null;
}

/** Structural check instead of `instanceof ApiError`: api.ts imports the types of this module. */
const httpError = (e: unknown): { status?: number; reason?: string } => (e && typeof e === 'object' ? (e as { status?: number; reason?: string }) : {});

export function decisionErrorKey(e: unknown): MessageKey {
	const { status, reason } = httpError(e);
	if (reason === 'plan_changed') return 'pipeline.error.planChanged';
	if (reason === 'plan_not_pending') return 'pipeline.error.notPending';
	if (reason === 'no_plan') return 'pipeline.error.noPlan';
	if (reason === 'comment_required') return 'pipeline.error.commentRequired';
	if (reason === 'invalid_comment') return 'pipeline.error.invalidComment';
	if (status === 401) return 'error.unauthorized';
	if (status === 403) return 'pipeline.error.forbidden';
	if (status === 0) return 'pipeline.error.network';
	return 'pipeline.error.generic';
}
/** Refusals that mean the shown plan is outdated: read it again (never decide again automatically). */
const OUTDATED = ['plan_changed', 'plan_not_pending', 'no_plan'];

/** The new refusals of stage 2 (docs/PLAN-PIPELINE-STUFE-2.md section 6) as a German message; null for every other reason. */
const STAGE2_REASONS: Record<string, MessageKey> = {
	step_disabled: 'pipeline.error.stepDisabled',
	step_not_failed: 'pipeline.error.stepNotFailed',
	fix_rounds_exhausted: 'pipeline.error.fixRoundsExhausted',
	plan_changed: 'pipeline.error.planChangedGeneric',
	revision_conflict: 'pipeline.settings.error.conflict',
	invalid_model: 'pipeline.settings.error.invalidModel',
	invalid_effort: 'pipeline.settings.error.invalidEffort',
	invalid_pipeline_settings: 'pipeline.settings.error.invalidSettings'
};
export function pipelineReasonKey(reason: string | null | undefined): MessageKey | null {
	return reason && Object.hasOwn(STAGE2_REASONS, reason) ? STAGE2_REASONS[reason]! : null;
}
/** Message for a refused retry. */
export function retryErrorKey(e: unknown): MessageKey {
	const { status, reason } = httpError(e);
	const key = pipelineReasonKey(reason);
	if (key) return key;
	if (reason === 'plan_not_approved') return 'pipeline.error.planNotApproved';
	if (status === 401) return 'error.unauthorized';
	if (status === 403) return 'pipeline.error.forbidden';
	if (status === 0) return 'pipeline.error.networkRetry';
	return 'pipeline.error.generic';
}
/** Refusals that mean the shown state is outdated: read the card again (never retry automatically). */
const RETRY_OUTDATED = ['plan_changed', 'step_not_failed', 'step_disabled', 'fix_rounds_exhausted', 'plan_not_approved'];

export interface RetryInput {
	/** The plan version the person saw; the server refuses (`plan_changed`) when it is not the current one. */
	planVersion?: number;
	note?: string;
}
export interface PipelineApi {
	taskPipeline: (taskID: string) => Promise<TaskPipeline>;
	decidePlan: (taskID: string, input: PlanDecisionInput) => Promise<TaskPipeline>;
	retryPipelineStep: (taskID: string, step: PipelineStepName, input: RetryInput) => Promise<TaskPipeline>;
}
export interface PipelineFeedback {
	tone: 'success' | 'info' | 'error';
	key: MessageKey;
	params?: Record<string, string | number>;
	/** A message of the section "Ausführung": shown there, and gone when the execution moves on. */
	scope?: 'execution';
}
export interface PipelineView {
	taskID: string | null;
	/** Null: nothing loaded yet, or the server has no pipeline endpoint. */
	data: TaskPipeline | null;
	status: 'loading' | 'ready' | 'failed';
	/** The typed comment: survives refreshes, tab changes and refused decisions. */
	comment: string;
	/** What is missing before the decision can be sent. */
	problem: DecisionProblem | null;
	busy: PlanDecision | null;
	feedback: PipelineFeedback | null;
	/** The shown plan replaced the version the person had before them: deciding needs a confirmation. */
	unread: boolean;
	/** The decision that was tried on an unread version and is now offered for confirmation. */
	confirm: PlanDecision | null;
	/** The step whose retry is being sent. */
	retrying: PipelineStepName | null;
	/** Own bindings of the card's project; empty for people who may not start. */
	bindings: ProjectBinding[];
	/** The binding chosen for the next start. */
	bindingID: string;
	/** The execution action that is being sent. */
	acting: ExecutionAction | null;
	/** The action that was tried on an unread plan version: the next one confirms it. */
	confirmExecution: 'start' | 'continue' | null;
}
export const emptyPipelineView = (): PipelineView => ({
	taskID: null,
	data: null,
	status: 'loading',
	comment: '',
	problem: null,
	busy: null,
	feedback: null,
	unread: false,
	confirm: null,
	retrying: null,
	bindings: [],
	bindingID: '',
	acting: null,
	confirmExecution: null
});
export type DecideOutcome = 'done' | 'unread' | 'invalid' | 'failed' | 'ignored';
export type RetryOutcome = 'done' | 'failed' | 'ignored';
export type ActOutcome = 'done' | 'unread' | 'failed' | 'ignored';
const EXECUTION_DONE: Record<ExecutionAction, MessageKey> = { start: 'pipeline.exec.feedback.started', continue: 'pipeline.exec.feedback.continued', stop: 'pipeline.exec.feedback.stopped' };
/** Refusals that mean the shown execution or plan is outdated (never send again automatically). */
const EXECUTION_OUTDATED = ['execution_active', 'nothing_to_run', 'no_execution', 'plan_changed'];

/** Drives `view` (a `$state` object in the component, a plain object in tests). */
export function createPipelineController(view: PipelineView, api: PipelineApi & Partial<ExecutionApi>) {
	/** Only the answer of the latest read (or decision) is applied. */
	let seq = 0;
	/** Changes with every card, so late answers of a card that was left are dropped. */
	let card = 0;
	/** A start whose answer got lost: sending it again with the same id never starts twice. */
	let unanswered: { taskID: string; bindingID: string; id: string } | null = null;
	/** Only the latest read of the bindings is applied. */
	let bindingsRead = 0;
	let projectOfBindings: string | null = null;

	function apply(next: TaskPipeline | null): void {
		if (JSON.stringify(next) !== JSON.stringify(view.data)) view.data = next;
	}

	/** `announce`: tell the person when the plan changed underneath them. */
	async function read(announce: boolean): Promise<void> {
		const taskID = view.taskID;
		if (!taskID) return;
		const my = ++seq;
		let next: TaskPipeline | null;
		try {
			next = await api.taskPipeline(taskID);
		} catch (e) {
			if (my !== seq) return;
			if (httpError(e).status !== 404) {
				// A failed refresh keeps what is shown; only a failed first load is reported.
				if (view.status !== 'ready') view.status = 'failed';
				return;
			}
			next = null;
		}
		if (my !== seq) return;
		const before = view.data?.plan;
		const after = next?.plan;
		const replaced = !!before && !!after && before.version !== after.version;
		if (replaced) view.unread = true;
		// A confirmation belongs to exactly the version it was offered for.
		if (replaced || after?.state !== 'proposed') view.confirm = null;
		if (replaced) view.confirmExecution = null;
		// A message about the execution belongs to the state it was said about.
		if (announce && view.acting === null && view.feedback?.scope === 'execution' && view.feedback.tone === 'success' && view.data?.execution?.state !== next?.execution?.state) view.feedback = null;
		// A running decision and the "plan changed" refusal already explain what happens: nothing replaces their message.
		const explained = view.busy !== null || (view.feedback?.key === 'pipeline.error.planChanged' && after?.state === 'proposed');
		if (announce && !explained && before && after && (before.version !== after.version || before.state !== after.state)) {
			view.problem = null;
			view.feedback = before.version !== after.version ? { tone: 'info', key: 'pipeline.feedback.newVersion', params: { version: after.version } } : null;
		}
		apply(next);
		view.status = 'ready';
	}

	/** `confirmed`: the person used the confirmation for the shown version. */
	async function send(decision: PlanDecision, canEdit: boolean, confirmed: boolean): Promise<DecideOutcome> {
		const taskID = view.taskID;
		const plan = view.data?.plan;
		if (!taskID || !plan || view.busy || !canDecide(view.data, canEdit)) return 'ignored';
		// A click aimed at the old version never decides the new one, however often it is repeated.
		if (view.unread && !confirmed) {
			view.problem = null;
			view.confirm = decision;
			view.feedback = { tone: 'info', key: 'pipeline.feedback.readFirst', params: { version: plan.version } };
			return 'unread';
		}
		view.problem = decisionProblem(decision, view.comment);
		if (view.problem) return 'invalid';
		const my = card;
		view.busy = decision;
		view.feedback = null;
		try {
			const sent = view.comment;
			const next = await api.decidePlan(taskID, { decision, version: plan.version, comment: sent.trim() || undefined });
			if (my !== card) return 'ignored';
			seq++; // reads started before this answer carry the old state
			apply(next);
			view.unread = false;
			view.confirm = null;
			if (view.comment === sent) view.comment = '';
			view.feedback = { tone: 'success', key: decision === 'approve' ? 'pipeline.feedback.approved' : 'pipeline.feedback.changesRequested' };
			return 'done';
		} catch (e) {
			if (my !== card) return 'ignored';
			if (OUTDATED.includes(httpError(e).reason ?? '')) await read(false);
			if (my !== card) return 'ignored';
			view.feedback = { tone: 'error', key: decisionErrorKey(e) };
			return 'failed';
		} finally {
			if (my === card) view.busy = null;
		}
	}

	/** Retries a failed step; the server counts the round and refuses what is outdated, the card is then read again. */
	async function retryStep(step: PipelineStepName, canEdit: boolean): Promise<RetryOutcome> {
		const taskID = view.taskID;
		if (!taskID || view.retrying || view.busy || retryOffer(view.data, step, canEdit).kind !== 'ready') return 'ignored';
		const my = card;
		view.retrying = step;
		view.feedback = null;
		try {
			const version = view.data?.plan?.version;
			const next = await api.retryPipelineStep(taskID, step, version === undefined ? {} : { planVersion: version });
			if (my !== card) return 'ignored';
			seq++; // reads started before this answer carry the old state
			if (next && Array.isArray(next.steps)) apply(next);
			else await read(false);
			if (my !== card) return 'ignored';
			const execution = view.data?.execution;
			const key: MessageKey = !isActiveExecution(execution) ? 'pipeline.feedback.retried' : execution!.state === 'paused' ? 'pipeline.exec.feedback.retriedPaused' : 'pipeline.exec.feedback.retriedRunning';
			view.feedback = { tone: 'success', key, params: { step: t(stepNameKey(step)) } };
			return 'done';
		} catch (e) {
			if (my !== card) return 'ignored';
			if (RETRY_OUTDATED.includes(httpError(e).reason ?? '')) await read(false);
			if (my !== card) return 'ignored';
			view.feedback = { tone: 'error', key: retryErrorKey(e) };
			return 'failed';
		} finally {
			if (my === card) view.retrying = null;
		}
	}

	async function loadBindings(projectID: string | null, mayStart: boolean): Promise<void> {
		projectOfBindings = mayStart ? projectID : null;
		const my = ++bindingsRead;
		const shown = card;
		let bindings: ProjectBinding[] = [];
		if (projectID && mayStart && api.listDevices) {
			try {
				// Own devices that are paired and not revoked; a refusal means there is nothing to start with.
				bindings = bindingsForProject((await api.listDevices()).filter((d) => d.paired), projectID);
			} catch {
				bindings = [];
			}
		}
		if (my !== bindingsRead || shown !== card) return;
		view.bindings = bindings;
		if (!bindings.some((b) => b.id === view.bindingID)) view.bindingID = bindings[0]?.id ?? '';
	}

	/** Start, continue and stop: one at a time, the card is read again when the server says the shown state is outdated. */
	async function act(action: ExecutionAction, send: (taskID: string) => Promise<TaskPipeline>): Promise<ActOutcome> {
		const taskID = view.taskID!;
		const my = card;
		view.acting = action;
		view.feedback = null;
		try {
			const next = await send(taskID);
			if (my !== card) return 'ignored';
			seq++; // reads started before this answer carry the old state
			apply(next);
			view.confirmExecution = null;
			if (action !== 'stop') view.unread = false;
			view.feedback = { tone: 'success', key: EXECUTION_DONE[action], scope: 'execution' };
			return 'done';
		} catch (e) {
			if (my !== card) return 'ignored';
			const { status, reason } = httpError(e);
			if (EXECUTION_OUTDATED.includes(reason ?? '')) await read(false);
			if (status === 404) await Promise.all([read(false), loadBindings(projectOfBindings, projectOfBindings !== null)]);
			if (my !== card) return 'ignored';
			view.feedback = { tone: 'error', key: executionErrorKey(e), scope: 'execution' };
			return 'failed';
		} finally {
			if (my === card) view.acting = null;
		}
	}

	/** Starting and continuing accept the plan: never a version that replaced the one the person had before them without a second click. */
	function readFirst(action: 'start' | 'continue'): boolean {
		const plan = view.data?.plan;
		if (!view.unread || !plan || view.confirmExecution === action) return false;
		view.confirmExecution = action;
		view.feedback = { tone: 'info', key: 'pipeline.exec.feedback.readFirst', params: { version: plan.version }, scope: 'execution' };
		return true;
	}

	async function startExecution(mayStart: boolean): Promise<ActOutcome> {
		const taskID = view.taskID;
		const bindingID = view.bindingID;
		if (!taskID || view.acting || !api.startPipelineExecution || !bindingID || !executionSection(view.data, view.bindings, mayStart).start) return 'ignored';
		if (readFirst('start')) return 'unread';
		const request = unanswered && unanswered.taskID === taskID && unanswered.bindingID === bindingID ? unanswered : { taskID, bindingID, id: crypto.randomUUID() };
		unanswered = request;
		return act('start', async () => {
			try {
				const next = await api.startPipelineExecution!(taskID, { id: request.id, bindingID });
				unanswered = null;
				return next;
			} catch (e) {
				// Only without an answer the start may have happened; a refusal ends this request.
				const status = httpError(e).status ?? 0;
				if (status !== 0 && status < 500) unanswered = null;
				throw e;
			}
		});
	}

	async function continueExecution(mayStart: boolean): Promise<ActOutcome> {
		if (!mayStart || !view.taskID || view.acting || !api.continuePipelineExecution || view.data?.execution?.state !== 'paused') return 'ignored';
		if (readFirst('continue')) return 'unread';
		const version = view.data.plan?.version;
		return act('continue', (taskID) => api.continuePipelineExecution!(taskID, version === undefined ? {} : { planVersion: version }));
	}

	async function stopExecution(mayStart: boolean): Promise<ActOutcome> {
		if (!mayStart || !view.taskID || view.acting || !api.stopPipelineExecution || !isActiveExecution(view.data?.execution)) return 'ignored';
		return act('stop', (taskID) => api.stopPipelineExecution!(taskID));
	}

	return {
		loadBindings,
		choose(bindingID: string): void {
			view.bindingID = bindingID;
		},
		startExecution,
		continueExecution,
		stopExecution,
		/** Shows another card: forgets draft and messages, then loads. */
		open(taskID: string): Promise<void> {
			card++;
			Object.assign(view, emptyPipelineView(), { taskID });
			return read(false);
		},
		refresh: (): Promise<void> => read(true),
		retry(): Promise<void> {
			view.status = 'loading';
			return read(false);
		},
		/** The person types: keeps the draft; the "what is missing" hint has done its job. */
		type(text: string): void {
			view.comment = text;
			view.problem = null;
		},
		decide: (decision: PlanDecision, canEdit: boolean): Promise<DecideOutcome> => send(decision, canEdit, false),
		retryStep,
		/** The person has read the new version and confirms the offered decision. */
		confirm: async (canEdit: boolean): Promise<DecideOutcome> => (view.confirm ? send(view.confirm, canEdit, true) : 'ignored')
	};
}
export type PipelineController = ReturnType<typeof createPipelineController>;
