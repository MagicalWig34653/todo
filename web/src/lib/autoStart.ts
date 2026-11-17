/**
 * Pure rules for the guard's automatic start (ADR 0033 stage C, contracts/planning-ext.yaml 1.2.0 and agents.yaml 1.2.0):
 * when the per-card switch may be used, error texts, calendar marks, revocation detection and the job event note.
 * The backend decides; this only hides, explains and formats.
 */
import { ApiError, type PlanningTask, type ScheduleEntry } from './api.js';
import { t, type MessageKey } from './i18n/index.js';
import { formatWhen } from './planning.js';

export interface BlockInput {
	status: string;
	plannedAt: string | null | undefined;
	plannedAllDay: boolean | undefined;
	isOwner: boolean;
	/** Usable bindings of the card's project on the person's own devices. */
	bindings: number;
}
/** Why the switch cannot be turned on (key), or null when it can. */
export function autoStartBlock(i: BlockInput): MessageKey | null {
	if (!i.isOwner) return 'autostart.block.owner';
	if (i.status === 'done') return 'autostart.block.done';
	if (!i.plannedAt) return 'autostart.block.start';
	if (i.plannedAllDay) return 'autostart.block.allDay';
	if (i.bindings < 1) return 'autostart.block.binding';
	return null;
}

/** The server needs a `deviceID` when the project is bound on more than one device. */
export const autoStartNeedsDevice = (bindings: { deviceID: string }[]): boolean => new Set(bindings.map((b) => b.deviceID)).size > 1;

const ERROR_KEYS: Record<string, MessageKey> = {
	version_conflict: 'autostart.error.version_conflict',
	task_done: 'autostart.error.task_done',
	planned_start_required: 'autostart.error.planned_start_required',
	all_day_not_allowed: 'autostart.error.all_day_not_allowed',
	no_binding: 'autostart.error.no_binding',
	device_required: 'autostart.error.device_required'
};
export function autoStartErrorKey(e: unknown): MessageKey {
	if (e instanceof ApiError) {
		if (e.status === 409 && e.reason && e.reason in ERROR_KEYS) return ERROR_KEYS[e.reason];
		if (e.status === 403) return 'autostart.error.forbidden';
	}
	return 'autostart.error.generic';
}

export type AutoStartResult = { ok: true; task: PlanningTask } | { ok: false; key: MessageKey; error: unknown };
/** Sends the switch with the card's version; the answer is the updated planning (new version included). */
export async function saveAutoStart(
	send: (taskID: string, body: { version: number; enabled: boolean; deviceID?: string }) => Promise<PlanningTask>,
	card: { taskID: string; version: number },
	enabled: boolean,
	deviceID?: string
): Promise<AutoStartResult> {
	try {
		const body: { version: number; enabled: boolean; deviceID?: string } = { version: card.version, enabled };
		if (enabled && deviceID) body.deviceID = deviceID;
		return { ok: true, task: await send(card.taskID, body) };
	} catch (error) {
		return { ok: false, key: autoStartErrorKey(error), error };
	}
}

export interface AutoStartMarks {
	/** Permission is set and the guard has not started the card yet. */
	badge: boolean;
	/** Permission set and the planned start is already past: waits for free lights. */
	overdue: boolean;
	startedAt: Date | null;
}
export function autoStartMarks(e: Pick<ScheduleEntry, 'autoStart' | 'autoStartedAt' | 'plannedAt'>, now: Date): AutoStartMarks {
	const startedAt = e.autoStartedAt ? new Date(e.autoStartedAt) : null;
	const overdue = !!e.autoStart && !!e.plannedAt && new Date(e.plannedAt).getTime() < now.getTime();
	return { badge: !!e.autoStart, overdue, startedAt: startedAt && !Number.isNaN(startedAt.getTime()) ? startedAt : null };
}

/** Titles of cards that had `autoStart` before and lost it without a hand-over (someone else changed the card). */
export function revokedTitles(prev: ScheduleEntry[], next: ScheduleEntry[]): string[] {
	const after = new Map(next.map((e) => [e.taskID, e]));
	return prev
		.filter((p) => {
			const n = after.get(p.taskID);
			return p.autoStart && n && !n.autoStart && !n.autoStartedAt;
		})
		.map((p) => p.title);
}

export interface JobEvent {
	id?: string;
	kind: string;
	detail: string;
	createdAt?: string | null;
}
export interface ReleasedInfo {
	origin: 'scheduler';
	catchup: boolean;
	delayMinutes: number;
	plannedAt: string;
}
/** The guard's release, read from the `released` event's JSON detail; null for manual releases or unreadable detail. */
export function releasedInfo(events: JobEvent[]): ReleasedInfo | null {
	const ev = events.find((e) => e.kind === 'released');
	if (!ev?.detail) return null;
	try {
		const d = JSON.parse(ev.detail) as Record<string, unknown>;
		if (d.origin !== 'scheduler' || typeof d.plannedAt !== 'string') return null;
		return {
			origin: 'scheduler',
			catchup: d.catchup === true,
			delayMinutes: typeof d.delayMinutes === 'number' && Number.isFinite(d.delayMinutes) ? Math.max(0, Math.round(d.delayMinutes)) : 0,
			plannedAt: d.plannedAt
		};
	} catch {
		return null;
	}
}
export function releasedNote(events: JobEvent[]): string | null {
	const r = releasedInfo(events);
	if (!r) return null;
	const planned = formatWhen(r.plannedAt);
	return r.catchup ? t('autostart.job.catchup', { planned, minutes: r.delayMinutes }) : t('autostart.job.released', { planned });
}
