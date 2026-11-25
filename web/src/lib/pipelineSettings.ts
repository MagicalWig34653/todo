/**
 * Project settings "Pipeline" (card B926E7D8, docs/PLAN-PIPELINE-STUFE-2.md section 1): types, the form draft, what is sent and the
 * controller of the settings dialog. Rights and validation stay in the backend; the checks here only save a round trip.
 */
import type { MessageKey } from './i18n/index.js';
import { t } from './i18n/index.js';
import { EFFORTS, PIPELINE_ROLES, PIPELINE_STEPS, effortKey, pipelineReasonKey, stepNameKey, type PipelineRole, type PipelineStepName, type RoleSetting } from './pipeline.js';

export const MAX_FIX_ROUNDS_LIMIT = 10;
export const DEFAULT_MAX_FIX_ROUNDS = 3;
export const MODEL_MAX = 100;
/** The pattern of the contract; the runner decides which names exist (stage 3). */
export const MODEL_PATTERN = /^[A-Za-z0-9._:/-]+$/;
/** Suggestions for the text field, not a list of what is allowed. */
export const MODEL_SUGGESTIONS = ['sonnet', 'opus', 'haiku', 'gpt-6.1-sol'] as const;

export interface PipelineSettingsEvent {
	id: string;
	actorType?: string | null;
	actorLabel?: string | null;
	summary: string;
	createdAt?: string | null;
}
export interface PipelineSettings {
	projectID: string;
	/** 0 while the project has no row; every save needs the revision that was read. */
	revision: number;
	steps: Record<PipelineStepName, boolean>;
	roles: Record<PipelineRole, RoleSetting>;
	maxFixRounds: number;
	notifyOnWaitingApproval: boolean;
	updatedAt?: string | null;
	updatedByLabel?: string | null;
	/** Newest first. */
	history: PipelineSettingsEvent[];
}
/** Body of the PATCH without the revision: only what changed. `null` clears a model or an effort. */
export interface SettingsPatch {
	steps?: Partial<Record<PipelineStepName, boolean>>;
	roles?: Partial<Record<PipelineRole, { model?: string | null; effort?: string | null }>>;
	maxFixRounds?: number;
	notifyOnWaitingApproval?: boolean;
}

/** Fills what the server omitted (missing equals the default) and drops keys this client does not know. */
export function normalizeSettings(raw: Partial<PipelineSettings> & { projectID: string }): PipelineSettings {
	const steps = {} as Record<PipelineStepName, boolean>;
	for (const step of PIPELINE_STEPS) steps[step] = raw.steps?.[step] !== false;
	const roles = {} as Record<PipelineRole, RoleSetting>;
	for (const role of PIPELINE_ROLES) {
		const r = raw.roles?.[role];
		roles[role] = { ...(r?.model ? { model: r.model } : {}), ...(r?.effort ? { effort: r.effort } : {}) };
	}
	return {
		projectID: raw.projectID,
		revision: raw.revision ?? 0,
		steps,
		roles,
		maxFixRounds: raw.maxFixRounds ?? DEFAULT_MAX_FIX_ROUNDS,
		notifyOnWaitingApproval: raw.notifyOnWaitingApproval !== false,
		updatedAt: raw.updatedAt ?? null,
		updatedByLabel: raw.updatedByLabel ?? null,
		history: raw.history ?? []
	};
}

// ---- the form ---------------------------------------------------------------------------------------------------------
export interface RoleDraft {
	model: string;
	/** '' = the default. */
	effort: string;
}
export interface SettingsDraft {
	steps: Record<PipelineStepName, boolean>;
	roles: Record<PipelineRole, RoleDraft>;
	/** Text of the number field. */
	maxFixRounds: string;
	notify: boolean;
}
export function draftOf(s: PipelineSettings): SettingsDraft {
	const roles = {} as Record<PipelineRole, RoleDraft>;
	for (const role of PIPELINE_ROLES) roles[role] = { model: s.roles[role]?.model ?? '', effort: s.roles[role]?.effort ?? '' };
	return { steps: { ...s.steps }, roles, maxFixRounds: String(s.maxFixRounds), notify: s.notifyOnWaitingApproval };
}

export interface SettingsProblem {
	field: 'model' | 'effort' | 'maxFixRounds';
	role?: PipelineRole;
	code: 'invalid_model' | 'invalid_effort' | 'invalid_max_fix_rounds';
}
const WHOLE_NUMBER = /^\d+$/;
export function draftProblems(d: SettingsDraft): SettingsProblem[] {
	const out: SettingsProblem[] = [];
	for (const role of PIPELINE_ROLES) {
		const model = d.roles[role].model.trim();
		if (model && (model.length > MODEL_MAX || !MODEL_PATTERN.test(model))) out.push({ field: 'model', role, code: 'invalid_model' });
		const effort = d.roles[role].effort;
		if (effort && !(EFFORTS as readonly string[]).includes(effort)) out.push({ field: 'effort', role, code: 'invalid_effort' });
	}
	const rounds = d.maxFixRounds.trim();
	if (!WHOLE_NUMBER.test(rounds) || Number(rounds) > MAX_FIX_ROUNDS_LIMIT) out.push({ field: 'maxFixRounds', code: 'invalid_max_fix_rounds' });
	return out;
}

/** Only what differs from the settings that were read; null when nothing changed. Expects a valid draft. */
export function settingsPatch(base: PipelineSettings, d: SettingsDraft): SettingsPatch | null {
	const patch: SettingsPatch = {};
	const steps: Partial<Record<PipelineStepName, boolean>> = {};
	for (const step of PIPELINE_STEPS) if (d.steps[step] !== base.steps[step]) steps[step] = d.steps[step];
	if (Object.keys(steps).length > 0) patch.steps = steps;
	const roles: NonNullable<SettingsPatch['roles']> = {};
	for (const role of PIPELINE_ROLES) {
		const change: { model?: string | null; effort?: string | null } = {};
		const model = d.roles[role].model.trim();
		if (model !== (base.roles[role]?.model ?? '')) change.model = model || null;
		const effort = d.roles[role].effort;
		if (effort !== (base.roles[role]?.effort ?? '')) change.effort = effort || null;
		if (Object.keys(change).length > 0) roles[role] = change;
	}
	if (Object.keys(roles).length > 0) patch.roles = roles;
	const rounds = Number(d.maxFixRounds.trim());
	if (rounds !== base.maxFixRounds) patch.maxFixRounds = rounds;
	if (d.notify !== base.notifyOnWaitingApproval) patch.notifyOnWaitingApproval = d.notify;
	return Object.keys(patch).length > 0 ? patch : null;
}
/** The draft differs from the saved values (an invalid number counts as different). */
export function settingsDirty(base: PipelineSettings, d: SettingsDraft): boolean {
	if (draftProblems(d).some((p) => p.field === 'maxFixRounds') && d.maxFixRounds.trim() !== String(base.maxFixRounds)) return true;
	return settingsPatch(base, d) !== null;
}

// ---- history text -----------------------------------------------------------------------------------------------------
const isRole = (v: string): v is PipelineRole => (PIPELINE_ROLES as readonly string[]).includes(v);
const isStep = (v: string): v is PipelineStepName => (PIPELINE_STEPS as readonly string[]).includes(v);
const CLEARED = new Set(['null', '-', 'none', 'standard']);

/** One piece of the server's summary ("steps.tester aus") in German, or null when it is not understood. */
function summaryPart(part: string): string | null {
	const [key, ...rest] = part.trim().split(/\s+/);
	const value = rest.join(' ');
	if (!key || !value) return null;
	const [group, name, field] = key.split('.');
	if (group === 'steps' && name && isStep(name) && !field) {
		if (value === 'aus') return t('pipeline.settings.history.stepOff', { step: t(stepNameKey(name)) });
		if (value === 'an') return t('pipeline.settings.history.stepOn', { step: t(stepNameKey(name)) });
	}
	if (group === 'roles' && name && isRole(name) && (field === 'model' || field === 'effort')) {
		const role = t(`pipeline.role.${name}` as MessageKey);
		if (CLEARED.has(value)) return t(field === 'model' ? 'pipeline.settings.history.modelCleared' : 'pipeline.settings.history.effortCleared', { role });
		if (field === 'model') return t('pipeline.settings.history.model', { role, value });
		return t('pipeline.settings.history.effort', { role, value: t(effortKey(value)) });
	}
	if (key === 'maxFixRounds' && WHOLE_NUMBER.test(value)) return t('pipeline.settings.history.rounds', { count: value });
	if (key === 'notifyOnWaitingApproval' && (value === 'an' || value === 'aus')) return t(value === 'an' ? 'pipeline.settings.history.notifyOn' : 'pipeline.settings.history.notifyOff');
	return null;
}
/** The history line in German; a text that is not understood stays as it is, so nothing is lost. */
export function settingsSummary(summary: string): string {
	const parts = summary.split(';');
	const out = parts.map(summaryPart);
	return out.every((p) => p !== null) && summary !== '' ? (out as string[]).join('; ') : summary;
}

// ---- errors -----------------------------------------------------------------------------------------------------------
const httpError = (e: unknown): { status?: number; reason?: string } => (e && typeof e === 'object' ? (e as { status?: number; reason?: string }) : {});
export function settingsErrorKey(e: unknown): MessageKey {
	const { status, reason } = httpError(e);
	const key = pipelineReasonKey(reason);
	if (key && reason !== 'plan_changed') return key;
	if (status === 401) return 'error.unauthorized';
	if (status === 403) return 'pipeline.settings.error.forbidden';
	if (status === 0) return 'pipeline.settings.error.network';
	return 'pipeline.settings.error.generic';
}

// ---- controller -------------------------------------------------------------------------------------------------------
export interface SettingsApi {
	pipelineSettings: (projectID: string) => Promise<PipelineSettings>;
	updatePipelineSettings: (projectID: string, body: SettingsPatch & { revision: number }) => Promise<PipelineSettings>;
}
export interface SettingsFeedback {
	tone: 'success' | 'info' | 'error';
	key: MessageKey;
}
export interface SettingsView {
	projectID: string | null;
	data: PipelineSettings | null;
	draft: SettingsDraft | null;
	/** `unsupported`: the server has no endpoint (404). */
	status: 'loading' | 'ready' | 'failed' | 'unsupported';
	problems: SettingsProblem[];
	busy: boolean;
	feedback: SettingsFeedback | null;
}
export const emptySettingsView = (): SettingsView => ({ projectID: null, data: null, draft: null, status: 'loading', problems: [], busy: false, feedback: null });
export type SaveOutcome = 'saved' | 'unchanged' | 'invalid' | 'conflict' | 'failed' | 'ignored';

/** Drives `view` (a `$state` object in the component, a plain object in tests). */
export function createSettingsController(view: SettingsView, api: SettingsApi) {
	/** Changes with every project, so late answers of a project that was left are dropped. */
	let project = 0;

	function adopt(settings: PipelineSettings): void {
		view.data = normalizeSettings(settings);
		view.draft = draftOf(view.data);
		view.problems = [];
	}
	async function load(): Promise<void> {
		const id = view.projectID;
		if (!id) return;
		const my = project;
		try {
			const settings = await api.pipelineSettings(id);
			if (my !== project) return;
			adopt(settings);
			view.status = 'ready';
		} catch (e) {
			if (my !== project) return;
			view.status = httpError(e).status === 404 ? 'unsupported' : 'failed';
		}
	}

	async function save(canManage: boolean): Promise<SaveOutcome> {
		const id = view.projectID;
		if (!id || !view.data || !view.draft || view.busy || !canManage) return 'ignored';
		view.problems = draftProblems(view.draft);
		if (view.problems.length > 0) {
			view.feedback = null;
			return 'invalid';
		}
		const patch = settingsPatch(view.data, view.draft);
		if (!patch) {
			view.feedback = { tone: 'info', key: 'pipeline.settings.unchanged' };
			return 'unchanged';
		}
		const my = project;
		view.busy = true;
		view.feedback = null;
		try {
			const saved = await api.updatePipelineSettings(id, { revision: view.data.revision, ...patch });
			if (my !== project) return 'ignored';
			adopt({ ...saved, projectID: saved.projectID ?? id });
			view.feedback = { tone: 'success', key: 'pipeline.settings.saved' };
			return 'saved';
		} catch (e) {
			if (my !== project) return 'ignored';
			const { reason } = httpError(e);
			if (reason === 'revision_conflict') {
				// Somebody else saved first: show what is saved now; the person decides again.
				await load();
				if (my !== project) return 'ignored';
				view.feedback = { tone: 'error', key: 'pipeline.settings.error.conflict' };
				return 'conflict';
			}
			view.feedback = { tone: 'error', key: settingsErrorKey(e) };
			return 'failed';
		} finally {
			if (my === project) view.busy = false;
		}
	}

	return {
		/** Shows another project: forgets draft and messages, then loads. */
		open(projectID: string): Promise<void> {
			project++;
			Object.assign(view, emptySettingsView(), { projectID });
			return load();
		},
		reload(): Promise<void> {
			view.status = 'loading';
			return load();
		},
		save,
		/** Back to the saved values. */
		discard(): void {
			if (view.data) adopt(view.data);
			view.feedback = null;
		}
	};
}
export type SettingsController = ReturnType<typeof createSettingsController>;
