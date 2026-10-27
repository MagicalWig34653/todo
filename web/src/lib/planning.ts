import type { Page, PlanningTask, Recurrence, Task, TaskStatus } from './api.js';

export const STATUSES: TaskStatus[] = ['open', 'in_progress', 'in_review', 'done'];
export const PRIORITIES = [0, 1, 2, 3] as const;

const pad = (n: number) => String(n).padStart(2, '0');

/** ISO instant -> value for `<input type="datetime-local">` in the browser's local time. */
export function toLocalInput(iso: string | null | undefined): string {
	if (!iso) return '';
	const d = new Date(iso);
	if (Number.isNaN(d.getTime())) return '';
	return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** `datetime-local` value (local time) -> ISO instant; empty or invalid input becomes null. */
export function fromLocalInput(value: string): string | null {
	if (!value) return null;
	const d = new Date(value);
	return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** Short German date/time for chips; date only when the time is midnight. */
export function formatWhen(iso: string | null | undefined, locale = 'de-DE'): string {
	if (!iso) return '';
	const d = new Date(iso);
	if (Number.isNaN(d.getTime())) return '';
	const midnight = d.getHours() === 0 && d.getMinutes() === 0;
	return new Intl.DateTimeFormat(locale, midnight ? { dateStyle: 'medium' } : { dateStyle: 'medium', timeStyle: 'short' }).format(d);
}

export function isOverdue(iso: string | null | undefined, done: boolean, now = new Date()): boolean {
	return !!iso && !done && new Date(iso).getTime() < now.getTime();
}

/** Moves `id` by `delta` positions within `ids`; returns the same array when impossible. */
export function moveWithin(ids: string[], id: string, delta: number): string[] {
	const from = ids.indexOf(id);
	const to = from + delta;
	if (from < 0 || to < 0 || to >= ids.length) return ids;
	const next = [...ids];
	next.splice(from, 1);
	next.splice(to, 0, id);
	return next;
}

/** Board columns from the four column responses; keeps the server order inside each column. */
export function columns(byStatus: Record<TaskStatus, PlanningTask[]>) {
	return STATUSES.map((status) => ({ status, items: byStatus[status] ?? [] }));
}

/** Follows `nextCursor` until the list is complete (with a hard page cap against server loops). */
export async function collectAll<T>(fetchPage: (cursor: string | null) => Promise<Page<T>>, maxPages = 20): Promise<T[]> {
	const items: T[] = [];
	let cursor: string | null = null;
	for (let i = 0; i < maxPages; i++) {
		const page: Page<T> = await fetchPage(cursor);
		items.push(...page.items);
		if (!page.nextCursor) break;
		cursor = page.nextCursor;
	}
	return items;
}

export function browserTimeZone(): string {
	return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
}

export type Frequency = 'none' | 'daily' | 'weekly' | 'monthly';

/** Form state (local inputs) -> API recurrence; `none` or a missing anchor date yields null. */
export function buildRecurrence(frequency: Frequency, interval: number, until: string, timeZone = browserTimeZone()): Recurrence | null {
	if (frequency === 'none') return null;
	const n = Math.min(1000, Math.max(1, Math.trunc(Number.isFinite(interval) ? interval : 1)));
	return { frequency, interval: n, timeZone, until: fromLocalInput(until) };
}

/** A recurrence needs a due or planned date (backend: `recurrence_requires_date`). */
export function recurrenceNeedsDate(recurrence: Recurrence | null, due: string, planned: string): boolean {
	return recurrence !== null && !due && !planned;
}

/** Adds a reminder (local input) keeping the list unique and sorted; invalid input is ignored. */
export function addReminder(reminders: string[], local: string): string[] {
	const iso = fromLocalInput(local);
	if (!iso || reminders.includes(iso)) return reminders;
	return [...reminders, iso].sort();
}

export function removeReminder(reminders: string[], iso: string): string[] {
	return reminders.filter((r) => r !== iso);
}

/** Tasks that are not yet in `excluded` and not the task itself, for dependency/milestone pickers. */
export function candidateTasks(all: Task[], selfID: string | null, excluded: Task[]): Task[] {
	const skip = new Set([...excluded.map((x) => x.id), ...(selfID ? [selfID] : [])]);
	return all.filter((x) => !skip.has(x.id));
}

/** Milestone progress: finished vs. all assigned tasks. */
export function milestoneProgress(tasks: Task[]): { done: number; total: number } {
	return { done: tasks.filter((x) => x.status === 'done').length, total: tasks.length };
}
