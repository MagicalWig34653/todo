import type { BoardColumn, Task } from './api.js';
import type { MessageKey } from './i18n/index.js';

export type Sort = 'manual' | 'title' | 'due' | 'priority';
export type Grouping = 'none' | 'column' | 'priority' | 'due';
export type ViewMode = 'list' | 'board';

export interface Display {
	view: ViewMode;
	sort: Sort;
	grouping: Grouping;
	showDone: boolean;
}
export const DEFAULT_DISPLAY: Display = { view: 'list', sort: 'manual', grouping: 'column', showDone: true };

export interface Group {
	key: string;
	/** Literal title (column names are user data). */
	title?: string;
	titleKey?: MessageKey;
	color?: string | null;
	columnID?: string | null;
	tasks: Task[];
}

const dueMs = (t: Task) => (t.planning?.dueAt ? new Date(t.planning.dueAt).getTime() : Number.POSITIVE_INFINITY);

export function sortTasks(tasks: Task[], sort: Sort): Task[] {
	const base = [...tasks];
	if (sort === 'title') return base.sort((a, b) => a.title.localeCompare(b.title, 'de'));
	if (sort === 'due') return base.sort((a, b) => dueMs(a) - dueMs(b));
	if (sort === 'priority') return base.sort((a, b) => (b.planning?.priority ?? 0) - (a.planning?.priority ?? 0));
	return base;
}

/**
 * Groups for the list view. `column` grouping follows the project's columns (sections) and puts tasks without a column first;
 * without own columns it degrades to a single group.
 */
export function groupTasks(tasks: Task[], grouping: Grouping, columns: BoardColumn[], sort: Sort, now = new Date()): Group[] {
	const sorted = sortTasks(tasks, sort);
	if (grouping === 'column' && columns.length > 0 && columns.every((c) => c.id)) {
		const byColumn = (id: string | null) =>
			sorted.filter((t) => (t.columnID ?? null) === id).sort((a, b) => (sort === 'manual' ? (a.boardPosition ?? 0) - (b.boardPosition ?? 0) : 0));
		const groups: Group[] = columns.map((c) => ({ key: c.id!, title: c.name, color: c.color, columnID: c.id, tasks: byColumn(c.id) }));
		const loose = byColumn(null);
		return loose.length > 0 ? [{ key: 'none', titleKey: 'list.noColumn', columnID: null, tasks: loose }, ...groups] : groups;
	}
	if (grouping === 'priority') {
		return [3, 2, 1, 0]
			.map((p) => ({
				key: `p${p}`,
				titleKey: `planning.priority.${p}` as MessageKey,
				tasks: sorted.filter((t) => (t.planning?.priority ?? 0) === p)
			}))
			.filter((g) => g.tasks.length > 0);
	}
	if (grouping === 'due') {
		const startOfDay = new Date(now);
		startOfDay.setHours(0, 0, 0, 0);
		const endOfDay = new Date(now);
		endOfDay.setHours(23, 59, 59, 999);
		const bucket = (t: Task) => {
			const ms = dueMs(t);
			if (!Number.isFinite(ms)) return 'none';
			if (ms < startOfDay.getTime()) return 'overdue';
			return ms <= endOfDay.getTime() ? 'today' : 'later';
		};
		return (['overdue', 'today', 'later', 'none'] as const)
			.map((b) => ({ key: b, titleKey: `list.due.${b}` as MessageKey, tasks: sorted.filter((t) => bucket(t) === b) }))
			.filter((g) => g.tasks.length > 0);
	}
	return [{ key: 'all', tasks: sorted }];
}
