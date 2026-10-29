import type { Task } from './api.js';

const isOpen = (t: Task) => t.status !== 'done';

/** "Eingang": open tasks without a due date, across all projects (same rule as the native app). */
export const inboxTasks = (tasks: Task[]) => tasks.filter((t) => isOpen(t) && !t.planning?.dueAt);

/** "Heute": open tasks due today or earlier (overdue), in the browser's local day. */
export function todayTasks(tasks: Task[], now = new Date()): Task[] {
	const end = new Date(now);
	end.setHours(23, 59, 59, 999);
	return tasks.filter((t) => isOpen(t) && !!t.planning?.dueAt && new Date(t.planning.dueAt).getTime() <= end.getTime());
}

/** Open task count per project id (own tasks only, sub-projects are counted on their own row). */
export function openCounts(tasks: Task[]): Map<string, number> {
	const m = new Map<string, number>();
	for (const t of tasks) if (isOpen(t)) m.set(t.projectID, (m.get(t.projectID) ?? 0) + 1);
	return m;
}
