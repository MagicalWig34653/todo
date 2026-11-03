/**
 * Pure model of the task graph view ("git log for tasks"): filtering, topological row order, lane assignment and edge
 * routing. No DOM, no network. Rows run top to bottom, newest first: a task sits above everything it waits for, so the
 * prerequisites ("older commits") are below. Edges are polylines on a (lane, row) grid; the renderer turns lane changes
 * into curves.
 */
import type { TaskStatus } from './api.js';

export interface GraphTask {
	id: string;
	title: string;
	status: TaskStatus;
	projectID: string;
	isFeature: boolean;
	dueAt?: string | null;
	/** When a done task was finished (last update); used by the "hide done older than N days" filter. */
	doneAt?: string | null;
	milestoneID?: string | null;
}
export interface GraphMilestone {
	id: string;
	title: string;
	dueAt?: string | null;
}
/** `taskID` waits for `prerequisiteID`. */
export interface GraphEdgeInput {
	taskID: string;
	prerequisiteID: string;
}
export interface GraphInput {
	tasks: GraphTask[];
	edges: GraphEdgeInput[];
	milestones: GraphMilestone[];
}
export interface GraphFilter {
	featuresOnly: boolean;
	/** Hide done tasks that were finished more than this many days ago; `null` = keep all. */
	hideDoneDays: number | null;
	now: Date;
}
export type MilestoneState = 'released' | 'planned';

export interface Point {
	lane: number;
	row: number;
}
export interface LaidNode {
	task: GraphTask;
	row: number;
	lane: number;
	/** Open prerequisites (ids) this task waits for. Empty for done tasks. */
	waitingFor: string[];
	blocked: boolean;
	/** True when other open tasks wait for this one. */
	blocking: boolean;
	overdue: boolean;
}
export interface LaidEdge {
	taskID: string;
	prerequisiteID: string;
	/** Waypoints from the dependent (top) to the prerequisite (bottom). */
	points: Point[];
	/** The prerequisite is not done: the dependent is blocked by this edge. */
	blocking: boolean;
}
export interface LaidMilestone {
	milestone: GraphMilestone | null;
	row: number;
	state: MilestoneState;
	overdue: boolean;
	taskCount: number;
	doneCount: number;
}
export type GraphRow = { kind: 'node'; id: string } | { kind: 'milestone'; milestoneID: string | null };
export interface GraphLayout {
	rows: GraphRow[];
	nodes: LaidNode[];
	edges: LaidEdge[];
	milestones: LaidMilestone[];
	laneCount: number;
}

const DAY = 86_400_000;

export function isOverdueTask(t: Pick<GraphTask, 'status' | 'dueAt'>, now: Date): boolean {
	return t.status !== 'done' && !!t.dueAt && Date.parse(t.dueAt) < now.getTime();
}

/** Released = it has tasks and all of them are done; everything else is planned (with an optional due date). */
export function milestoneState(tasks: Pick<GraphTask, 'status'>[]): MilestoneState {
	return tasks.length > 0 && tasks.every((t) => t.status === 'done') ? 'released' : 'planned';
}

/**
 * Applies the view filters. "Only features" keeps features and bridges dependencies through the hidden open tasks
 * between them, so the order and the waiting relations stay intact. Done tasks older than the cutoff disappear.
 */
export function filterGraph(input: GraphInput, f: GraphFilter): GraphInput {
	const byID = new Map(input.tasks.map((t) => [t.id, t]));
	const cutoff = f.hideDoneDays == null ? null : f.now.getTime() - f.hideDoneDays * DAY;
	const oldDone = (t: GraphTask) => cutoff != null && t.status === 'done' && !!t.doneAt && Date.parse(t.doneAt) < cutoff;
	const keep = (t: GraphTask) => (!f.featuresOnly || t.isFeature) && !oldDone(t);

	const prereqs = new Map<string, string[]>();
	for (const e of input.edges) {
		if (!byID.has(e.taskID) || !byID.has(e.prerequisiteID)) continue;
		(prereqs.get(e.taskID) ?? prereqs.set(e.taskID, []).get(e.taskID)!).push(e.prerequisiteID);
	}
	const tasks = input.tasks.filter(keep);
	const kept = new Set(tasks.map((t) => t.id));
	const edges: GraphEdgeInput[] = [];
	const seen = new Set<string>();
	for (const t of tasks) {
		// Walk through hidden, not yet done tasks to the next visible prerequisite.
		const stack = [...(prereqs.get(t.id) ?? [])];
		const visited = new Set<string>();
		while (stack.length) {
			const id = stack.pop()!;
			if (visited.has(id)) continue;
			visited.add(id);
			if (kept.has(id)) {
				const key = `${t.id}>${id}`;
				if (!seen.has(key)) {
					seen.add(key);
					edges.push({ taskID: t.id, prerequisiteID: id });
				}
			} else {
				const hidden = byID.get(id)!;
				if (hidden.status !== 'done' && !oldDone(hidden)) stack.push(...(prereqs.get(id) ?? []));
			}
		}
	}
	return { tasks, edges, milestones: input.milestones };
}

/** Descending by due date; milestones without a date come first (still open ended), then by title. */
function milestoneOrder(a: GraphMilestone, b: GraphMilestone): number {
	const da = a.dueAt ? Date.parse(a.dueAt) : Number.POSITIVE_INFINITY;
	const db = b.dueAt ? Date.parse(b.dueAt) : Number.POSITIVE_INFINITY;
	if (da !== db) return da > db ? -1 : 1;
	return a.title.localeCompare(b.title) || (a.id < b.id ? -1 : 1);
}

/**
 * Lays the graph out. `full` is the unfiltered input so milestone state (released/planned) does not change with the
 * filters; `input` is what is drawn.
 */
export function layoutGraph(input: GraphInput, now: Date, full: GraphInput = input): GraphLayout {
	const byID = new Map(input.tasks.map((t) => [t.id, t]));
	const index = new Map(input.tasks.map((t, i) => [t.id, i]));
	// Dedupe and drop edges to unknown tasks / self loops.
	const prereqs = new Map<string, string[]>();
	const dependents = new Map<string, string[]>();
	const seenEdge = new Set<string>();
	for (const e of input.edges) {
		const key = `${e.taskID}>${e.prerequisiteID}`;
		if (e.taskID === e.prerequisiteID || !byID.has(e.taskID) || !byID.has(e.prerequisiteID) || seenEdge.has(key)) continue;
		seenEdge.add(key);
		(prereqs.get(e.taskID) ?? prereqs.set(e.taskID, []).get(e.taskID)!).push(e.prerequisiteID);
		(dependents.get(e.prerequisiteID) ?? dependents.set(e.prerequisiteID, []).get(e.prerequisiteID)!).push(e.taskID);
	}
	for (const list of prereqs.values()) list.sort((a, b) => index.get(a)! - index.get(b)!);

	// Groups: 0 = no milestone, then milestones by due date (latest on top).
	const milestones = [...input.milestones].sort(milestoneOrder);
	const groupOf = new Map<string, number>(milestones.map((m, i) => [m.id, i + 1]));
	const group = (t: GraphTask) => (t.milestoneID ? (groupOf.get(t.milestoneID) ?? 0) : 0);

	// Topological order, dependents first. Among ready tasks the top-most group wins, then the input order.
	const waiting = new Map<string, number>(input.tasks.map((t) => [t.id, (dependents.get(t.id) ?? []).length]));
	let ready = input.tasks.filter((t) => waiting.get(t.id) === 0);
	const order: GraphTask[] = [];
	const placed = new Set<string>();
	const better = (a: GraphTask, b: GraphTask) => group(a) - group(b) || index.get(a.id)! - index.get(b.id)!;
	const place = (t: GraphTask) => {
		order.push(t);
		placed.add(t.id);
		for (const p of prereqs.get(t.id) ?? []) {
			const left = (waiting.get(p) ?? 0) - 1;
			waiting.set(p, left);
			if (left === 0) ready.push(byID.get(p)!);
		}
	};
	while (order.length < input.tasks.length) {
		if (ready.length === 0) {
			// Defensive: a cycle (the server rejects them). Release the first unplaced task by input order.
			const next = input.tasks.find((t) => !placed.has(t.id))!;
			place(next);
			continue;
		}
		let bi = 0;
		for (let i = 1; i < ready.length; i++) if (better(ready[i], ready[bi]) < 0) bi = i;
		const [next] = ready.splice(bi, 1);
		if (!placed.has(next.id)) place(next);
	}

	// Rows with milestone markers: a marker precedes the first task of its group; empty groups keep their slot.
	const rows: GraphRow[] = [];
	const emitted = new Set<number>();
	const hasUnassigned = input.tasks.some((t) => group(t) === 0);
	const emitUpTo = (g: number) => {
		for (let i = 0; i <= g; i++) {
			if (emitted.has(i)) continue;
			emitted.add(i);
			if (i === 0) {
				if (hasUnassigned && milestones.length > 0) rows.push({ kind: 'milestone', milestoneID: null });
			} else rows.push({ kind: 'milestone', milestoneID: milestones[i - 1].id });
		}
	};
	const rowOf = new Map<string, number>();
	for (const t of order) {
		emitUpTo(group(t));
		rowOf.set(t.id, rows.length);
		rows.push({ kind: 'node', id: t.id });
	}
	emitUpTo(milestones.length);

	// Lane assignment (top to bottom). `lanes[i]` is the task a lane is currently waiting to reach.
	const lanes: (string | null)[] = [];
	const laneOf = new Map<string, number>();
	const via = new Map<string, number>(); // edge key -> lane the edge travels in
	const freeLane = () => {
		const i = lanes.indexOf(null);
		if (i >= 0) return i;
		lanes.push(null);
		return lanes.length - 1;
	};
	for (const t of order) {
		let lane = lanes.indexOf(t.id);
		if (lane < 0) lane = freeLane();
		for (let i = 0; i < lanes.length; i++) if (lanes[i] === t.id) lanes[i] = null; // merge: all waiting lanes end here
		laneOf.set(t.id, lane);
		let ownLaneTaken = false;
		for (const p of prereqs.get(t.id) ?? []) {
			let l = lanes.indexOf(p);
			if (l < 0) {
				if (!ownLaneTaken) {
					l = lane;
					ownLaneTaken = true;
				} else l = freeLane();
				lanes[l] = p;
			}
			via.set(`${t.id}>${p}`, l);
		}
	}

	const laidEdges: LaidEdge[] = [];
	for (const [tid, list] of prereqs) {
		for (const pid of list) {
			const r1 = rowOf.get(tid)!;
			const r2 = rowOf.get(pid)!;
			if (r2 <= r1) continue; // only reachable through a defensive cycle break
			const start = { lane: laneOf.get(tid)!, row: r1 };
			const end = { lane: laneOf.get(pid)!, row: r2 };
			const through = via.get(`${tid}>${pid}`) ?? start.lane;
			const points: Point[] = [start];
			if (r2 - r1 >= 2) {
				points.push({ lane: through, row: r1 + 1 });
				if (r2 - 1 > r1 + 1) points.push({ lane: through, row: r2 - 1 });
			}
			points.push(end);
			laidEdges.push({ taskID: tid, prerequisiteID: pid, points, blocking: byID.get(pid)!.status !== 'done' && byID.get(tid)!.status !== 'done' });
		}
	}

	const waitingFor = new Map<string, string[]>();
	const blockingIDs = new Set<string>();
	for (const e of laidEdges) {
		if (!e.blocking) continue;
		(waitingFor.get(e.taskID) ?? waitingFor.set(e.taskID, []).get(e.taskID)!).push(e.prerequisiteID);
		blockingIDs.add(e.prerequisiteID);
	}
	const nodes: LaidNode[] = order.map((t) => ({
		task: t,
		row: rowOf.get(t.id)!,
		lane: laneOf.get(t.id)!,
		waitingFor: waitingFor.get(t.id) ?? [],
		blocked: (waitingFor.get(t.id) ?? []).length > 0,
		blocking: blockingIDs.has(t.id),
		overdue: isOverdueTask(t, now)
	}));

	const fullByMilestone = new Map<string, GraphTask[]>();
	for (const t of full.tasks) if (t.milestoneID) (fullByMilestone.get(t.milestoneID) ?? fullByMilestone.set(t.milestoneID, []).get(t.milestoneID)!).push(t);
	const laidMilestones: LaidMilestone[] = [];
	rows.forEach((r, row) => {
		if (r.kind !== 'milestone') return;
		const m = r.milestoneID ? (milestones.find((x) => x.id === r.milestoneID) ?? null) : null;
		const own = m ? (fullByMilestone.get(m.id) ?? []) : [];
		const state = m ? milestoneState(own) : 'planned';
		laidMilestones.push({
			milestone: m,
			row,
			state,
			overdue: !!m && state === 'planned' && !!m.dueAt && Date.parse(m.dueAt) < now.getTime(),
			taskCount: own.length,
			doneCount: own.filter((t) => t.status === 'done').length
		});
	});

	return { rows, nodes, edges: laidEdges, milestones: laidMilestones, laneCount: Math.max(1, lanes.length) };
}

/** Filters, then lays out. Milestone state always comes from the unfiltered tasks. */
export function buildTaskGraph(input: GraphInput, f: GraphFilter): GraphLayout {
	return layoutGraph(filterGraph(input, f), f.now, input);
}

/**
 * SVG path for one edge: straight along a lane, cubic S-curves where the lane changes. `x(lane)` and `y(row)` are the
 * pixel centres.
 */
export function edgePath(points: Point[], x: (lane: number) => number, y: (row: number) => number): string {
	let d = `M${x(points[0].lane)} ${y(points[0].row)}`;
	for (let i = 1; i < points.length; i++) {
		const a = points[i - 1];
		const b = points[i];
		const x1 = x(a.lane), y1 = y(a.row), x2 = x(b.lane), y2 = y(b.row);
		if (a.lane === b.lane) d += `L${x2} ${y2}`;
		else {
			const mid = (y1 + y2) / 2;
			d += `C${x1} ${mid} ${x2} ${mid} ${x2} ${y2}`;
		}
	}
	return d;
}

/** Arrow-key navigation: next/previous node row, or the nearest node on a neighbouring lane. */
export function neighbourNode(layout: GraphLayout, id: string, dir: 'up' | 'down' | 'left' | 'right'): string | null {
	const cur = layout.nodes.find((n) => n.task.id === id);
	if (!cur) return null;
	const byRow = [...layout.nodes].sort((a, b) => a.row - b.row);
	const i = byRow.indexOf(cur);
	if (dir === 'up') return byRow[i - 1]?.task.id ?? null;
	if (dir === 'down') return byRow[i + 1]?.task.id ?? null;
	const want = cur.lane + (dir === 'left' ? -1 : 1);
	const candidates = byRow.filter((n) => n.lane === want).sort((a, b) => Math.abs(a.row - cur.row) - Math.abs(b.row - cur.row));
	return candidates[0]?.task.id ?? null;
}
