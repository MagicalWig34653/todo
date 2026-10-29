import { describe, expect, it } from 'vitest';
import type { Task } from '../src/lib/api';
import { inboxTasks, openCounts, todayTasks } from '../src/lib/counts';

const t = (id: string, projectID: string, status: Task['status'], dueAt?: string): Task => ({
	id, projectID, title: id, description: '', status, version: 1,
	planning: { dueAt, priority: 0, position: 0, hasRecurrence: false, reminderCount: 0 }
});
const now = new Date('2026-10-29T10:00:00');
const tasks = [
	t('a', 'p1', 'open'),
	t('b', 'p1', 'done'),
	t('c', 'p2', 'open', '2026-10-29T18:00:00'),
	t('d', 'p2', 'open', '2026-10-20T08:00:00'),
	t('e', 'p2', 'in_progress', '2026-11-02T08:00:00')
];
describe('counts', () => {
	it('inbox = open without due date', () => expect(inboxTasks(tasks).map((x) => x.id)).toEqual(['a']));
	it('today includes overdue, excludes later and done', () => expect(todayTasks(tasks, now).map((x) => x.id)).toEqual(['c', 'd']));
	it('counts open tasks per project', () => expect([...openCounts(tasks)]).toEqual([['p1', 1], ['p2', 3]]));
});
