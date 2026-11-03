/**
 * Pure model of the task graph view, drawn like the history of a Git client. One row per task, newest first, planned
 * and open work above a "now" line, finished work below it. A lane is a strand of related work:
 *  - a parent (feature) is a merge commit: it sits above its subtasks, which branch off below it;
 *  - "waits for" is a lane connection too: a task sits above what it waits for;
 *  - milestones are tags on the rows of the tasks they release.
 * No DOM, no network. Everything is deterministic: same input, same rows, lanes and colours.
 */
import type { TaskStatus } from './api.js';

export interface GraphTask {
	id: string;
	title: string;
	status: TaskStatus;
	projectID: string;
	isFeature: boolean;
	dueAt?: string | null;
	/** When a done task was finished (last update); used by the filter and as its date. */
	doneAt?: string | null;
	updatedAt?: string | null;
	createdAt?: string | null;
	parentID?: string | null;
	/** Agent or person working on it. */
	agent?: string | null;
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
export type LinkKind = 'sub' | 'dep';

export interface Point {
	lane: number;
	row: number;
}
export interface LaidTag {
	milestoneID: string;
	title: string;
	state: MilestoneState;
	overdue: boolean;
	dueAt?: string | null;
}
export interface LaidNode {
	task: GraphTask;
	row: number;
	lane: number;
	/** Palette index (stable per strand). */
	color: number;
	/** Open prerequisites (ids) this task waits for. Empty for done tasks. */
	waitingFor: string[];
	blocked: boolean;
	/** True when other open tasks wait for this one. */
	blocking: boolean;
	overdue: boolean;
	/** Has subtasks below it: drawn as a merge point. */
	merge: boolean;
	/** The date shown in the row. */
	when: { kind: 'done' | 'due' | 'updated'; at: string | null };
	tags: LaidTag[];
}
export interface LaidEdge {
	/** The upper end (feature / the task that waits). */
	taskID: string;
	/** The lower end (subtask / prerequisite). */
	targetID: string;
	kind: LinkKind;
	/** Waypoints from the upper to the lower node. */
	points: Point[];
	color: number;
	/** Lane the edge travels in between the first and the last row. */
	via: number;
	/** The dependency is not done: the dependent is blocked by this edge. */
	blocking: boolean;
}
export interface LaidMilestone {
	milestone: GraphMilestone;
	state: MilestoneState;
	overdue: boolean;
	taskCount: number;
	doneCount: number;
}
export type GraphRow = { kind: 'node'; id: string } | { kind: 'now' };
export interface GraphLayout {
	rows: GraphRow[];
	nodes: LaidNode[];
	edges: LaidEdge[];
	milestones: LaidMilestone[];
	laneCount: number;
	/** Row index of the "now" line, or -1. */
	nowRow: number;
	/** True when rows were cut off by `limitLayout`. */
	truncated: boolean;
}

/** Binary min-heap by a numeric key; ties keep no particular order (keys are unique where it matters). */
class MinHeap<T> {
	private items: T[] = [];
	constructor(private key: (v: T) => number) {}
	get size(): number {
		return this.items.length;
	}
	peek(): T | undefined {
		return this.items[0];
	}
	push(v: T): void {
		const a = this.items;
		let i = a.push(v) - 1;
		while (i > 0) {
			const p = (i - 1) >> 1;
			if (this.key(a[p]) <= this.key(v)) break;
			a[i] = a[p];
			i = p;
		}
		a[i] = v;
	}
	pop(): T | undefined {
		const a = this.items;
		if (a.length === 0) return undefined;
		const top = a[0];
		const last = a.pop()!;
		if (a.length > 0) {
			let i = 0;
			for (;;) {
				let c = 2 * i + 1;
				if (c >= a.length) break;
				if (c + 1 < a.length && this.key(a[c + 1]) < this.key(a[c])) c++;
				if (this.key(a[c]) >= this.key(last)) break;
				a[i] = a[c];
				i = c;
			}
			a[i] = last;
		}
		return top;
	}
}

const DAY = 86_400_000;
/** Number of distinct lane colours (the renderer maps an index to a hue). */
export const PALETTE_SIZE = 8;

export function isOverdueTask(t: Pick<GraphTask, 'status' | 'dueAt'>, now: Date): boolean {
	return t.status !== 'done' && !!t.dueAt && Date.parse(t.dueAt) < now.getTime();
}

/** Released = it has tasks and all of them are done; everything else is planned (with an optional due date). */
export function milestoneState(tasks: Pick<GraphTask, 'status'>[]): MilestoneState {
	return tasks.length > 0 && tasks.every((t) => t.status === 'done') ? 'released' : 'planned';
}

/** First 7 hex digits of the id, like an abbreviated commit hash. */
export function shortID(id: string): string {
	return id.replace(/-/g, '').slice(0, 7).toLowerCase();
}

function hash(s: string): number {
	let h = 2166136261;
	for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
	return h >>> 0;
}

const time = (s?: string | null): number => {
	const v = s ? Date.parse(s) : NaN;
	return Number.isNaN(v) ? 0 : v;
};

/** Sort key: done = finished, open = due date, else last change. Larger = further up. */
function sortAt(t: GraphTask): number {
	return t.status === 'done' ? time(t.doneAt ?? t.updatedAt) : time(t.dueAt) || time(t.updatedAt) || time(t.createdAt);
}

function whenOf(t: GraphTask): LaidNode['when'] {
	if (t.status === 'done') return { kind: 'done', at: t.doneAt ?? t.updatedAt ?? null };
	if (t.dueAt) return { kind: 'due', at: t.dueAt };
	return { kind: 'updated', at: t.updatedAt ?? t.createdAt ?? null };
}

/** All links as `upper -> lower`, deduplicated, unknown tasks and self loops dropped. */
function collectLinks(input: GraphInput): { taskID: string; targetID: string; kind: LinkKind }[] {
	const known = new Set(input.tasks.map((t) => t.id));
	const out: { taskID: string; targetID: string; kind: LinkKind }[] = [];
	const seen = new Set<string>();
	const add = (taskID: string, targetID: string, kind: LinkKind) => {
		const key = `${kind}:${taskID}>${targetID}`;
		if (taskID === targetID || !known.has(taskID) || !known.has(targetID) || seen.has(key)) return;
		seen.add(key);
		out.push({ taskID, targetID, kind });
	};
	for (const t of input.tasks) if (t.parentID) add(t.parentID, t.id, 'sub');
	for (const e of input.edges) add(e.taskID, e.prerequisiteID, 'dep');
	return out;
}

/**
 * Applies the view filters. "Only features" keeps features and bridges links through the hidden open tasks between
 * them, so order and relations stay intact. Done tasks older than the cutoff disappear.
 */
export function filterGraph(input: GraphInput, f: GraphFilter): GraphInput {
	const byID = new Map(input.tasks.map((t) => [t.id, t]));
	const cutoff = f.hideDoneDays == null ? null : f.now.getTime() - f.hideDoneDays * DAY;
	const oldDone = (t: GraphTask) => cutoff != null && t.status === 'done' && !!t.doneAt && Date.parse(t.doneAt) < cutoff;
	const keep = (t: GraphTask) => (!f.featuresOnly || t.isFeature) && !oldDone(t);

	const links = collectLinks(input);
	const downs = new Map<string, { id: string; kind: LinkKind }[]>();
	for (const l of links) (downs.get(l.taskID) ?? downs.set(l.taskID, []).get(l.taskID)!).push({ id: l.targetID, kind: l.kind });
	const tasks = input.tasks.filter(keep);
	const kept = new Set(tasks.map((t) => t.id));
	const edges: GraphEdgeInput[] = [];
	const seen = new Set<string>();
	const parentOf = new Map<string, string>(); // visible parent after bridging
	for (const t of tasks) {
		// Walk through hidden, not yet done tasks to the next visible target.
		const stack = (downs.get(t.id) ?? []).map((d) => ({ ...d, direct: true }));
		const visited = new Set<string>();
		while (stack.length) {
			const cur = stack.pop()!;
			if (visited.has(cur.id)) continue;
			visited.add(cur.id);
			if (kept.has(cur.id)) {
				if (cur.kind === 'sub' && cur.direct) continue; // restored from parentID below
				const key = `${t.id}>${cur.id}`;
				if (!seen.has(key)) {
					seen.add(key);
					edges.push({ taskID: t.id, prerequisiteID: cur.id });
				}
			} else {
				const hidden = byID.get(cur.id)!;
				if (hidden.status !== 'done' && !oldDone(hidden)) stack.push(...(downs.get(cur.id) ?? []).map((d) => ({ ...d, direct: false })));
			}
		}
	}
	for (const t of tasks) if (t.parentID && kept.has(t.parentID)) parentOf.set(t.id, t.parentID);
	return { tasks: tasks.map((t) => ({ ...t, parentID: parentOf.get(t.id) ?? null })), edges, milestones: input.milestones };
}

/**
 * Lays the graph out. `full` is the unfiltered input so milestone state (released/planned) does not change with the
 * filters; `input` is what is drawn.
 */
export function layoutGraph(input: GraphInput, now: Date, full: GraphInput = input): GraphLayout {
	const byID = new Map(input.tasks.map((t) => [t.id, t]));
	// Display order basis: open work first (future on top), then done work, newest first; ties are stable.
	const sorted = [...input.tasks].sort(
		(a, b) =>
			Number(b.status !== 'done') - Number(a.status !== 'done') || sortAt(b) - sortAt(a) || a.title.localeCompare(b.title) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
	);
	const index = new Map(sorted.map((t, i) => [t.id, i]));
	const links = collectLinks(input);
	const downs = new Map<string, { id: string; kind: LinkKind }[]>();
	const ups = new Map<string, number>();
	for (const l of links) {
		(downs.get(l.taskID) ?? downs.set(l.taskID, []).get(l.taskID)!).push({ id: l.targetID, kind: l.kind });
		ups.set(l.targetID, (ups.get(l.targetID) ?? 0) + 1);
	}
	// Subtasks (branches) before prerequisites, each by display order, so the first branch continues the parent's strand.
	for (const list of downs.values()) list.sort((a, b) => Number(a.kind === 'dep') - Number(b.kind === 'dep') || index.get(a.id)! - index.get(b.id)!);

	// Topological order, upper nodes first. Among ready nodes the best display position wins.
	const waiting = new Map<string, number>(sorted.map((t) => [t.id, ups.get(t.id) ?? 0]));
	const ready = new MinHeap<GraphTask>((t) => index.get(t.id)!);
	for (const t of sorted) if (waiting.get(t.id) === 0) ready.push(t);
	const order: GraphTask[] = [];
	const placed = new Set<string>();
	const place = (t: GraphTask) => {
		order.push(t);
		placed.add(t.id);
		for (const d of downs.get(t.id) ?? []) {
			const left = (waiting.get(d.id) ?? 0) - 1;
			waiting.set(d.id, left);
			if (left === 0) ready.push(byID.get(d.id)!);
		}
	};
	while (order.length < sorted.length) {
		if (ready.size === 0) {
			// Defensive: a cycle (the server rejects them). Release the first unplaced task by display order.
			place(sorted.find((t) => !placed.has(t.id))!);
			continue;
		}
		const next = ready.pop()!;
		if (!placed.has(next.id)) place(next);
	}

	// Rows: the "now" line sits before the first done task.
	const rows: GraphRow[] = [];
	const rowOf = new Map<string, number>();
	let nowRow = -1;
	for (const t of order) {
		if (nowRow < 0 && t.status === 'done') {
			nowRow = rows.length;
			rows.push({ kind: 'now' });
		}
		rowOf.set(t.id, rows.length);
		rows.push({ kind: 'node', id: t.id });
	}
	if (nowRow < 0 && order.length > 0) {
		nowRow = rows.length;
		rows.push({ kind: 'now' });
	}

	// Lane assignment, top to bottom. A lane entry is the task the lane is travelling to, with its strand colour.
	// At most one lane travels to a given task, so lookups go through `laneTo`; free lanes and used colours are tracked
	// incrementally (the whole pass is O(n log n) instead of scanning every lane per link).
	type Entry = { id: string; color: number };
	const lanes: (Entry | null)[] = [];
	const laneTo = new Map<string, number>();
	const colorUse = new Array<number>(PALETTE_SIZE).fill(0);
	const freeLanes = new MinHeap<number>((i) => i);
	const setLane = (i: number, entry: Entry | null) => {
		const old = lanes[i];
		if (old) {
			colorUse[old.color]--;
			if (laneTo.get(old.id) === i) laneTo.delete(old.id);
		}
		lanes[i] = entry;
		if (entry) {
			colorUse[entry.color]++;
			laneTo.set(entry.id, i);
		} else freeLanes.push(i);
	};
	const laneOf = new Map<string, number>();
	const colorOf = new Map<string, number>();
	let maxLanes = 1;
	const newColor = (id: string): number => {
		const start = hash(id) % PALETTE_SIZE;
		for (let i = 0; i < PALETTE_SIZE; i++) {
			const c = (start + i) % PALETTE_SIZE;
			if (colorUse[c] === 0) return c;
		}
		return start;
	};
	/** Lowest free lane (not taken out: the caller may leave it free). */
	const freeLane = () => {
		while (freeLanes.size > 0 && lanes[freeLanes.peek()!] !== null) freeLanes.pop();
		if (freeLanes.size > 0) return freeLanes.peek()!;
		lanes.push(null);
		freeLanes.push(lanes.length - 1);
		return lanes.length - 1;
	};
	const via = new Map<string, { lane: number; color: number }>();
	for (const t of order) {
		let lane = laneTo.get(t.id) ?? -1;
		let color: number;
		if (lane < 0) {
			color = newColor(t.id);
			lane = freeLane();
		} else color = lanes[lane]!.color;
		if (laneTo.has(t.id)) setLane(lane, null); // the lane arriving here ends
		laneOf.set(t.id, lane);
		colorOf.set(t.id, color);
		let own = false;
		for (const d of downs.get(t.id) ?? []) {
			let l = laneTo.get(d.id) ?? -1;
			if (l < 0) {
				if (!own) {
					l = lane;
					own = true;
					setLane(l, { id: d.id, color });
				} else {
					const c = newColor(d.id);
					l = freeLane();
					setLane(l, { id: d.id, color: c });
				}
			}
			via.set(`${d.kind}:${t.id}>${d.id}`, { lane: l, color: lanes[l]!.color });
		}
		maxLanes = Math.max(maxLanes, lanes.length, lane + 1);
	}

	const laidEdges: LaidEdge[] = [];
	for (const l of links) {
		const r1 = rowOf.get(l.taskID)!;
		const r2 = rowOf.get(l.targetID)!;
		if (r2 <= r1) continue; // only reachable through a defensive cycle break
		const v = via.get(`${l.kind}:${l.taskID}>${l.targetID}`)!;
		const points: Point[] = [{ lane: laneOf.get(l.taskID)!, row: r1 }];
		if (r2 - r1 >= 2) {
			points.push({ lane: v.lane, row: r1 + 1 });
			if (r2 - 1 > r1 + 1) points.push({ lane: v.lane, row: r2 - 1 });
		}
		points.push({ lane: laneOf.get(l.targetID)!, row: r2 });
		laidEdges.push({
			taskID: l.taskID,
			targetID: l.targetID,
			kind: l.kind,
			points,
			color: v.color,
			via: v.lane,
			blocking: l.kind === 'dep' && byID.get(l.targetID)!.status !== 'done' && byID.get(l.taskID)!.status !== 'done'
		});
	}

	const waitingFor = new Map<string, string[]>();
	const blockingIDs = new Set<string>();
	const merges = new Set<string>();
	for (const e of laidEdges) {
		if (e.kind === 'sub') merges.add(e.taskID);
		if (!e.blocking) continue;
		(waitingFor.get(e.taskID) ?? waitingFor.set(e.taskID, []).get(e.taskID)!).push(e.targetID);
		blockingIDs.add(e.targetID);
	}

	// Milestones as tags; state comes from the unfiltered tasks. Only top-level members of a milestone carry the tag.
	const fullByMilestone = new Map<string, GraphTask[]>();
	for (const t of full.tasks) if (t.milestoneID) (fullByMilestone.get(t.milestoneID) ?? fullByMilestone.set(t.milestoneID, []).get(t.milestoneID)!).push(t);
	const laidMilestones: LaidMilestone[] = [];
	const tagOf = new Map<string, LaidTag>();
	for (const m of [...input.milestones].sort((a, b) => time(b.dueAt) - time(a.dueAt) || a.title.localeCompare(b.title))) {
		const own = fullByMilestone.get(m.id) ?? [];
		const state = milestoneState(own);
		const overdue = state === 'planned' && !!m.dueAt && Date.parse(m.dueAt) < now.getTime();
		laidMilestones.push({ milestone: m, state, overdue, taskCount: own.length, doneCount: own.filter((t) => t.status === 'done').length });
		tagOf.set(m.id, { milestoneID: m.id, title: m.title, state, overdue, dueAt: m.dueAt ?? null });
	}

	const nodes: LaidNode[] = order.map((t) => {
		const parent = t.parentID ? byID.get(t.parentID) : undefined;
		const tag = t.milestoneID && !(parent && parent.milestoneID === t.milestoneID) ? tagOf.get(t.milestoneID) : undefined;
		return {
			task: t,
			row: rowOf.get(t.id)!,
			lane: laneOf.get(t.id)!,
			color: colorOf.get(t.id)!,
			waitingFor: waitingFor.get(t.id) ?? [],
			blocked: (waitingFor.get(t.id) ?? []).length > 0,
			blocking: blockingIDs.has(t.id),
			overdue: isOverdueTask(t, now),
			merge: merges.has(t.id),
			when: whenOf(t),
			tags: tag ? [tag] : []
		};
	});

	return { rows, nodes, edges: laidEdges, milestones: laidMilestones, laneCount: maxLanes, nowRow, truncated: false };
}

/** Filters, then lays out. Milestone state always comes from the unfiltered tasks. */
export function buildTaskGraph(input: GraphInput, f: GraphFilter): GraphLayout {
	return layoutGraph(filterGraph(input, f), f.now, input);
}

/**
 * Keeps the first `maxRows` rows. Edges leaving the window continue as a stub to the bottom edge; lane count shrinks to
 * what is still visible.
 */
export function limitLayout(layout: GraphLayout, maxRows: number): GraphLayout {
	if (layout.rows.length <= maxRows) return layout;
	const nodes = layout.nodes.filter((n) => n.row < maxRows);
	const edges: LaidEdge[] = [];
	for (const e of layout.edges) {
		if (e.points[0].row >= maxRows) continue;
		if (e.points.at(-1)!.row < maxRows) {
			edges.push(e);
			continue;
		}
		const kept = e.points.filter((p) => p.row < maxRows);
		kept.push({ lane: kept.length > 1 ? kept.at(-1)!.lane : e.via, row: maxRows });
		edges.push({ ...e, points: kept });
	}
	let laneCount = 1;
	for (const n of nodes) laneCount = Math.max(laneCount, n.lane + 1);
	for (const e of edges) for (const p of e.points) laneCount = Math.max(laneCount, p.lane + 1);
	return {
		...layout,
		rows: layout.rows.slice(0, maxRows),
		nodes,
		edges,
		laneCount,
		nowRow: layout.nowRow < maxRows ? layout.nowRow : -1,
		truncated: true
	};
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

/** Arrow-key navigation between node rows (the "now" line is skipped). */
export function neighbourNode(layout: GraphLayout, id: string, dir: 'up' | 'down' | 'first' | 'last'): string | null {
	const byRow = [...layout.nodes].sort((a, b) => a.row - b.row);
	const i = byRow.findIndex((n) => n.task.id === id);
	if (i < 0) return null;
	if (dir === 'first') return byRow[0].task.id;
	if (dir === 'last') return byRow.at(-1)!.task.id;
	return byRow[dir === 'up' ? i - 1 : i + 1]?.task.id ?? null;
}
