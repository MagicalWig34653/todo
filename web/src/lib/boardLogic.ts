import type { BoardColumn, BoardResponse, Task } from './api.js';

/** A board lane: a real column, a virtual status column, or the "no column" bucket (`laneKey === 'none'`). */
export interface Lane extends BoardColumn {
	/** Stable key for keyed each-blocks and drag data. */
	laneKey: string;
}

export const NO_COLUMN_KEY = 'none';

export function toLanes(board: BoardResponse): Lane[] {
	const lanes: Lane[] = board.columns.map((c) => ({ ...c, laneKey: c.id ?? `status:${c.key ?? c.position}` }));
	if (board.mode === 'columns' && board.unassigned.length > 0) {
		lanes.unshift({
			id: null,
			key: null,
			name: '',
			color: null,
			isDone: false,
			position: -1,
			version: null,
			tasks: board.unassigned,
			laneKey: NO_COLUMN_KEY
		});
	}
	return lanes;
}

/**
 * Optimistic move of a task to lane `toKey` at `index` (clamped). Returns new lanes, or the same array when nothing changes.
 * Moving into a done column marks the task done, moving a done task into another column reopens it (mirrors ADR 0011).
 */
export function applyMove(lanes: Lane[], taskID: string, toKey: string, index: number): Lane[] {
	const from = lanes.find((l) => l.tasks.some((x) => x.id === taskID));
	const to = lanes.find((l) => l.laneKey === toKey);
	if (!from || !to) return lanes;
	const task = from.tasks.find((x) => x.id === taskID)!;
	const fromIndex = from.tasks.indexOf(task);
	const rest = to.tasks.filter((x) => x.id !== taskID);
	const target = Math.max(0, Math.min(index, rest.length));
	if (from === to && target === fromIndex) return lanes;
	const status = to.isDone ? 'done' : task.status === 'done' ? 'open' : task.status;
	const moved: Task = { ...task, status, columnID: to.id };
	return lanes.map((l) => {
		if (l === to) {
			const tasks = [...rest];
			tasks.splice(target, 0, moved);
			return { ...l, tasks };
		}
		if (l === from) return { ...l, tasks: l.tasks.filter((x) => x.id !== taskID) };
		return l;
	});
}

/** Moves `key` to position `to` among `keys`; returns the same array when nothing changes. */
export function reorderKeys(keys: string[], key: string, to: number): string[] {
	const from = keys.indexOf(key);
	if (from < 0) return keys;
	const next = keys.filter((k) => k !== key);
	next.splice(Math.max(0, Math.min(to, next.length)), 0, key);
	return next.join() === keys.join() ? keys : next;
}

/** Colour choices for project markers and columns (contract: `#RRGGBB`, uppercase). */
export const PROJECT_COLORS = [
	'#DB4D40', '#EB8A0A', '#C2A61A', '#45AE5C', '#29ABAB', '#2470E0', '#6B59D9', '#B852C7', '#E05290', '#737378'
] as const;

/** Stable marker colour derived from the project id (the server has no project colours yet; same idea as the native app). */
export function projectColor(id: string | null | undefined): string {
	if (!id) return PROJECT_COLORS[9];
	let h = 0;
	for (let i = 0; i < id.length; i++) h = (h * 131 + id.charCodeAt(i)) & 0xffffff;
	return PROJECT_COLORS[h % PROJECT_COLORS.length];
}

/** First line of a description, shortened for cards. */
export function snippet(text: string, max = 90): string {
	const line = text.trim().split('\n')[0] ?? '';
	return line.length > max ? line.slice(0, max - 1) + '…' : line;
}
