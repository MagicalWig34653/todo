/** Pure rules of the permission model (ADR 0005, docs/BERECHTIGUNGEN.md): roles, what a role may do, inheritance, who sees what. */
import type { EffectiveVisibility, PrincipalType, Project, ProjectGrant, Role, TeamMembership } from './api.js';

/** Weakest first. */
export const ROLES: Role[] = ['read', 'comment', 'edit', 'manage'];

export const roleRank = (r: Role | null | undefined): number => (r ? ROLES.indexOf(r) : -1);
export const hasRole = (have: Role | null | undefined, need: Role): boolean => roleRank(have) >= roleRank(need);
export const maxRole = (a: Role | null | undefined, b: Role | null | undefined): Role | undefined => (roleRank(a) >= roleRank(b) ? (a ?? undefined) : (b ?? undefined));

/** Things a person does in a project, and the lowest role that allows them (backend: PlanningController, ADR 0005). */
export type Action = 'comment' | 'addTask' | 'editTask' | 'editProject' | 'share';
export const ACTION_ROLE: Record<Action, Role> = {
	comment: 'comment',
	addTask: 'edit',
	editTask: 'edit',
	editProject: 'manage',
	share: 'manage'
};
export const can = (role: Role | null | undefined, action: Action): boolean => hasRole(role, ACTION_ROLE[action]);
/** The role a person is missing for an action, or null if the action is allowed. */
export const missingRole = (role: Role | null | undefined, action: Action): Role | null => (can(role, action) ? null : ACTION_ROLE[action]);

/** Own role in a project; projects from older servers without the field count as own (full access). */
export const roleOf = (p: Pick<Project, 'role'>): Role => p.role ?? 'manage';
export const isOwner = (p: Pick<Project, 'isOwner'>): boolean => p.isOwner ?? true;

/** Roots of the visible tree, split into own projects and projects of other people ("Mit mir geteilt"). */
export function splitRoots(projects: Project[]): { mine: Project[]; shared: Project[] } {
	const ids = new Set(projects.map((p) => p.id));
	const roots = projects.filter((p) => !p.parentID || !ids.has(p.parentID));
	return { mine: roots.filter(isOwner), shared: roots.filter((p) => !isOwner(p)) };
}
export const sharedWithMe = (projects: Project[]): Project[] => projects.filter((p) => !isOwner(p));

/** Ancestor chain (nearest first) as far as it is visible. */
export function ancestors(projects: Project[], id: string): Project[] {
	const out: Project[] = [];
	const seen = new Set<string>([id]);
	let current = projects.find((p) => p.id === id);
	while (current?.parentID && !seen.has(current.parentID)) {
		seen.add(current.parentID);
		current = projects.find((p) => p.id === current!.parentID);
		if (current) out.push(current);
	}
	return out;
}

export interface Principal {
	type: PrincipalType;
	id: string;
	name: string;
}
/** One line in the sharing dialog: a direct grant of this project or one inherited from an ancestor. */
export interface AccessRow {
	key: string;
	principal: Principal;
	role: Role;
	/** `undefined` = granted directly on this project. */
	inheritedFrom?: { id: string; name: string };
	grantID?: string;
}

export interface AncestorGrants {
	project: { id: string; name: string };
	/** False = this ancestor does not pass its grants down (inheritance switched off); the chain stops there. */
	inherits: boolean;
	/** `null` = not readable for this viewer (no manage role there). */
	grants: ProjectGrant[] | null;
}

/**
 * Ancestors whose grants reach `project`: walks up while the project (and every ancestor on the way) inherits.
 * `load` returns the ancestor's own inheritance flag and its grants.
 */
export async function inheritedChain(
	project: Project,
	inherits: boolean,
	all: Project[],
	load: (p: Project) => Promise<{ inherits: boolean; grants: ProjectGrant[] | null }>
): Promise<AncestorGrants[]> {
	const out: AncestorGrants[] = [];
	if (!inherits) return out;
	for (const anc of ancestors(all, project.id)) {
		const info = await load(anc);
		out.push({ project: { id: anc.id, name: anc.name }, inherits: info.inherits, grants: info.grants });
		if (!info.inherits) break;
	}
	return out;
}

const principalOf = (g: ProjectGrant, fallback: string): Principal => ({ type: g.principalType, id: g.principalID, name: g.principalName?.trim() || fallback });

/** Direct grants first, then inherited ones; an inherited line is dropped when the same principal has a direct grant. */
export function accessRows(direct: ProjectGrant[], chain: AncestorGrants[], fallbackName: (g: ProjectGrant) => string): AccessRow[] {
	const rows: AccessRow[] = direct.map((g) => ({ key: `d:${g.id}`, principal: principalOf(g, fallbackName(g)), role: g.role, grantID: g.id }));
	const taken = new Set(rows.map((r) => `${r.principal.type}:${r.principal.id}`));
	for (const level of chain) {
		for (const g of level.grants ?? []) {
			const k = `${g.principalType}:${g.principalID}`;
			if (taken.has(k)) continue;
			taken.add(k);
			rows.push({ key: `i:${level.project.id}:${g.id}`, principal: principalOf(g, fallbackName(g)), role: g.role, inheritedFrom: level.project });
		}
	}
	return rows;
}

export interface WhoCanSee {
	userID: string;
	name: string;
	role: Role;
	/** Why the person has access, strongest source first (e.g. "Eigentümer", "Team Familie"). */
	via: string[];
}

/**
 * Effective role per person: owner (manage), person grants, team grants through accepted members; the highest role wins.
 * Team-owned projects give every member of the owning team at least read.
 */
export function whoCanSee(input: {
	owner?: { type: PrincipalType; id: string; name: string };
	rows: AccessRow[];
	teamMembers: Record<string, Pick<TeamMembership, 'userID' | 'displayName' | 'accepted'>[]>;
	labels: { owner: string; direct: string; team: (name: string) => string; inherited: (name: string) => string };
}): WhoCanSee[] {
	const people = new Map<string, WhoCanSee>();
	const add = (userID: string, name: string, role: Role, via: string) => {
		const cur = people.get(userID);
		if (!cur) return void people.set(userID, { userID, name, role, via: [via] });
		if (roleRank(role) > roleRank(cur.role)) cur.role = role;
		if (!cur.via.includes(via)) cur.via.push(via);
		if (!cur.name || cur.name === cur.userID) cur.name = name;
	};
	const { owner, rows, teamMembers, labels } = input;
	if (owner?.type === 'person') add(owner.id, owner.name, 'manage', labels.owner);
	if (owner?.type === 'team') for (const m of teamMembers[owner.id] ?? []) if (m.accepted) add(m.userID, m.displayName?.trim() || m.userID, 'read', labels.team(owner.name));
	for (const r of rows) {
		const via = r.inheritedFrom ? labels.inherited(r.inheritedFrom.name) : r.principal.type === 'team' ? labels.team(r.principal.name) : labels.direct;
		if (r.principal.type === 'person') add(r.principal.id, r.principal.name, r.role, via);
		else for (const m of teamMembers[r.principal.id] ?? []) if (m.accepted) add(m.userID, m.displayName?.trim() || m.userID, r.role, via);
	}
	return [...people.values()].sort((a, b) => roleRank(b.role) - roleRank(a.role) || a.name.localeCompare(b.name, 'de'));
}

export const initialsOf = (name: string): string =>
	name.split(/\s+/).filter(Boolean).slice(0, 2).map((s) => s[0]!.toUpperCase()).join('') || '?';

/** Deterministic hue so the same person always gets the same avatar colour. */
export function avatarHue(key: string): number {
	let h = 0;
	for (const c of key) h = (h * 31 + c.charCodeAt(0)) % 360;
	return h;
}

/** Pending/active people on the project page's share button: owner + grant principals (persons), deduplicated. */
export function participants(owner: { id: string; name: string } | undefined, rows: AccessRow[]): { id: string; name: string; team: boolean }[] {
	const out: { id: string; name: string; team: boolean }[] = [];
	const seen = new Set<string>();
	const push = (id: string, name: string, team: boolean) => {
		if (seen.has(id)) return;
		seen.add(id);
		out.push({ id, name, team });
	};
	if (owner) push(owner.id, owner.name, false);
	for (const r of rows) push(r.principal.id, r.principal.name, r.principal.type === 'team');
	return out;
}

export type { EffectiveVisibility };
