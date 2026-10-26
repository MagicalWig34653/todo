import type { Project } from './api.js';

export interface ProjectNode {
	project: Project;
	children: ProjectNode[];
}

/** Builds a forest from the flat list; orphans (parent not visible) become roots. */
export function buildTree(projects: Project[]): ProjectNode[] {
	const nodes = new Map<string, ProjectNode>(projects.map((p) => [p.id, { project: p, children: [] }]));
	const roots: ProjectNode[] = [];
	for (const node of nodes.values()) {
		const parent = node.project.parentID ? nodes.get(node.project.parentID) : undefined;
		(parent ? parent.children : roots).push(node);
	}
	return roots;
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
