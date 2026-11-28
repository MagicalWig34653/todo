/** Pure rules of responsibility (ADR 0043, contracts/assignments.yaml). The server decides; this only mirrors it. */
import { hasRole } from './access.js';
import { ApiError, type Assignee, type ForMe, type Question, type Review, type Role, type Task } from './api.js';
import type { ForYouNeed } from './forYou.js';

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

/** Filter "Meine". `keep`: cards added while looking at the filtered view, so they do not vanish at once. */
export function mineOnly<T extends Pick<Task, 'id' | 'assigneeID'>>(tasks: readonly T[], meID: string | undefined, keep?: ReadonlySet<string>): T[] {
	return tasks.filter((t) => (!!meID && t.assigneeID === meID) || !!keep?.has(t.id));
}

export type Segment = 'mine' | 'all';
/** "Für mich" is preselected only when it has something to show. */
export const defaultSegment = (mine: number): Segment => (mine > 0 ? 'mine' : 'all');

const isMissing = (e: unknown) => e instanceof ApiError && e.status === 404;

/**
 * `GET /v1/for-me` beside the feed, so that its failure does not take the feed with it. `own`: the answer, `null` for a
 * server without the route, `undefined` when it failed this time (`failure`; whatever is shown stays).
 */
export async function settleForMe(request: Promise<ForMe>): Promise<{ own: ForMe | null | undefined; failure?: unknown }> {
	try {
		return { own: await request };
	} catch (failure) {
		return isMissing(failure) ? { own: null } : { own: undefined, failure };
	}
}

/** Waiting plans for "Für mich": feed entries that concern this account and belong to one of its own cards. */
export function minePlans(needs: readonly ForYouNeed[], mine: Pick<ForMe, 'tasks'> | null): ForYouNeed[] {
	if (!mine) return [];
	const own = new Set(mine.tasks.map((x) => x.id));
	return needs.filter((n) => n.kind === 'plan' && n.concernsMe === true && own.has(n.taskID));
}

/** Number of entries under "Für mich". */
export const forMeCount = (mine: ForMe | null, plans: readonly ForYouNeed[]): number =>
	mine ? mine.questions.length + mine.reviews.length + mine.tasks.length + plans.length : 0;

/** Largest page `GET /v1/questions` and `GET /v1/reviews` accept (newest first). */
export const MAX_LIST_LIMIT = 200;

export interface NeedResponsibility {
	kind: 'question' | 'review';
	id: string;
	assigneeID?: string | null;
	assigneeName?: string | null;
	runner: boolean;
}

/**
 * Who a question or review entry of the feed is for. The lists are capped at the newest entries while the feed shows old
 * ones first, so an entry they do not reach falls back to what the feed itself says. `null`: another kind, or an older
 * server that says nothing about responsibility.
 */
export function needResponsibility(need: ForYouNeed, question?: Question, review?: Review): NeedResponsibility | null {
	const kind = need.kind;
	if (kind !== 'question' && kind !== 'review') return null;
	const id = kind === 'question' ? need.questionID : need.reviewID;
	if (!id) return null;
	const listed =
		kind === 'question'
			? question && { assigneeID: question.assigneeID, assigneeName: question.assigneeName, runner: !!question.agentQuestionID }
			: review && { assigneeID: review.reviewerID, assigneeName: review.assigneeName, runner: !!review.agentJobID };
	if (listed) return { kind, id, ...listed, assigneeName: listed.assigneeName ?? need.assigneeName };
	if (need.concernsMe === undefined) return null;
	return { kind, id, assigneeID: need.assigneeID, assigneeName: need.assigneeName, runner: need.actor?.type === 'Run' };
}

/**
 * Is this a server without responsibility? A 404 of the people list alone also means "project missing or invisible", so
 * only a missing `/for-me` as well proves it.
 */
export async function lacksResponsibility(listError: unknown, probeForMe: () => Promise<unknown>): Promise<boolean> {
	if (!isMissing(listError)) return false;
	try {
		await probeForMe();
		return false;
	} catch (e) {
		return isMissing(e);
	}
}
