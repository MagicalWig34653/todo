import { describe, expect, it } from 'vitest';
import {
	PALETTE_SIZE,
	buildTaskGraph,
	edgePath,
	filterGraph,
	layoutGraph,
	limitLayout,
	milestoneState,
	neighbourNode,
	shortID,
	type GraphInput,
	type GraphTask
} from '../src/lib/taskGraph.js';

const now = new Date('2026-11-03T12:00:00Z');
const t = (id: string, over: Partial<GraphTask> = {}): GraphTask => ({ id, title: id, status: 'open', projectID: 'p', isFeature: false, ...over });
const input = (tasks: GraphTask[], deps: [string, string][] = [], milestones: GraphInput['milestones'] = []): GraphInput => ({
	tasks,
	edges: deps.map(([taskID, prerequisiteID]) => ({ taskID, prerequisiteID })),
	milestones
});
const node = (l: ReturnType<typeof layoutGraph>, id: string) => l.nodes.find((n) => n.task.id === id)!;
const done = (id: string, at: string, over: Partial<GraphTask> = {}) => t(id, { status: 'done', doneAt: at, updatedAt: at, ...over });

describe('row order and the now line', () => {
	it('puts open work above the now line and done work below, newest first', () => {
		const l = layoutGraph(
			input([done('old', '2026-10-01T10:00:00Z'), t('later', { dueAt: '2026-12-01T10:00:00Z' }), done('new', '2026-11-02T10:00:00Z'), t('soon', { dueAt: '2026-11-10T10:00:00Z' })]),
			now
		);
		const ids = l.rows.map((r) => (r.kind === 'now' ? '|now|' : r.id));
		expect(ids).toEqual(['later', 'soon', '|now|', 'new', 'old']);
		expect(l.nowRow).toBe(2);
	});

	it('keeps the now line at the bottom when nothing is done and at the top when everything is', () => {
		expect(layoutGraph(input([t('a', { dueAt: '2026-12-01T00:00:00Z' })]), now).rows.map((r) => r.kind)).toEqual(['node', 'now']);
		expect(layoutGraph(input([done('a', '2026-11-01T00:00:00Z')]), now).rows.map((r) => r.kind)).toEqual(['now', 'node']);
		expect(layoutGraph(input([]), now).rows).toEqual([]);
	});

	it('shows the date that fits: done, due, updated', () => {
		const l = layoutGraph(input([done('d', '2026-11-01T00:00:00Z'), t('o', { dueAt: '2026-12-01T00:00:00Z' }), t('u', { updatedAt: '2026-11-02T00:00:00Z' })]), now);
		expect(node(l, 'd').when).toEqual({ kind: 'done', at: '2026-11-01T00:00:00Z' });
		expect(node(l, 'o').when.kind).toBe('due');
		expect(node(l, 'u').when).toEqual({ kind: 'updated', at: '2026-11-02T00:00:00Z' });
	});

	it('is deterministic', () => {
		const tasks = Array.from({ length: 30 }, (_, i) => t(`n${i}`, { parentID: i % 5 === 0 || i === 0 ? null : `n${i - (i % 5)}`, updatedAt: `2026-10-${String((i % 20) + 1).padStart(2, '0')}T00:00:00Z` }));
		const deps: [string, string][] = [['n7', 'n3'], ['n12', 'n8'], ['n25', 'n2']];
		const a = layoutGraph(input(tasks, deps), now);
		const b = layoutGraph(input([...tasks].reverse(), deps), now);
		expect(JSON.stringify(a.nodes.map((n) => [n.task.id, n.row, n.lane, n.color]))).toBe(JSON.stringify(b.nodes.map((n) => [n.task.id, n.row, n.lane, n.color])));
	});
});

describe('lanes', () => {
	it('keeps a plain chain on one lane with one colour', () => {
		const l = layoutGraph(input([t('c', { dueAt: '2026-12-03T00:00:00Z' }), t('b', { dueAt: '2026-12-02T00:00:00Z' }), t('a', { dueAt: '2026-12-01T00:00:00Z' })], [['c', 'b'], ['b', 'a']]), now);
		expect(l.nodes.map((n) => n.row)).toEqual([0, 1, 2]);
		expect(new Set(l.nodes.map((n) => n.lane)).size).toBe(1);
		expect(new Set(l.nodes.map((n) => n.color)).size).toBe(1);
		expect(l.laneCount).toBe(1);
	});

	it('a parent branches its subtasks and they merge back into it', () => {
		const l = layoutGraph(input([t('f', { isFeature: true, updatedAt: '2026-11-03T00:00:00Z' }), t('s1', { parentID: 'f', updatedAt: '2026-11-02T00:00:00Z' }), t('s2', { parentID: 'f', updatedAt: '2026-11-01T00:00:00Z' })]), now);
		expect(node(l, 'f').row).toBeLessThan(node(l, 's1').row);
		expect(node(l, 'f').merge).toBe(true);
		// First subtask continues the parent's strand, the second one opens a new lane with its own colour.
		expect(node(l, 's1').lane).toBe(node(l, 'f').lane);
		expect(node(l, 's1').color).toBe(node(l, 'f').color);
		expect(node(l, 's2').lane).not.toBe(node(l, 'f').lane);
		expect(node(l, 's2').color).not.toBe(node(l, 'f').color);
		expect(l.laneCount).toBe(2);
		const branch = l.edges.find((e) => e.targetID === 's2')!;
		expect(branch.kind).toBe('sub');
		expect(branch.points[0].lane).toBe(node(l, 'f').lane);
		expect(branch.points.at(-1)!.lane).toBe(node(l, 's2').lane);
		expect(branch.color).toBe(node(l, 's2').color);
	});

	it('waiting is a lane connection: the dependent sits above, and blocks only while open', () => {
		const l = layoutGraph(input([t('b', { updatedAt: '2026-11-03T00:00:00Z' }), t('a', { updatedAt: '2026-11-02T00:00:00Z' }), done('x', '2026-11-01T00:00:00Z'), t('y', { updatedAt: '2026-11-03T01:00:00Z' })], [['b', 'a'], ['y', 'x']]), now);
		expect(node(l, 'b').row).toBeLessThan(node(l, 'a').row);
		expect(node(l, 'b').blocked).toBe(true);
		expect(node(l, 'b').waitingFor).toEqual(['a']);
		expect(node(l, 'a').blocking).toBe(true);
		expect(l.edges.find((e) => e.targetID === 'a')!.blocking).toBe(true);
		expect(node(l, 'y').blocked).toBe(false);
		expect(l.edges.find((e) => e.targetID === 'x')!.blocking).toBe(false);
		expect(node(l, 'y').row).toBeLessThan(node(l, 'x').row);
	});

	it('two tasks waiting for the same one converge on a single lane (fork)', () => {
		const l = layoutGraph(input([t('p', { updatedAt: '2026-11-03T03:00:00Z' }), t('q', { updatedAt: '2026-11-03T02:00:00Z' }), t('base', { updatedAt: '2026-11-03T01:00:00Z' })], [['p', 'base'], ['q', 'base']]), now);
		expect(node(l, 'p').lane).not.toBe(node(l, 'q').lane);
		const ends = l.edges.filter((e) => e.targetID === 'base').map((e) => e.points.at(-1)!.lane);
		expect(new Set(ends).size).toBe(1);
		// The second edge reaches the merge lane via its own lane without crossing other nodes.
		expect(l.laneCount).toBe(2);
	});

	it('every edge goes strictly downward, ends on its nodes and uses valid lanes and colours', () => {
		const tasks = Array.from({ length: 60 }, (_, i) => t(`n${i}`, { updatedAt: new Date(Date.UTC(2026, 9, 1 + (i * 7) % 30)).toISOString(), status: i % 4 === 0 ? 'done' : 'open', doneAt: i % 4 === 0 ? '2026-10-15T00:00:00Z' : null, parentID: i > 0 && i % 6 === 1 ? `n${i - 1}` : null }));
		const deps: [string, string][] = [];
		for (let i = 2; i < 60; i += 3) deps.push([`n${i}`, `n${(i * 7) % i}`]);
		const l = layoutGraph(input(tasks, deps), now);
		expect(l.nodes).toHaveLength(60);
		expect(new Set(l.nodes.map((n) => n.row)).size).toBe(60);
		for (const e of l.edges) {
			const a = node(l, e.taskID), b = node(l, e.targetID);
			expect(a.row).toBeLessThan(b.row);
			expect(e.points[0]).toEqual({ lane: a.lane, row: a.row });
			expect(e.points.at(-1)).toEqual({ lane: b.lane, row: b.row });
			for (let i = 1; i < e.points.length; i++) expect(e.points[i].row).toBeGreaterThan(e.points[i - 1].row);
			expect(e.color).toBeGreaterThanOrEqual(0);
			expect(e.color).toBeLessThan(PALETTE_SIZE);
		}
		for (const n of l.nodes) expect(n.lane).toBeLessThan(l.laneCount);
	});

	it('survives a dependency cycle without hanging', () => {
		const l = layoutGraph(input([t('a'), t('b')], [['a', 'b'], ['b', 'a']]), now);
		expect(l.nodes).toHaveLength(2);
	});

	it('minimises lane changes: a chain of independent strands reuses lane 0', () => {
		const l = layoutGraph(input([t('a', { updatedAt: '2026-11-03T03:00:00Z' }), t('b', { updatedAt: '2026-11-03T02:00:00Z' }), t('c', { updatedAt: '2026-11-03T01:00:00Z' })]), now);
		expect(l.laneCount).toBe(1);
		expect(l.nodes.every((n) => n.lane === 0)).toBe(true);
	});
});

describe('tags', () => {
	it('marks released and planned milestones on top-level members only', () => {
		const ms = [{ id: 'm1', title: 'v1.0', dueAt: null }, { id: 'm2', title: 'v2.0', dueAt: '2026-01-01T00:00:00Z' }];
		const tasks = [done('a', '2026-11-01T00:00:00Z', { milestoneID: 'm1' }), t('b', { milestoneID: 'm2', updatedAt: '2026-11-02T00:00:00Z' }), t('c', { milestoneID: 'm2', parentID: 'b', updatedAt: '2026-11-01T00:00:00Z' })];
		const l = layoutGraph(input(tasks, [], ms), now);
		expect(node(l, 'a').tags).toMatchObject([{ title: 'v1.0', state: 'released' }]);
		expect(node(l, 'b').tags).toMatchObject([{ title: 'v2.0', state: 'planned', overdue: true }]);
		expect(node(l, 'c').tags).toEqual([]);
		expect(l.milestones.map((m) => m.milestone.id)).toEqual(['m2', 'm1']);
		expect(milestoneState([])).toBe('planned');
	});

	it('milestone state does not depend on the filter', () => {
		const ms = [{ id: 'm', title: 'v1', dueAt: null }];
		const full = input([done('a', '2020-01-01T00:00:00Z', { milestoneID: 'm' }), t('b', { milestoneID: 'm' })], [], ms);
		const l = buildTaskGraph(full, { featuresOnly: false, hideDoneDays: 7, now });
		expect(l.nodes.map((n) => n.task.id)).toEqual(['b']);
		expect(node(l, 'b').tags[0].state).toBe('planned');
		expect(l.milestones[0]).toMatchObject({ taskCount: 2, doneCount: 1 });
	});
});

describe('filterGraph', () => {
	it('only features bridges links through hidden open tasks', () => {
		const f = filterGraph(input([t('top', { isFeature: true }), t('mid'), t('low', { isFeature: true })], [['top', 'mid'], ['mid', 'low']]), { featuresOnly: true, hideDoneDays: null, now });
		expect(f.tasks.map((x) => x.id)).toEqual(['top', 'low']);
		expect(f.edges).toEqual([{ taskID: 'top', prerequisiteID: 'low' }]);
	});

	it('hides done tasks older than the cutoff and keeps a parent link only to visible parents', () => {
		const f = filterGraph(
			input([done('old', '2026-09-01T00:00:00Z'), done('fresh', '2026-11-01T00:00:00Z', { parentID: 'old' }), t('open', { parentID: 'fresh' })]),
			{ featuresOnly: false, hideDoneDays: 30, now }
		);
		expect(f.tasks.map((x) => [x.id, x.parentID])).toEqual([['fresh', null], ['open', 'fresh']]);
	});
});

describe('limitLayout', () => {
	const tasks = Array.from({ length: 10 }, (_, i) => t(`n${i}`, { updatedAt: new Date(Date.UTC(2026, 10, 3, 10 - i)).toISOString() }));
	const deps: [string, string][] = [['n0', 'n9'], ['n1', 'n2']];
	it('returns the layout unchanged when it fits', () => {
		const l = layoutGraph(input(tasks, deps), now);
		expect(limitLayout(l, 100)).toBe(l);
		expect(l.truncated).toBe(false);
	});
	it('cuts rows and continues edges as stubs to the bottom edge', () => {
		const l = limitLayout(layoutGraph(input(tasks, deps), now), 5);
		expect(l.rows).toHaveLength(5);
		expect(l.truncated).toBe(true);
		expect(l.nodes.every((n) => n.row < 5)).toBe(true);
		const stub = l.edges.find((e) => e.taskID === 'n0')!;
		expect(stub.points.at(-1)!.row).toBe(5);
		expect(l.edges.some((e) => e.taskID === 'n1')).toBe(true);
	});
});

describe('helpers', () => {
	it('edgePath draws straight lines on a lane and S-curves between lanes', () => {
		const x = (lane: number) => lane * 10;
		const y = (row: number) => row * 20;
		expect(edgePath([{ lane: 0, row: 0 }, { lane: 0, row: 2 }], x, y)).toBe('M0 0L0 40');
		expect(edgePath([{ lane: 0, row: 0 }, { lane: 1, row: 1 }], x, y)).toBe('M0 0C0 10 10 10 10 20');
	});

	it('shortID is a 7 digit hash-like prefix', () => {
		expect(shortID('4E633799-F7B9-4704-BB9C-9D224798ACF3')).toBe('4e63379');
	});

	it('neighbourNode moves between node rows and skips the now line', () => {
		const l = layoutGraph(input([t('a', { updatedAt: '2026-11-03T02:00:00Z' }), done('b', '2026-11-01T00:00:00Z')]), now);
		expect(neighbourNode(l, 'a', 'down')).toBe('b');
		expect(neighbourNode(l, 'b', 'up')).toBe('a');
		expect(neighbourNode(l, 'a', 'up')).toBeNull();
		expect(neighbourNode(l, 'a', 'last')).toBe('b');
		expect(neighbourNode(l, 'b', 'first')).toBe('a');
	});
});
