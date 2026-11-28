/** Pure rules of responsibility (ADR 0043, contracts/assignments.yaml). The server decides; this only mirrors it. */
import { hasRole } from './access.js';
import type { Assignee, Role, Task } from './api.js';

export type AssignmentKind = Assignee['assignableTo'][number];

/**
 * Name of a responsible person: what the server sent, else the list of assignable people (only readable with edit), else
 * the own name. `null` = nobody, or a person this account cannot name (the caller picks the neutral label).
 */
export function responsibleName(
	id: string | null | undefined,
	serverName: string | null | undefined,
	people: readonly Pick<Assignee, 'userID' | 'displayName'>[] = [],
	me?: { id: string; displayName: string } | null
): string | null {
	if (!id) return null;
	return serverName?.trim() || people.find((p) => p.userID === id)?.displayName || (me?.id === id ? me.displayName : null);
}

export function candidatesFor<T extends { assignableTo: readonly AssignmentKind[] }>(people: readonly T[], kind: AssignmentKind): T[] {
	return people.filter((p) => p.assignableTo.includes(kind));
}

/** A named review (`reviewerID`) is decided by that person or the project management only (`not_the_reviewer`). */
export function mayDecideReview(reviewerID: string | null | undefined, meID: string | undefined, role: Role): boolean {
	return !reviewerID || reviewerID === meID || role === 'manage';
}

/** Questions are handed over with edit; questions of local runner jobs never. */
export function mayHandOverQuestion(role: Role, runner = false): boolean {
	return !runner && hasRole(role, 'edit');
}

export function mayHandOverReview(r: { reviewerID?: string | null; meID?: string; role: Role; runner?: boolean }): boolean {
	return !r.runner && hasRole(r.role, 'edit') && mayDecideReview(r.reviewerID, r.meID, r.role);
}

/** Filter "Meine". */
export function mineOnly<T extends Pick<Task, 'assigneeID'>>(tasks: readonly T[], meID: string | undefined): T[] {
	return meID ? tasks.filter((t) => t.assigneeID === meID) : [];
}

export type Segment = 'mine' | 'all';
/** "Für mich" is preselected only when it has something to show. */
export const defaultSegment = (mine: number): Segment => (mine > 0 ? 'mine' : 'all');
