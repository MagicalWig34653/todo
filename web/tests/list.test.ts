import { describe, expect, it } from 'vitest';
import type { BoardColumn, Task } from '../src/lib/api';
import { groupTasks, sortTasks } from '../src/lib/listLogic';

const t = (id: string, o: Partial<Task> & { due?: string; prio?: number } = {}): Task => ({
	id, projectID: 'p', title: id, description: '', status: 'open', version: 1, columnID: o.columnID ?? null, boardPosition: o.boardPosition ?? 0,
	planning: { dueAt: o.due, priority: o.prio ?? 0, position: 0, hasRecurrence: false, reminderCount: 0 }
});
const cols: BoardColumn[] = [
	{ id: 'c1', name: 'A', isDone: false, position: 0, version: 1, tasks: [] },
	{ id: 'c2', name: 'B', isDone: true, position: 1, version: 1, tasks: [] }
];
describe('list grouping', () => {
	it('sorts by title, due and priority', () => {
		const xs = [t('b', { due: '2026-12-01T00:00:00Z', prio: 1 }), t('a', { prio: 3 }), t('c', { due: '2026-11-01T00:00:00Z' })];
		expect(sortTasks(xs, 'title').map((x) => x.id)).toEqual(['a', 'b', 'c']);
		expect(sortTasks(xs, 'due').map((x) => x.id)).toEqual(['c', 'b', 'a']);
		expect(sortTasks(xs, 'priority').map((x) => x.id)).toEqual(['a', 'b', 'c']);
	});
	it('groups by column with loose tasks first and manual board order', () => {
		const xs = [t('x', { columnID: 'c1', boardPosition: 1 }), t('y', { columnID: 'c1', boardPosition: 0 }), t('z')];
		const g = groupTasks(xs, 'column', cols, 'manual');
		expect(g.map((x) => x.key)).toEqual(['none', 'c1', 'c2']);
		expect(g[1].tasks.map((x) => x.id)).toEqual(['y', 'x']);
	});
	it('falls back to one group without columns', () => {
		expect(groupTasks([t('a')], 'column', [], 'manual')).toHaveLength(1);
	});
	it('groups by due bucket', () => {
		const now = new Date('2026-10-29T10:00:00');
		const g = groupTasks([t('o', { due: '2026-10-01T10:00:00' }), t('h', { due: '2026-10-29T20:00:00' }), t('n')], 'due', [], 'manual', now);
		expect(g.map((x) => x.key)).toEqual(['overdue', 'today', 'none']);
	});
});
