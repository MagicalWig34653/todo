/**
 * Execution of the pipeline on a runner (card F5DD1C00, docs/PLAN-PIPELINE-STUFE-3.md sections 2, 3 and 6): pure rules of the
 * section "Ausführung" in the Pipeline tab. The controller that sends the requests is the one of lib/pipeline.ts.
 */
import type { JobState, RunnerDevice } from './api.js';
import type { ProjectBinding } from './agentsLogic.js';
import type { MessageKey } from './i18n/index.js';
import type { PipelineStepName, TaskPipeline } from './pipeline.js';

const EXECUTION_STATES = ['running', 'waiting_approval', 'blocked', 'paused', 'completed', 'stopped'] as const;
export type ExecutionState = (typeof EXECUTION_STATES)[number];
const PAUSE_REASONS = ['plan_needs_owner', 'task_changed', 'continue_required'] as const;
const JOB_STATES: readonly JobState[] = ['queued', 'claimed', 'running', 'waiting_for_answer', 'awaiting_review', 'succeeded', 'failed', 'cancelled'];
/** The steps a runner works on; planner and approval come before them. */
const WORK_STEPS: readonly PipelineStepName[] = ['developer', 'validation', 'tester', 'review'];
/** Start of the progress text the runner sends with a hold (`todo-runner budget`). */
const BUDGET_HOLD = 'Kontingent-Bremse';

// The server omits nil fields: every optional field may be missing or null.
export interface PipelineExecution {
	id: string;
	state: ExecutionState;
	/** Only with `paused` (why the owner is needed) and `blocked` (`step_failed`, `fix_rounds_exhausted`). */
	reason?: string | null;
	step?: PipelineStepName | null;
	bindingID: string;
	bindingLabel?: string | null;
	deviceLabel?: string | null;
	/** False: the device never asked for pipeline jobs (an old runner, or one that has not polled yet). */
	runnerSupportsPipeline?: boolean | null;
	jobID?: string | null;
	jobState?: JobState | null;
	jobProgress?: string | null;
	createdAt?: string | null;
	updatedAt?: string | null;
}
export interface StartInput {
	/** Chosen by the client: sending the same start again returns the same execution. */
	id: string;
	bindingID: string;
}
export interface ContinueInput {
	/** The plan version the person saw; the server refuses (`plan_changed`) when it is not the current one. */
	planVersion?: number;
}
export interface ExecutionApi {
	listDevices: () => Promise<RunnerDevice[]>;
	startPipelineExecution: (taskID: string, input: StartInput) => Promise<TaskPipeline>;
	continuePipelineExecution: (taskID: string, input: ContinueInput) => Promise<TaskPipeline>;
	stopPipelineExecution: (taskID: string) => Promise<TaskPipeline>;
}
export type ExecutionAction = 'start' | 'continue' | 'stop';

const known = <T extends string>(list: readonly T[], value: string | null | undefined): value is T => (list as readonly (string | null | undefined)[]).includes(value);

export const isActiveExecution = (e: PipelineExecution | null | undefined): boolean => !!e && e.state !== 'completed' && e.state !== 'stopped';
export const executionStateKey = (state: string): MessageKey => (known(EXECUTION_STATES, state) ? `pipeline.exec.state.${state}` : 'pipeline.state.unknown');
export const pauseReasonKey = (reason: string | null | undefined): MessageKey => (known(PAUSE_REASONS, reason) ? `pipeline.exec.pause.${reason}` : 'pipeline.exec.pause.other');
export const jobStateKey = (state: string): MessageKey => (known(JOB_STATES, state) ? `agents.job.${state}` : 'pipeline.state.unknown');
export const isBudgetHold = (e: PipelineExecution): boolean => e.jobState === 'queued' && !!e.jobProgress?.startsWith(BUDGET_HOLD);

export interface LiveStep {
	step: PipelineStepName;
	tone: 'running' | 'waiting' | 'warning';
	key: MessageKey;
	/** The progress the runner sent, shown as plain text; the long text of a hold is not repeated here. */
	progress: string | null;
}
/** The step a running execution is at, with what its job does right now. */
export function liveStep(p: TaskPipeline | null): LiveStep | null {
	const e = p?.execution;
	if (!e || e.state !== 'running' || !e.step) return null;
	const line = (tone: LiveStep['tone'], key: MessageKey): LiveStep => ({ step: e.step!, tone, key, progress: e.jobProgress || null });
	if (isBudgetHold(e)) return { ...line('warning', 'pipeline.exec.live.held'), progress: null };
	if (e.jobState === 'waiting_for_answer') return line('warning', 'pipeline.exec.live.answer');
	if (e.jobState === 'claimed') return line('running', 'pipeline.exec.live.claimed');
	if (e.jobState === 'running') return line('running', 'pipeline.exec.live.running');
	return line('waiting', 'pipeline.exec.live.queued');
}

/** Every work step that is on is finished: the server would refuse a start (`nothing_to_run`). */
export function nothingToRun(p: TaskPipeline | null): boolean {
	const on = p?.steps.filter((s) => WORK_STEPS.includes(s.step) && s.enabled !== false) ?? [];
	return on.length > 0 && on.every((s) => s.state === 'done' || s.state === 'skipped');
}

/**
 * Whether the section is there and offers a start. `mayStart` and the bindings only hide controls, the server checks the right.
 * Without an execution and without a binding the tab looks like before.
 */
export function executionSection(p: TaskPipeline | null, bindings: readonly ProjectBinding[], mayStart: boolean): { show: boolean; start: boolean } {
	if (!p) return { show: false, start: false };
	const own = mayStart && bindings.length > 0;
	return { show: !!p.execution || own, start: own && !isActiveExecution(p.execution) && !nothingToRun(p) };
}

/** Shown at a retry while an execution is active: the retry is not only a note on the board then. */
export function retryHintKey(p: TaskPipeline | null, mayStart: boolean): MessageKey | null {
	if (!isActiveExecution(p?.execution)) return null;
	return mayStart ? 'pipeline.exec.retryRuns' : 'pipeline.exec.retryNeedsOwner';
}

const REASONS: Record<string, MessageKey> = {
	execution_id_conflict: 'pipeline.exec.error.idConflict',
	execution_active: 'pipeline.exec.error.active',
	nothing_to_run: 'pipeline.exec.error.nothing',
	no_execution: 'pipeline.exec.error.none',
	plan_changed: 'pipeline.exec.error.planChanged'
};
/** Message for a refused start, continue or stop. */
export function executionErrorKey(e: unknown): MessageKey {
	const { status, reason } = e && typeof e === 'object' ? (e as { status?: number; reason?: string }) : ({} as { status?: number; reason?: string });
	if (reason && Object.hasOwn(REASONS, reason)) return REASONS[reason]!;
	if (status === 401) return 'error.unauthorized';
	if (status === 403) return 'pipeline.exec.error.forbidden';
	if (status === 404) return 'pipeline.exec.error.notFound';
	if (status === 0) return 'pipeline.exec.error.network';
	return 'pipeline.exec.error.generic';
}
