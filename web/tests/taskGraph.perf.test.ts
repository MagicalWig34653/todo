import { describe, expect, it } from 'vitest';
import { buildTaskGraph, filterGraph, layoutGraph, limitLayout, neighbourNode, type GraphInput, type GraphTask } from '../src/lib/taskGraph.js';

// Performance regression tests for the layout on large boards (deterministic data, generous time limits so a slow CI
// machine does not flake, but tight enough to catch a quadratic or worse step).
const now = new Date('2026-11-03T12:00:00Z');
let seed = 42;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);

function bigInput(n: number, opts: { wideFeature?: number } = {}): GraphInput {
	seed = 42;
	const tasks: GraphTask[] = [];
	for (let i = 0; i < n; i++) {
		const done = rnd() < 0.3;
		const at = new Date(now.getTime() - Math.floor(rnd() * 120) * 86_400_000).toISOString();
		tasks.push({
			id: `t${i}`,
			title: `Aufgabe ${i}`,
			status: done ? 'done' : rnd() < 0.2 ? 'in_progress' : 'open',
			projectID: `p${i % 30}`,
			isFeature: i % 9 === 0,
			dueAt: !done && rnd() < 0.3 ? at : null,
			doneAt: done ? at : null,
			updatedAt: at,
			createdAt: at,
			parentID: null,
			milestoneID: rnd() < 0.1 ? `m${i % 14}` : null
		});
	}
	// features own the next few tasks as subtasks
	for (let f = 0; f < n; f += 9) for (let k = 1; k <= 5 && f + k < n; k++) tasks[f + k].parentID = tasks[f].id;
	if (opts.wideFeature) for (let k = 0; k < opts.wideFeature && k + 1 < n; k++) tasks[k + 1].parentID = tasks[0].id;
	const edges: GraphInput['edges'] = [];
	for (let i = 1; i < n; i++) if (rnd() < 0.3) edges.push({ taskID: `t${i}`, prerequisiteID: `t${Math.floor(rnd() * i)}` });
	const milestones = Array.from({ length: 14 }, (_, i) => ({ id: `m${i}`, title: `v${i}`, dueAt: null }));
	return { tasks, edges, milestones };
}
const time = <T>(fn: () => T): [T, number] => {
	const t = performance.now();
	const r = fn();
	return [r, performance.now() - t];
};

describe('layout performance', () => {
	it('lays out 700 tasks well under a frame budget', () => {
		const data = bigInput(700);
		const [layout, ms] = time(() => buildTaskGraph(data, { featuresOnly: false, hideDoneDays: null, now }));
		console.info('700 tasks', ms.toFixed(1), 'ms', layout.rows.length, 'rows', layout.laneCount, 'lanes');
		expect(layout.nodes.length).toBe(700);
		expect(ms).toBeLessThan(150);
	});

	it('scales close to linearly: 8000 tasks stay within 1.5 s', () => {
		const data = bigInput(8000);
		const [layout, ms] = time(() => buildTaskGraph(data, { featuresOnly: false, hideDoneDays: null, now }));
		console.info('8000 tasks', ms.toFixed(1), 'ms', layout.laneCount, 'lanes');
		expect(layout.nodes.length).toBe(8000);
		expect(ms).toBeLessThan(1500);
	});

	it('handles a feature with 2000 subtasks (wide lanes) and a long independent backlog', () => {
		const data = bigInput(6000, { wideFeature: 2000 });
		const [layout, ms] = time(() => layoutGraph(filterGraph(data, { featuresOnly: false, hideDoneDays: null, now }), now, data));
		console.info('wide feature', ms.toFixed(1), 'ms', layout.laneCount, 'lanes');
		expect(ms).toBeLessThan(1500);
		const [limited, lms] = time(() => limitLayout(layout, 300));
		expect(limited.rows.length).toBe(300);
		expect(lms).toBeLessThan(100);
	});

	it('keyboard navigation does not sort per key press', () => {
		const data = bigInput(3000);
		const layout = layoutGraph(filterGraph(data, { featuresOnly: false, hideDoneDays: null, now }), now, data);
		const limited = limitLayout(layout, 300);
		const id = limited.nodes[150].task.id;
		const [, ms] = time(() => {
			for (let i = 0; i < 1000; i++) neighbourNode(limited, id, 'down');
		});
		console.info('1000 neighbourNode', ms.toFixed(1), 'ms');
		expect(ms).toBeLessThan(200);
	});
});

// Digests taken from the earlier, quadratic implementation: the faster layout must produce exactly the same rows, lanes and colours.
describe('layout stays identical to the reference implementation', () => {
	const expected: [number, number, string][] = [
		[700, 0, '0cef3f09ba58470bd49013e0bde7e2072e40085a'],
		[3000, 0, '767b858c103e06ab1376ca350229f71fa0df1fdb'],
		[2500, 800, 'bfe99eedb55475035fd29fe88ec189e895207cc0']
	];
	it.each(expected)('%i tasks, wide feature %i', async (n, wide, digest) => {
		const { createHash } = await import('node:crypto');
		const data = bigInput(n, { wideFeature: wide });
		const l = layoutGraph(filterGraph(data, { featuresOnly: false, hideDoneDays: 30, now }), now, data);
		expect(createHash('sha1').update(JSON.stringify(l, (k, v) => (k === 'builds' || k === 'buildsMore' ? undefined : v))).digest('hex')).toBe(digest);
	});
});
