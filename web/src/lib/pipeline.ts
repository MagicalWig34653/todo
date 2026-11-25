/** Plan approval and pipeline state of a card (card 74EC341D, contracts/pipeline.yaml): pure rules and the tab's controller. */
import type { MessageKey } from './i18n/index.js';
import { t } from './i18n/index.js';

export const PIPELINE_STEPS = ['planner', 'approval', 'developer', 'validation', 'tester', 'review'] as const;
export type PipelineStepName = (typeof PIPELINE_STEPS)[number];
const STEP_STATES = ['pending', 'running', 'waiting', 'changes_requested', 'done', 'failed', 'skipped'] as const;
export type PipelineStepState = (typeof STEP_STATES)[number];
const PLAN_STATES = ['proposed', 'approved', 'changes_requested'] as const;
export type PlanState = (typeof PLAN_STATES)[number];
export type PlanDecision = 'approve' | 'request_changes';
export const PLAN_COMMENT_MAX = 4000;

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
	decisionComment?: string | null;
}
export interface PipelineStep {
	step: PipelineStepName;
	state: PipelineStepState;
	note?: string | null;
	actorLabel?: string | null;
	updatedAt?: string | null;
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
export function isEmptyPipeline(p: TaskPipeline | null): boolean {
	return !p || (!p.plan && p.steps.every((s) => s.state === 'pending'));
}
export const awaitingApproval = (p: TaskPipeline | null): boolean => p?.plan?.state === 'proposed';
/** Only hides the controls; the server decides who may approve. */
export const canDecide = (p: TaskPipeline | null, canEdit: boolean): boolean => canEdit && awaitingApproval(p);

const known = <T extends string>(list: readonly T[], value: string): value is T => (list as readonly string[]).includes(value);
export const stepNameKey = (step: string): MessageKey => (known(PIPELINE_STEPS, step) ? `pipeline.step.${step}` : 'pipeline.step.unknown');
export const stepStateKey = (state: string): MessageKey => (known(STEP_STATES, state) ? `pipeline.state.${state}` : 'pipeline.state.unknown');
export const planStateKey = (state: string): MessageKey => (known(PLAN_STATES, state) ? `pipeline.planState.${state}` : 'pipeline.state.unknown');

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

export interface PipelineApi {
	taskPipeline: (taskID: string) => Promise<TaskPipeline>;
	decidePlan: (taskID: string, input: PlanDecisionInput) => Promise<TaskPipeline>;
}
export interface PipelineFeedback {
	tone: 'success' | 'info' | 'error';
	key: MessageKey;
	params?: Record<string, string | number>;
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
}
export const emptyPipelineView = (): PipelineView => ({ taskID: null, data: null, status: 'loading', comment: '', problem: null, busy: null, feedback: null });
export type DecideOutcome = 'done' | 'invalid' | 'failed' | 'ignored';

/** Drives `view` (a `$state` object in the component, a plain object in tests). */
export function createPipelineController(view: PipelineView, api: PipelineApi) {
	/** Only the answer of the latest read (or decision) is applied. */
	let seq = 0;
	/** Changes with every card, so late answers of a card that was left are dropped. */
	let card = 0;

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
		// A running decision and the "plan changed" refusal already explain what happens: nothing replaces their message.
		const explained = view.busy !== null || (view.feedback?.key === 'pipeline.error.planChanged' && after?.state === 'proposed');
		if (announce && !explained && before && after && (before.version !== after.version || before.state !== after.state)) {
			view.problem = null;
			view.feedback = before.version !== after.version ? { tone: 'info', key: 'pipeline.feedback.newVersion', params: { version: after.version } } : null;
		}
		apply(next);
		view.status = 'ready';
	}

	return {
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
		async decide(decision: PlanDecision, canEdit: boolean): Promise<DecideOutcome> {
			const taskID = view.taskID;
			const plan = view.data?.plan;
			if (!taskID || !plan || view.busy || !canDecide(view.data, canEdit)) return 'ignored';
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
	};
}
export type PipelineController = ReturnType<typeof createPipelineController>;
