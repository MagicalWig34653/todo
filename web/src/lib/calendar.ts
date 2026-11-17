/**
 * Pure calendar rules (ADR 0033, contracts/planning-ext.yaml 1.1.0): Berlin wall clock, visible ranges, block layout,
 * drop and keyboard plans, conflict labels and the optimistic write with undo. No DOM, no stores.
 */
import { ApiError, type PlanningTask, type ScheduleConflict, type ScheduleEntry, type ScheduleUpdate } from './api.js';
import { t, type MessageKey } from './i18n/index.js';

export type { ScheduleEntry, ScheduleUpdate };
export type CalendarView = 'week' | 'month';
export interface CivilDay {
	y: number;
	m: number;
	d: number;
}
export type SchedulePatch = Omit<ScheduleUpdate, 'version'>;

export const TIME_ZONE = 'Europe/Berlin';
export const STEP_MINUTES = 15;
export const DEFAULT_MINUTES = 30;
export const MIN_MINUTES = 15;
export const MAX_MINUTES = 1440;
const MINUTE = 60_000;

const partsFormat = new Intl.DateTimeFormat('en-GB', {
	timeZone: TIME_ZONE, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', weekday: 'short'
});
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export interface BerlinParts extends CivilDay {
	h: number;
	min: number;
	/** 0 = Monday ... 6 = Sunday */
	weekday: number;
}

export function berlinParts(date: Date): BerlinParts {
	const v: Record<string, string> = {};
	for (const p of partsFormat.formatToParts(date)) v[p.type] = p.value;
	return { y: +v.year, m: +v.month, d: +v.day, h: +v.hour, min: +v.minute, weekday: WEEKDAYS.indexOf(v.weekday) };
}

/**
 * Berlin wall clock -> instant. A nonexistent local time (spring gap) moves to the next valid minute; an ambiguous one
 * (autumn) takes the first occurrence.
 */
export function berlinToDate(y: number, m: number, d: number, h = 0, min = 0): Date {
	const local = Date.UTC(y, m - 1, d, h, min);
	for (const offset of [2 * 3_600_000, 3_600_000]) {
		const t0 = new Date(local - offset);
		const p = berlinParts(t0);
		if (p.y === y && p.m === m && p.d === d && p.h === h && p.min === min) return t0;
	}
	for (let i = 0; i <= 180; i++) {
		const t0 = new Date(local - 2 * 3_600_000 + i * MINUTE);
		const p = berlinParts(t0);
		if (Date.UTC(p.y, p.m - 1, p.d, p.h, p.min) >= local) return t0;
	}
	return new Date(local);
}

export const civilKey = (c: CivilDay): string => `${c.y}-${String(c.m).padStart(2, '0')}-${String(c.d).padStart(2, '0')}`;
export const sameDay = (a: CivilDay, b: CivilDay): boolean => a.y === b.y && a.m === b.m && a.d === b.d;
export function addCivilDays(c: CivilDay, n: number): CivilDay {
	const u = new Date(Date.UTC(c.y, c.m - 1, c.d + n));
	return { y: u.getUTCFullYear(), m: u.getUTCMonth() + 1, d: u.getUTCDate() };
}
export const dayStart = (c: CivilDay): Date => berlinToDate(c.y, c.m, c.d, 0, 0);
export const civilOf = (date: Date): CivilDay => {
	const p = berlinParts(date);
	return { y: p.y, m: p.m, d: p.d };
};

export function weekDays(anchor: Date): CivilDay[] {
	const p = berlinParts(anchor);
	const monday = addCivilDays(p, -p.weekday);
	return Array.from({ length: 7 }, (_, i) => addCivilDays(monday, i));
}

/** Weeks (Monday first) that cover the anchor's month. */
export function monthGrid(anchor: Date): CivilDay[][] {
	const p = berlinParts(anchor);
	const first = { y: p.y, m: p.m, d: 1 };
	const next = { y: p.m === 12 ? p.y + 1 : p.y, m: p.m === 12 ? 1 : p.m + 1, d: 1 };
	const firstWeekday = berlinParts(dayStart(first)).weekday;
	const start = addCivilDays(first, -firstWeekday);
	const lastDay = addCivilDays(next, -1);
	const lastWeekday = berlinParts(dayStart(lastDay)).weekday;
	const end = addCivilDays(lastDay, 6 - lastWeekday);
	const weeks: CivilDay[][] = [];
	for (let c = start; !(c.y > end.y || (c.y === end.y && (c.m > end.m || (c.m === end.m && c.d > end.d)))); c = addCivilDays(c, 7)) {
		weeks.push(Array.from({ length: 7 }, (_, i) => addCivilDays(c, i)));
	}
	return weeks;
}

export interface VisibleRange {
	from: Date;
	to: Date;
	days: CivilDay[];
}
export function visibleRange(view: CalendarView, anchor: Date): VisibleRange {
	const days = view === 'week' ? weekDays(anchor) : monthGrid(anchor).flat();
	return { from: dayStart(days[0]), to: dayStart(addCivilDays(days[days.length - 1], 1)), days };
}

/** Next/previous window; keeps the Berlin wall clock (and clamps the day for months). */
export function shiftAnchor(view: CalendarView, anchor: Date, dir: 1 | -1): Date {
	const p = berlinParts(anchor);
	if (view === 'week') {
		const c = addCivilDays(p, 7 * dir);
		return berlinToDate(c.y, c.m, c.d, p.h, p.min);
	}
	const total = p.y * 12 + (p.m - 1) + dir;
	const y = Math.floor(total / 12);
	const m = (total % 12) + 1;
	const lastOfMonth = new Date(Date.UTC(y, m, 0)).getUTCDate();
	return berlinToDate(y, m, Math.min(p.d, lastOfMonth), p.h, p.min);
}

export const entryStart = (e: ScheduleEntry): Date | null => (e.plannedAt ? new Date(e.plannedAt) : null);
export const entryMinutes = (e: ScheduleEntry): number => e.plannedMinutes ?? DEFAULT_MINUTES;
export function entryEnd(e: ScheduleEntry): Date {
	const s = entryStart(e);
	return new Date((s?.getTime() ?? 0) + entryMinutes(e) * MINUTE);
}

export function dayEntries(all: ScheduleEntry[], day: CivilDay) {
	const from = dayStart(day).getTime();
	const to = dayStart(addCivilDays(day, 1)).getTime();
	const allDay: ScheduleEntry[] = [];
	const timed: ScheduleEntry[] = [];
	const due: ScheduleEntry[] = [];
	for (const e of all) {
		const s = entryStart(e);
		if (s && e.plannedAllDay) {
			if (s.getTime() >= from && s.getTime() < to) allDay.push(e);
		} else if (s) {
			const end = entryEnd(e).getTime();
			if (s.getTime() < to && Math.max(end, s.getTime() + 1) > from) timed.push(e);
		}
		if (e.dueAt) {
			const dd = new Date(e.dueAt).getTime();
			if (dd >= from && dd < to) due.push(e);
		}
	}
	return { allDay, timed, due };
}

export interface Placed {
	entry: ScheduleEntry;
	startMin: number;
	endMin: number;
	col: number;
	cols: number;
}
/** Timed blocks of one day in minutes from its start; overlapping blocks get side-by-side columns. */
export function layoutDay(entries: ScheduleEntry[], day: CivilDay): Placed[] {
	const from = dayStart(day).getTime();
	const items = entries
		.map((entry) => {
			const s = entryStart(entry)!.getTime();
			const startMin = Math.max(0, Math.round((s - from) / MINUTE));
			const rawEnd = Math.round((entryEnd(entry).getTime() - from) / MINUTE);
			const endMin = Math.min(1440, Math.max(rawEnd, startMin + MIN_MINUTES));
			return { entry, startMin, endMin, col: 0, cols: 1 };
		})
		.sort((a, b) => a.startMin - b.startMin || a.endMin - b.endMin || a.entry.taskID.localeCompare(b.entry.taskID));
	let cluster: Placed[] = [];
	let clusterEnd = -1;
	const finish = () => {
		const cols = cluster.reduce((m, p) => Math.max(m, p.col + 1), 1);
		for (const p of cluster) p.cols = cols;
		cluster = [];
	};
	const colEnds: number[] = [];
	for (const p of items) {
		if (cluster.length && p.startMin >= clusterEnd) {
			finish();
			colEnds.length = 0;
		}
		let col = colEnds.findIndex((end) => end <= p.startMin);
		if (col < 0) col = colEnds.length;
		colEnds[col] = p.endMin;
		p.col = col;
		cluster.push(p);
		clusterEnd = Math.max(clusterEnd, p.endMin);
		if (cluster.length === 1) clusterEnd = p.endMin;
	}
	finish();
	return items;
}

export const snapMinutes = (min: number, step = STEP_MINUTES): number => Math.min(1440 - step, Math.max(0, Math.round(min / step) * step));

export const canDrag = (e: ScheduleEntry): boolean => e.canEdit && e.status !== 'done';

export type DropTarget =
	| { kind: 'slot'; day: CivilDay; minutes: number }
	| { kind: 'allDay'; day: CivilDay }
	| { kind: 'unscheduled' };

/** Patch for dropping a card on a target; null when not allowed or nothing changes (`dueAt` is never touched). */
export function dropPlan(target: DropTarget, e: ScheduleEntry): SchedulePatch | null {
	if (!canDrag(e)) return null;
	if (target.kind === 'unscheduled') return e.plannedAt ? { plannedAt: null } : null;
	if (target.kind === 'allDay') {
		const iso = dayStart(target.day).toISOString();
		return e.plannedAllDay && e.plannedAt && new Date(e.plannedAt).toISOString() === iso ? null : { plannedAt: iso, plannedAllDay: true };
	}
	const minutes = snapMinutes(target.minutes);
	const iso = berlinToDate(target.day.y, target.day.m, target.day.d, Math.floor(minutes / 60), minutes % 60).toISOString();
	return !e.plannedAllDay && e.plannedAt && new Date(e.plannedAt).toISOString() === iso ? null : { plannedAt: iso, plannedAllDay: false };
}

function shiftLocal(start: Date, dayDelta: number, minDelta: number): Date {
	const p = berlinParts(start);
	const total = p.h * 60 + p.min + minDelta;
	const extraDays = Math.floor(total / 1440);
	const rest = total - extraDays * 1440;
	const c = addCivilDays(p, dayDelta + extraDays);
	return berlinToDate(c.y, c.m, c.d, Math.floor(rest / 60), rest % 60);
}

/** Arrow keys move by 15 minutes or one day, Shift+Up/Down changes the duration; null when the key does nothing. */
export function keyPlan(e: ScheduleEntry, key: string, shift: boolean): SchedulePatch | null {
	if (!canDrag(e) || !e.plannedAt) return null;
	const start = new Date(e.plannedAt);
	if (key === 'ArrowLeft' || key === 'ArrowRight') return { plannedAt: shiftLocal(start, key === 'ArrowRight' ? 1 : -1, 0).toISOString() };
	if (key !== 'ArrowUp' && key !== 'ArrowDown') return null;
	if (e.plannedAllDay) return null;
	const sign = key === 'ArrowDown' ? 1 : -1;
	if (shift) {
		const next = entryMinutes(e) + sign * STEP_MINUTES;
		return next < MIN_MINUTES || next > MAX_MINUTES ? null : { plannedMinutes: next };
	}
	return { plannedAt: shiftLocal(start, 0, sign * STEP_MINUTES).toISOString() };
}

const CONFLICT_KEYS: Record<ScheduleConflict, MessageKey> = {
	after_due: 'calendar.conflict.after_due',
	prerequisite_later: 'calendar.conflict.prerequisite_later',
	prerequisite_open: 'calendar.conflict.prerequisite_open',
	repository_overlap: 'calendar.conflict.repository_overlap'
};
export const conflictLabels = (e: Pick<ScheduleEntry, 'conflicts'>): string[] => e.conflicts.filter((c) => c in CONFLICT_KEYS).map((c) => t(CONFLICT_KEYS[c]));

/** `after_due` is cheap to recompute, so an optimistic move shows it at once; the other hints stay as the server sent them. */
export function withLocalConflicts(e: ScheduleEntry): ScheduleEntry {
	const rest = e.conflicts.filter((c) => c !== 'after_due');
	const start = entryStart(e);
	let after = false;
	if (start && e.dueAt) {
		const due = new Date(e.dueAt).getTime();
		after = e.plannedAllDay ? start.getTime() > due : entryEnd(e).getTime() > due;
	}
	return { ...e, conflicts: after ? [...rest, 'after_due'] : rest };
}

/** Optimistic local view of a patch. */
export function applyPatch(e: ScheduleEntry, patch: SchedulePatch): ScheduleEntry {
	const next = { ...e };
	if ('plannedAt' in patch) {
		next.plannedAt = patch.plannedAt ?? null;
		if (patch.plannedAt === null) {
			next.plannedAllDay = false;
			next.plannedMinutes = null;
		}
	}
	if ('plannedMinutes' in patch) next.plannedMinutes = patch.plannedMinutes ?? null;
	if (patch.plannedAllDay !== undefined) next.plannedAllDay = patch.plannedAllDay;
	return withLocalConflicts(next);
}

/** A card of the sidebar ("Ohne Termin"); the planning list carries no role, so the caller passes `canEdit`. */
export function unscheduledEntry(pt: PlanningTask, canEdit: boolean): ScheduleEntry {
	return {
		taskID: pt.task.id, projectID: pt.task.projectID, title: pt.task.title, status: pt.task.status, version: pt.task.version,
		plannedAt: null, plannedMinutes: null, plannedAllDay: false, dueAt: pt.dueAt ?? null, blocked: false, canEdit, autoStart: false, conflicts: []
	};
}

export function inversePatch(before: ScheduleEntry): SchedulePatch {
	return { plannedAt: before.plannedAt ?? null, plannedMinutes: before.plannedMinutes ?? null, plannedAllDay: before.plannedAllDay };
}

export interface UndoStep {
	taskID: string;
	/** Version after the move; the undo is sent against it. */
	version: number;
	patch: SchedulePatch;
}
export type CommitResult = { ok: true; undo: UndoStep } | { ok: false; key: MessageKey | null; error: unknown };

/** Maps a failed write to a German message key; null = use the generic error text. */
export function scheduleErrorKey(e: unknown): MessageKey | null {
	if (!(e instanceof ApiError)) return null;
	if (e.isConflict) return 'calendar.error.conflict';
	if (e.status === 409 && e.reason === 'task_done') return 'calendar.error.done';
	if (e.status === 403) return 'calendar.error.readOnly';
	if (e.reason === 'recurrence_requires_date') return 'calendar.error.recurrence';
	return null;
}

/** Sends one patch with the card's version; success carries what the undo needs, failure a message key. */
export async function commitSchedule(
	send: (taskID: string, body: ScheduleUpdate) => Promise<PlanningTask>,
	entry: ScheduleEntry,
	patch: SchedulePatch
): Promise<CommitResult> {
	try {
		const res = await send(entry.taskID, { version: entry.version, ...patch });
		return { ok: true, undo: { taskID: entry.taskID, version: res.task.version, patch: inversePatch(entry) } };
	} catch (error) {
		return { ok: false, key: scheduleErrorKey(error), error };
	}
}

const fmtTime = new Intl.DateTimeFormat('de-DE', { timeZone: TIME_ZONE, hour: '2-digit', minute: '2-digit' });
const fmtDay = new Intl.DateTimeFormat('de-DE', { timeZone: TIME_ZONE, weekday: 'short', day: 'numeric', month: 'short' });
export const formatTime = (d: Date): string => fmtTime.format(d);
export const formatDay = (d: Date): string => fmtDay.format(d);
export const formatDayHeading = (c: CivilDay): string => fmtDay.format(dayStart(c));
export const monthTitle = (anchor: Date): string => new Intl.DateTimeFormat('de-DE', { timeZone: TIME_ZONE, month: 'long', year: 'numeric' }).format(anchor);

/** Screen reader line for a card block: title, time or all-day, due and conflicts. */
export function describeEntry(e: ScheduleEntry): string {
	const s = entryStart(e);
	const parts = [e.title];
	if (s) parts.push(e.plannedAllDay ? `${formatDay(s)}, ${t('calendar.allDay')}` : `${formatDay(s)}, ${formatTime(s)} bis ${formatTime(entryEnd(e))}`);
	if (e.status === 'done') parts.push(t('calendar.doneMark'));
	if (!e.canEdit) parts.push(t('calendar.readOnly'));
	parts.push(...conflictLabels(e));
	return parts.join('. ');
}

const pad = (n: number) => String(n).padStart(2, '0');
/** Instant -> `datetime-local` value in Berlin wall clock (not the browser zone). */
export function toBerlinInput(iso: string | null | undefined): string {
	if (!iso) return '';
	const d = new Date(iso);
	if (Number.isNaN(d.getTime())) return '';
	const p = berlinParts(d);
	return `${p.y}-${pad(p.m)}-${pad(p.d)}T${pad(p.h)}:${pad(p.min)}`;
}
export function fromBerlinInput(value: string): Date | null {
	const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
	return m ? berlinToDate(+m[1], +m[2], +m[3], +m[4], +m[5]) : null;
}

export interface ScheduleForm {
	start: string;
	minutes: string;
	allDay: boolean;
}
/** Patch from the "Start und Dauer" dialog; null for invalid input (start missing, duration outside 5..1440). */
export function formPatch(e: ScheduleEntry, form: ScheduleForm): SchedulePatch | null {
	const start = fromBerlinInput(form.start);
	if (!start) return null;
	if (form.allDay) return { plannedAt: dayStart(civilOf(start)).toISOString(), plannedAllDay: true };
	const patch: SchedulePatch = { plannedAt: start.toISOString(), plannedAllDay: false };
	const raw = String(form.minutes ?? '').trim(); // a number input binds numbers at runtime
	if (raw === '') {
		if (e.plannedMinutes != null) patch.plannedMinutes = null;
	} else {
		const n = Number(raw);
		if (!Number.isInteger(n) || n < 5 || n > MAX_MINUTES) return null;
		patch.plannedMinutes = n;
	}
	return patch;
}
