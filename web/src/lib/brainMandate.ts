/** Brain mandate (ADR 0032 and addendum 23.11.2026, cards 11DA4A38 and 2280A2F1): types of `/v1/settings/brain-mandate` and the pure rules of the settings page. One mandate per connection. No DOM. */

import { ApiError, type OAuthGrant, type Project } from './api.js';
import type { MessageKey } from './i18n/index.js';
import { connectionName } from './oauth.js';
import type { SelectionDTO } from './projectGroups.js';

/** `BrainMandateDTO` (contracts/connections.yaml 1.1.0). `active` is false after a revocation and when the grant itself was revoked. */
export interface BrainMandate {
	grantID: string;
	grantName: string | null;
	projectIDs: string[];
	active: boolean;
	createdAt: string;
	updatedAt: string;
	revokedAt: string | null;
	lastUsedAt: string | null;
	/** ADR 0036: why the connection was revoked; absent when it is alive or the cause is unknown. */
	grantRevokedReason?: string | null;
	/** ADR 0036: this connection took the mandate over from an earlier one after a new sign-in. */
	takenOver?: { fromGrantID: string; fromName: string; at: string } | null;
	/** ADR 0037: the rule (groups, "all except"); null/absent = only the explicit projects. `projectIDs` is what it covers now. */
	selection?: SelectionDTO | null;
	explicitProjectIDs?: string[];
}

/** One row of `GET /v1/settings/brain-mandate/audit`. */
export interface BrainAuditItem {
	id: string;
	kind: string;
	/** Absent for `connection.*` entries (no card involved). */
	taskID?: string | null;
	projectID: string;
	/** Review or question id; for `connection.*` the id of the connection whose projects changed. */
	subjectID: string;
	grantID: string;
	quote: string;
	note?: string | null;
	createdAt: string;
}

/** Server ceiling of projects in one mandate (`invalid_projects` above). */
export const MAX_PROJECTS = 200;

/** `recoverable`: signed out by replay detection, a new sign-in may take it over. `superseded`: a new sign-in did. */
export type MandateStatus = 'active' | 'revoked' | 'grant_revoked' | 'recoverable' | 'superseded';

/** Revoked by the person, or void because the connection itself was revoked (the backend reports both as `active: false`). */
export function mandateStatus(m: BrainMandate): MandateStatus {
	if (m.grantRevokedReason === 'superseded') return 'superseded';
	if (m.revokedAt) return 'revoked';
	if (m.active) return 'active';
	return m.grantRevokedReason === 'replay' ? 'recoverable' : 'grant_revoked';
}

/** The list of the settings page: mandates that moved to a newer connection stay only in the protocol. */
export const listedMandates = (mandates: readonly BrainMandate[]) => mandates.filter((m) => mandateStatus(m) !== 'superseded');

/** Protocol entries of a takeover: their `quote` is a note of the server, `subjectID` the earlier connection. */
export const isTakeover = (kind: string) => kind === 'mandate.taken_over' || kind === 'connection.taken_over';

/** ADR 0037: a group change that moved the reach of a mandate; the `quote` is a note of the server. */
export const isGroupChange = (kind: string) => kind === 'mandate.group_added' || kind === 'mandate.group_removed';

const key = (id: string) => id.toLowerCase();
const sameID = (a: string, b: string) => key(a) === key(b);

/** Display label per project (lower-case id): the parent path makes equal names distinguishable. Safe against cycles and missing parents. */
export function projectLabels(projects: readonly Project[]): Map<string, string> {
	const byID = new Map(projects.map((p) => [key(p.id), p]));
	const labels = new Map<string, string>();
	for (const p of projects) {
		const parts = [p.name];
		const seen = new Set([key(p.id)]);
		let parent = p.parentID ? byID.get(key(p.parentID)) : undefined;
		while (parent && !seen.has(key(parent.id))) {
			seen.add(key(parent.id));
			parts.unshift(parent.name);
			parent = parent.parentID ? byID.get(key(parent.parentID)) : undefined;
		}
		labels.set(key(p.id), parts.join(' › '));
	}
	return labels;
}

export interface ScopeProject {
	/** Id as the mandate stored it. */
	id: string;
	/** Project name (with parent path), or a short id for a project the person cannot read any more. */
	label: string;
	accessible: boolean;
}

const byLabel = (a: ScopeProject, b: ScopeProject) => Number(b.accessible) - Number(a.accessible) || a.label.localeCompare(b.label, 'de');

/** Names for the ids of a mandate; unreadable ones are marked and come last. */
export function resolveScope(ids: readonly string[], projects: readonly Project[]): ScopeProject[] {
	const labels = projectLabels(projects);
	return ids
		.map((id): ScopeProject => {
			const label = labels.get(key(id));
			return label === undefined ? { id, label: key(id).slice(0, 8), accessible: false } : { id, label, accessible: true };
		})
		.sort(byLabel);
}

const nameOf = (g: OAuthGrant) => connectionName(g);

/** The person's own connections that may receive the mandate: not revoked, sorted by name. */
export function eligibleGrants(grants: readonly OAuthGrant[]): OAuthGrant[] {
	return grants.filter((g) => !g.revoked).sort((a, b) => nameOf(a).localeCompare(nameOf(b), 'de'));
}

/** Projects matching all words of the query in their label (parent path included), sorted by label. */
export function filterProjects(projects: readonly Project[], query: string): Project[] {
	const labels = projectLabels(projects);
	const label = (p: Project) => labels.get(key(p.id)) ?? p.name;
	const words = query.toLowerCase().split(/\s+/).filter(Boolean);
	return projects
		.filter((p) => words.every((w) => label(p).toLowerCase().includes(w)))
		.sort((a, b) => label(a).localeCompare(label(b), 'de'));
}

/** Adds or removes one project; the 201st is refused, removing always works. */
export function toggleProject(sel: ReadonlySet<string>, id: string): Set<string> {
	const next = new Set(sel);
	if (next.has(id)) next.delete(id);
	else if (next.size < MAX_PROJECTS) next.add(id);
	return next;
}

export type SelectionProblem = 'grant_required' | 'projects_required' | 'too_many';

/** A mandate needs one connection and 1 to 200 explicitly chosen projects (there is no "all"). */
export function selectionProblem(grantID: string, selected: ReadonlySet<string>): SelectionProblem | null {
	if (!grantID) return 'grant_required';
	if (selected.size === 0) return 'projects_required';
	if (selected.size > MAX_PROJECTS) return 'too_many';
	return null;
}

export interface MandateScope {
	grantID: string;
	projectIDs: readonly string[];
}

export interface MandateDiff {
	grantChanged: boolean;
	added: ScopeProject[];
	removed: ScopeProject[];
	kept: ScopeProject[];
	changed: boolean;
}

/** What replacing `before` by `after` changes: connection, added, removed and kept projects (ids compared case-insensitively). */
export function diffMandate(before: MandateScope, after: MandateScope, projects: readonly Project[]): MandateDiff {
	const was = new Set(before.projectIDs.map(key));
	const will = new Set(after.projectIDs.map(key));
	const added = resolveScope(after.projectIDs.filter((id) => !was.has(key(id))), projects);
	const removed = resolveScope(before.projectIDs.filter((id) => !will.has(key(id))), projects);
	const kept = resolveScope(after.projectIDs.filter((id) => was.has(key(id))), projects);
	const grantChanged = !sameID(before.grantID, after.grantID);
	return { grantChanged, added, removed, kept, changed: grantChanged || added.length > 0 || removed.length > 0 };
}

/** The mandate of one connection (ids compared case-insensitively), or `undefined`: every connection has its own. */
export function mandateFor(mandates: readonly BrainMandate[], grantID: string): BrainMandate | undefined {
	return mandates.find((m) => sameID(m.grantID, grantID));
}

/**
 * How a save goes for the chosen connection's own mandate: `first` (none yet, or one that gives nobody power: revoked or
 * void) is a plain save with a summary; `replace` (an active mandate gets other projects) needs the confirmation diff,
 * because rights are taken away; `unchanged` has nothing to save. Other connections' mandates are never touched.
 */
export type SaveKind = 'first' | 'replace' | 'unchanged';

export function saveKind(current: BrainMandate | null | undefined, next: MandateScope): SaveKind {
	if (!current || mandateStatus(current) !== 'active') return 'first';
	return diffMandate(current, next, []).changed ? 'replace' : 'unchanged';
}

/**
 * Starting projects of the form for the chosen connection: nothing preselected without an active mandate of that connection;
 * with one, the projects the person can still read (as the ids of the project list, so picker and PUT use the same ids).
 */
export function prefillProjects(mandate: BrainMandate | null | undefined, projects: readonly Project[]): string[] {
	if (!mandate || mandateStatus(mandate) !== 'active') return [];
	// ADR 0037: with a rule the form starts from the explicitly named projects, not from what the rule covers.
	const inMandate = new Set((mandate.selection?.projectIDs ?? mandate.projectIDs).map(key));
	return projects.filter((p) => inMandate.has(key(p.id))).map((p) => p.id);
}

/** Message key for the documented answers of the mandate endpoints; `null` = use the generic error mapping. */
export function mandateErrorKey(e: unknown): MessageKey | null {
	if (!(e instanceof ApiError)) return null;
	if (e.status === 401) return 'brainMandate.error.session';
	if (e.status === 400 && e.reason === 'invalid_projects') return 'brainMandate.error.invalidProjects';
	if (e.status === 404) return 'brainMandate.error.notFound';
	if (e.status === 409 && e.reason === 'grant_revoked') return 'brainMandate.error.grantRevoked';
	return null;
}

export function auditKindKey(kind: string): MessageKey {
	switch (kind) {
		case 'review.accepted':
			return 'brainMandate.audit.kind.accepted';
		case 'review.changes_requested':
			return 'brainMandate.audit.kind.changes';
		case 'question.answered':
			return 'brainMandate.audit.kind.answered';
		case 'plan.approved':
			return 'brainMandate.audit.kind.planApproved';
		case 'plan.changes_requested':
			return 'brainMandate.audit.kind.planChanges';
		case 'connection.project_added':
			return 'brainMandate.audit.kind.projectAdded';
		case 'connection.project_removed':
			return 'brainMandate.audit.kind.projectRemoved';
		case 'mandate.group_added':
			return 'brainMandate.audit.kind.groupAdded';
		case 'mandate.group_removed':
			return 'brainMandate.audit.kind.groupRemoved';
		case 'mandate.taken_over':
			return 'brainMandate.audit.kind.takenOver';
		case 'connection.taken_over':
			return 'brainMandate.audit.kind.accessTakenOver';
		default:
			return 'brainMandate.audit.kind.other';
	}
}

/** `?card=` value that opens the card of an audit entry. */
export const auditCardParam = (taskID: string) => `task:${taskID}`;
