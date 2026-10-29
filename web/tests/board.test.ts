import { describe, expect, it } from 'vitest';
import type { BoardResponse, Task } from '../src/lib/api';
import { applyMove, projectColor, reorderKeys, snippet, toLanes } from '../src/lib/boardLogic';

const task = (id: string, status: Task['status'] = 'open', columnID: string | null = null): Task => ({
	id, projectID: 'p', title: id, description: '', status, version: 1, columnID, boardPosition: 0
});
const board = (): BoardResponse => ({
	projectID: 'p',
	mode: 'columns',
	columns: [
		{ id: 'c1', name: 'A', isDone: false, position: 0, version: 1, tasks: [task('t1', 'open', 'c1'), task('t2', 'open', 'c1')] },
		{ id: 'c2', name: 'B', isDone: false, position: 1, version: 1, tasks: [] },
		{ id: 'c3', name: 'Done', isDone: true, position: 2, version: 1, tasks: [task('t3', 'done', 'c3')] }
	],
	unassigned: [task('u1')]
});

describe('board lanes', () => {
	it('prepends the no-column lane only when needed', () => {
		expect(toLanes(board()).map((l) => l.laneKey)).toEqual(['none', 'c1', 'c2', 'c3']);
		expect(toLanes({ ...board(), unassigned: [] }).map((l) => l.laneKey)).toEqual(['c1', 'c2', 'c3']);
	});
	it('moves within a column', () => {
		const lanes = applyMove(toLanes(board()), 't1', 'c1', 1);
		expect(lanes.find((l) => l.laneKey === 'c1')!.tasks.map((x) => x.id)).toEqual(['t2', 't1']);
	});
	it('returns the same lanes for a no-op', () => {
		const lanes = toLanes(board());
		expect(applyMove(lanes, 't1', 'c1', 0)).toBe(lanes);
		expect(applyMove(lanes, 'missing', 'c1', 0)).toBe(lanes);
	});
	it('moves between columns and clamps the index', () => {
		const lanes = applyMove(toLanes(board()), 't1', 'c2', 99);
		expect(lanes.find((l) => l.laneKey === 'c1')!.tasks.map((x) => x.id)).toEqual(['t2']);
		const b = lanes.find((l) => l.laneKey === 'c2')!.tasks;
		expect(b.map((x) => x.id)).toEqual(['t1']);
		expect(b[0].columnID).toBe('c2');
	});
	it('couples done columns with the status', () => {
		let lanes = applyMove(toLanes(board()), 't1', 'c3', 0);
		expect(lanes.find((l) => l.laneKey === 'c3')!.tasks[0]).toMatchObject({ id: 't1', status: 'done' });
		lanes = applyMove(lanes, 't3', 'c2', 0);
		expect(lanes.find((l) => l.laneKey === 'c2')!.tasks[0]).toMatchObject({ id: 't3', status: 'open' });
	});
	it('reorders column keys', () => {
		expect(reorderKeys(['a', 'b', 'c'], 'a', 2)).toEqual(['b', 'c', 'a']);
		const same = ['a', 'b'];
		expect(reorderKeys(same, 'a', 0)).toBe(same);
	});
});

describe('helpers', () => {
	it('derives a stable project colour', () => {
		expect(projectColor('abc')).toBe(projectColor('abc'));
		expect(projectColor('abc')).toMatch(/^#[0-9A-F]{6}$/);
	});
	it('shortens descriptions to the first line', () => {
		expect(snippet('eins\nzwei')).toBe('eins');
		expect(snippet('x'.repeat(200), 10)).toHaveLength(10);
	});
});
