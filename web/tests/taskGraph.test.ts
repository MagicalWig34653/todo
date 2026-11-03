import { describe, expect, it } from 'vitest';
import { buildTaskGraph, edgePath, filterGraph, layoutGraph, milestoneState, neighbourNode, type GraphInput, type GraphTask } from '../src/lib/taskGraph.js';

const now = new Date('2026-11-03T12:00:00Z');
const t = (id: string, over: Partial<GraphTask> = {}): GraphTask => ({ id, title: id, status: 'open', projectID: 'p', isFeature: false, ...over });
const input = (tasks: GraphTask[], deps: [string, string][] = [], milestones: GraphInput['milestones'] = []): GraphInput => ({
	tasks,
	edges: deps.map(([taskID, prerequisiteID]) => ({ taskID, prerequisiteID })),
	milestones
});
const row = (l: ReturnType<typeof layoutGraph>, id: string) => l.nodes.find((n) => n.task.id === id)!;

describe('layoutGraph', () => {
	it('puts dependents above their prerequisites', () => {
		const l = layoutGraph(input([t('c'), t('b'), t('a')], [['c', 'b'], ['b', 'a']]), now);
		expect(row(l, 'c').row).toBeLessThan(row(l, 'b').row);
		expect(row(l, 'b').row).toBeLessThan(row(l, 'a').row);
		// A plain chain stays on one lane.
		expect(new Set(l.nodes.map((n) => n.lane)).size).toBe(1);
		expect(l.laneCount).toBe(1);
	});

	it('branches for a second prerequisite and merges back (diamond)', () => {
		// d waits for b and c, both wait for a.
		const l = layoutGraph(input([t('d'), t('b'), t('c'), t('a')], [['d', 'b'], ['d', 'c'], ['b', 'a'], ['c', 'a']]), now);
		expect(l.laneCount).toBe(2);
		expect(row(l, 'd').lane).toBe(0);
		expect(row(l, 'b').lane).not.toBe(row(l, 'c').lane);
		expect(row(l, 'a').lane).toBe(0);
		const merge = l.edges.find((e) => e.taskID === 'c' && e.prerequisiteID === 'a')!;
		expect(merge.points[0].lane).not.toBe(merge.points.at(-1)!.lane);
	});

	it('every edge goes strictly downward and ends on its nodes', () => {
		const tasks = Array.from({ length: 40 }, (_, i) => t(`n${i}`));
		const deps: [string, string][] = [];
		for (let i = 1; i < 40; i++) {
			deps.push([`n${i}`, `n${(i * 7) % i}`]);
			if (i % 3 === 0) deps.push([`n${i}`, `n${Math.floor(i / 2)}`]);
		}
		const l = layoutGraph(input(tasks, deps), now);
		for (const e of l.edges) {
			const from = row(l, e.taskID), to = row(l, e.prerequisiteID);
			expect(e.points[0]).toEqual({ lane: from.lane, row: from.row });
			expect(e.points.at(-1)).toEqual({ lane: to.lane, row: to.row });
			expect(to.row).toBeGreaterThan(from.row);
			for (let i = 1; i < e.points.length; i++) expect(e.points[i].row).toBeGreaterThan(e.points[i - 1].row);
		}
		// No two nodes share a grid cell.
		expect(new Set(l.nodes.map((n) => `${n.lane}:${n.row}`)).size).toBe(l.nodes.length);
	});

	it('marks blocked tasks, what they wait for, and the blocking predecessor', () => {
		const l = layoutGraph(input([t('b', { status: 'in_progress' }), t('a'), t('x', { status: 'done' }), t('y')], [['b', 'a'], ['y', 'x']]), now);
		expect(row(l, 'b').blocked).toBe(true);
		expect(row(l, 'b').waitingFor).toEqual(['a']);
		expect(row(l, 'a').blocking).toBe(true);
		expect(row(l, 'a').blocked).toBe(false);
		// A done prerequisite does not block.
		expect(row(l, 'y').blocked).toBe(false);
		expect(l.edges.find((e) => e.taskID === 'y')!.blocking).toBe(false);
	});

	it('flags overdue open tasks only', () => {
		const l = layoutGraph(input([t('late', { dueAt: '2026-11-01T00:00:00Z' }), t('doneLate', { dueAt: '2026-11-01T00:00:00Z', status: 'done' }), t('future', { dueAt: '2027-01-01T00:00:00Z' })]), now);
		expect(row(l, 'late').overdue).toBe(true);
		expect(row(l, 'doneLate').overdue).toBe(false);
		expect(row(l, 'future').overdue).toBe(false);
	});

	it('groups tasks under milestone markers, latest milestone on top', () => {
		const ms = [{ id: 'm1', title: '1.0', dueAt: '2026-09-01T00:00:00Z' }, { id: 'm2', title: '2.0', dueAt: '2027-01-01T00:00:00Z' }];
		const l = layoutGraph(
			input([t('a', { milestoneID: 'm1', status: 'done' }), t('b', { milestoneID: 'm2' }), t('c')], [['b', 'a']], ms),
			now
		);
		const markers = l.milestones.map((m) => m.milestone?.id ?? null);
		expect(markers).toEqual([null, 'm2', 'm1']);
		const rowOfMarker = (id: string | null) => l.milestones.find((m) => (m.milestone?.id ?? null) === id)!.row;
		expect(row(l, 'c').row).toBeGreaterThan(rowOfMarker(null));
		expect(row(l, 'b').row).toBeGreaterThan(rowOfMarker('m2'));
		expect(row(l, 'b').row).toBeLessThan(rowOfMarker('m1'));
		expect(row(l, 'a').row).toBeGreaterThan(rowOfMarker('m1'));
		const m1 = l.milestones.find((m) => m.milestone?.id === 'm1')!;
		expect(m1.state).toBe('released');
		expect(m1.doneCount).toBe(1);
		expect(l.milestones.find((m) => m.milestone?.id === 'm2')!.state).toBe('planned');
	});

	it('keeps empty milestones and marks planned milestones in the past as overdue', () => {
		const l = layoutGraph(input([t('a')], [], [{ id: 'm', title: 'Old', dueAt: '2026-01-01T00:00:00Z' }]), now);
		const m = l.milestones.find((x) => x.milestone?.id === 'm')!;
		expect(m.state).toBe('planned');
		expect(m.overdue).toBe(true);
	});

	it('survives cycles and unknown edges without throwing or looping', () => {
		const l = layoutGraph(input([t('a'), t('b')], [['a', 'b'], ['b', 'a'], ['a', 'ghost'], ['a', 'a']]), now);
		expect(l.nodes).toHaveLength(2);
		for (const e of l.edges) expect(row(l, e.prerequisiteID).row).toBeGreaterThan(row(l, e.taskID).row);
	});

	it('handles 600 nodes quickly', () => {
		const tasks = Array.from({ length: 600 }, (_, i) => t(`n${i}`, { milestoneID: i % 50 === 0 ? 'm' : null }));
		const deps: [string, string][] = [];
		for (let i = 1; i < 600; i++) deps.push([`n${i}`, `n${i - 1}`], [`n${i}`, `n${Math.floor(Math.random() * i)}`]);
		const start = performance.now();
		const l = layoutGraph(input(tasks, deps, [{ id: 'm', title: 'M' }]), now);
		expect(performance.now() - start).toBeLessThan(1500);
		expect(l.nodes).toHaveLength(600);
	});
});

describe('filterGraph', () => {
	it('features only bridges dependencies through hidden open tasks', () => {
		const f = filterGraph(input([t('F2', { isFeature: true }), t('mid'), t('F1', { isFeature: true })], [['F2', 'mid'], ['mid', 'F1']]), { featuresOnly: true, hideDoneDays: null, now });
		expect(f.tasks.map((x) => x.id)).toEqual(['F2', 'F1']);
		expect(f.edges).toEqual([{ taskID: 'F2', prerequisiteID: 'F1' }]);
	});

	it('does not bridge through a done task', () => {
		const f = filterGraph(input([t('F2', { isFeature: true }), t('mid', { status: 'done' }), t('F1', { isFeature: true })], [['F2', 'mid'], ['mid', 'F1']]), { featuresOnly: true, hideDoneDays: null, now });
		expect(f.edges).toEqual([]);
	});

	it('hides done tasks older than N days but keeps recent and undated ones', () => {
		const tasks = [
			t('old', { status: 'done', doneAt: '2026-09-01T00:00:00Z' }),
			t('recent', { status: 'done', doneAt: '2026-10-30T00:00:00Z' }),
			t('undated', { status: 'done' }),
			t('open')
		];
		const f = filterGraph(input(tasks), { featuresOnly: false, hideDoneDays: 14, now });
		expect(f.tasks.map((x) => x.id)).toEqual(['recent', 'undated', 'open']);
	});

	it('milestone state ignores the filters', () => {
		const ms = [{ id: 'm', title: 'R' }];
		const all = input([t('a', { status: 'done', milestoneID: 'm', doneAt: '2026-01-01T00:00:00Z' }), t('b', { status: 'done', milestoneID: 'm', doneAt: '2026-01-01T00:00:00Z' })], [], ms);
		const l = buildTaskGraph(all, { featuresOnly: false, hideDoneDays: 7, now });
		expect(l.nodes).toHaveLength(0);
		expect(l.milestones[0].state).toBe('released');
		expect(l.milestones[0].taskCount).toBe(2);
	});
});

describe('helpers', () => {
	it('milestoneState', () => {
		expect(milestoneState([])).toBe('planned');
		expect(milestoneState([{ status: 'done' }, { status: 'open' }])).toBe('planned');
		expect(milestoneState([{ status: 'done' }])).toBe('released');
	});
	it('edgePath uses curves only on lane changes', () => {
		const x = (l: number) => l * 10, y = (r: number) => r * 10;
		expect(edgePath([{ lane: 0, row: 0 }, { lane: 0, row: 2 }], x, y)).toBe('M0 0L0 20');
		expect(edgePath([{ lane: 0, row: 0 }, { lane: 1, row: 1 }], x, y)).toBe('M0 0C0 5 10 5 10 10');
	});
	it('neighbourNode moves by row and lane', () => {
		const l = layoutGraph(input([t('d'), t('b'), t('c'), t('a')], [['d', 'b'], ['d', 'c'], ['b', 'a'], ['c', 'a']]), now);
		const order = l.nodes.map((n) => n.task.id);
		expect(neighbourNode(l, order[0], 'down')).toBe(order[1]);
		expect(neighbourNode(l, order[0], 'up')).toBeNull();
		expect(neighbourNode(l, 'd', 'right')).not.toBeNull();
	});
});
