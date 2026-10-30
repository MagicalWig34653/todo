import type { Project } from './api.js';

export interface ProjectNode {
	project: Project;
	children: ProjectNode[];
}

/** Sibling order of ADR 0012: the viewer's position first (unpositioned last), then createdAt, then id. */
export function compareSiblings(a: Project, b: Project): number {
	const pa = a.position ?? Number.POSITIVE_INFINITY;
	const pb = b.position ?? Number.POSITIVE_INFINITY;
	if (pa !== pb) return pa < pb ? -1 : 1;
	const ca = a.createdAt ?? '';
	const cb = b.createdAt ?? '';
	if (ca !== cb) return ca < cb ? -1 : 1;
	return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/** Builds a forest from the flat list; orphans (parent not visible) become roots. Siblings follow `compareSiblings`. */
export function buildTree(projects: Project[]): ProjectNode[] {
	const nodes = new Map<string, ProjectNode>(projects.map((p) => [p.id, { project: p, children: [] }]));
	const roots: ProjectNode[] = [];
	for (const node of nodes.values()) {
		const parent = node.project.parentID ? nodes.get(node.project.parentID) : undefined;
		(parent ? parent.children : roots).push(node);
	}
	const order = (list: ProjectNode[]) => {
		list.sort((a, b) => compareSiblings(a.project, b.project));
		for (const n of list) order(n.children);
	};
	order(roots);
	return roots;
}

/** Parent as the viewer sees it: a parent that is not in the list (redacted) counts as top level. */
export function visibleParent(projects: Project[], p: Project): string | null {
	return p.parentID && projects.some((x) => x.id === p.parentID) ? p.parentID : null;
}

/** Ordered siblings (same visible parent) of `parentID`, optionally without one project. */
export function siblingsOf(projects: Project[], parentID: string | null, without?: string): Project[] {
	return projects
		.filter((x) => x.id !== without && visibleParent(projects, x) === parentID)
		.sort(compareSiblings);
}

export type DropZone = 'before' | 'after' | 'into';
export interface DropPlan {
	/** New (or unchanged) parent as the viewer sees it. */
	parentID: string | null;
	/** Index among the siblings of that parent, without the moved project. */
	index: number;
	/** True when the shared tree changes (needs `manage`, sends parentID + version). */
	reparent: boolean;
}

/**
 * Where a project lands when dropped on `target` in `zone`. Returns null for impossible drops
 * (onto itself or into its own subtree, which the backend would reject as a cycle) and for no-ops.
 */
export function planDrop(projects: Project[], dragID: string, targetID: string, zone: DropZone): DropPlan | null {
	const drag = projects.find((p) => p.id === dragID);
	const target = projects.find((p) => p.id === targetID);
	if (!drag || !target || dragID === targetID) return null;
	if (selfAndDescendants(projects, dragID).has(targetID)) return null;
	const parentID = zone === 'into' ? target.id : visibleParent(projects, target);
	const siblings = siblingsOf(projects, parentID, dragID);
	let index = siblings.length;
	if (zone !== 'into') {
		const at = siblings.findIndex((s) => s.id === targetID);
		index = zone === 'before' ? at : at + 1;
	}
	const reparent = visibleParent(projects, drag) !== parentID;
	if (!reparent) {
		const current = siblingsOf(projects, parentID).findIndex((s) => s.id === dragID);
		if (current === index) return null;
	}
	return { parentID, index, reparent };
}

/** Plan for "move up/down" menu items; null at the edges. */
export function planStep(projects: Project[], id: string, direction: -1 | 1): DropPlan | null {
	const p = projects.find((x) => x.id === id);
	if (!p) return null;
	const parentID = visibleParent(projects, p);
	const list = siblingsOf(projects, parentID);
	const at = list.findIndex((s) => s.id === id);
	const to = at + direction;
	if (at < 0 || to < 0 || to >= list.length) return null;
	return { parentID, index: to, reparent: false };
}

/** Plan for the menu "Verschieben nach…": to the end of the new parent's children. */
export function planMoveTo(projects: Project[], id: string, parentID: string | null): DropPlan | null {
	const p = projects.find((x) => x.id === id);
	if (!p || visibleParent(projects, p) === parentID) return null;
	return { parentID, index: siblingsOf(projects, parentID, id).length, reparent: true };
}

/** IDs of a project and all its descendants; these are invalid move targets. */
export function selfAndDescendants(projects: Project[], id: string): Set<string> {
	const result = new Set<string>([id]);
	let grew = true;
	while (grew) {
		grew = false;
		for (const p of projects) {
			if (p.parentID && result.has(p.parentID) && !result.has(p.id)) {
				result.add(p.id);
				grew = true;
			}
		}
	}
	return result;
}

/** Flat, depth-annotated list for select boxes. */
export function flatten(nodes: ProjectNode[], depth = 0): { project: Project; depth: number }[] {
	return nodes.flatMap((n) => [{ project: n.project, depth }, ...flatten(n.children, depth + 1)]);
}
