import type { MessageKey } from './i18n/index.js';
import { splitLead } from './explainer.js';
import { previewText } from './previewText.js';

/** "Für dich" feed (backend ADR 0023, contracts/feed.yaml): types and pure helpers. */
export interface ForYouActor {
	type: 'Person' | 'Integration' | 'Run';
	id: string;
	name?: string | null;
}
export interface ForYouImage {
	attachmentID: string;
	buildArtifactID?: string | null;
	filename: string;
	mediaType: string;
	previewURL: string;
	buildID?: string | null;
	label?: string | null;
	platform?: string | null;
}
export interface ForYouPost {
	id: string;
	kind: 'progress' | 'build' | 'done' | 'review' | 'question' | 'comment' | 'agent_run' | 'plan' | string;
	event: string;
	state?: string | null;
	projectID: string;
	projectName: string;
	taskID: string;
	taskTitle: string;
	actor: ForYouActor;
	text?: string | null;
	detail?: string | null;
	percent?: number | null;
	images: ForYouImage[];
	createdAt?: string | null;
	/** build.status_changed (and build.added with a reported status), feed contract 1.1.0. */
	status?: string | null;
	platform?: string | null;
}
export interface ForYouAction {
	key: string;
	label: string;
	method: string;
	path: string;
	body?: { answer?: string; decision?: string; note?: string; comment?: string; status?: string; version?: number } | null;
	requiresInput: boolean;
	inputField?: string | null;
}
export interface ForYouNeed {
	id: string;
	kind: 'question' | 'review' | 'plan' | 'blocked' | 'overdue' | 'due' | string;
	projectID: string;
	projectName: string;
	taskID: string;
	taskTitle: string;
	taskVersion: number;
	title: string;
	detail?: string | null;
	options: string[];
	blocking: boolean;
	questionID?: string | null;
	reviewID?: string | null;
	dueAt?: string | null;
	actor?: ForYouActor | null;
	createdAt?: string | null;
	actions: ForYouAction[];
	/** Responsibility (feed contract, additive): absent on older servers. */
	concernsMe?: boolean;
	assigneeID?: string | null;
	assigneeName?: string | null;
}
/** Confirmation request of an agent (backend ADR 0026, contracts/action-requests.yaml). */
export interface ActionImpact {
	targetType: 'project' | 'task' | string;
	targetID: string;
	targetName: string;
	subprojects: number;
	tasks: number;
	newOwnerName?: string | null;
	destructive: boolean;
}
export interface ActionRequest {
	id: string;
	tool: 'delete_project' | 'delete_task' | 'transfer_project_owner' | string;
	state: 'pending' | 'confirmed' | 'rejected' | 'expired' | 'executed' | 'failed';
	summary: string;
	impact: ActionImpact;
	agentLabel?: string | null;
	result?: { ok: boolean; code: string } | null;
	createdAt?: string | null;
	decidedAt?: string | null;
	executedAt?: string | null;
	expiresAt: string;
}
/** Feed card of a pending request; same fields as the request plus the paths the card posts to. */
export interface ForYouConfirmation {
	id: string;
	tool: string;
	summary: string;
	impact: ActionImpact;
	agentLabel?: string | null;
	createdAt?: string | null;
	expiresAt: string;
	confirmPath: string;
	rejectPath: string;
}

/** Second step before confirming: deleting a project asks for its name, everything else for a tick. */
export function confirmGate(c: Pick<ForYouConfirmation, 'tool' | 'impact'>): 'name' | 'check' {
	return c.tool === 'delete_project' ? 'name' : 'check';
}
/** The typed text must equal the name (surrounding blanks are ignored, case counts). */
export function nameMatches(typed: string, name: string): boolean {
	return typed.trim() === name.trim() && name.trim() !== '';
}
/** i18n key of the outcome line of a decided request. */
export function outcomeKey(r: Pick<ActionRequest, 'tool' | 'state' | 'result'>): string {
	if (r.state === 'rejected') return 'confirm.done.rejected';
	if (r.state === 'expired') return 'confirm.done.expired';
	if (r.state === 'failed') return 'confirm.done.failed';
	if (r.state === 'executed') {
		return ({ delete_project: 'confirm.done.projectDeleted', delete_task: 'confirm.done.taskDeleted', transfer_project_owner: 'confirm.done.ownerChanged' } as Record<string, string>)[r.tool] ?? 'confirm.done.executed';
	}
	return 'confirm.done.executed';
}
/** i18n key of a failure reason (`result.code`); unknown codes fall back to a generic text. */
export function failureKey(code: string | undefined): string {
	return ({ forbidden: 'confirm.fail.forbidden', not_found: 'confirm.fail.notFound', version_conflict: 'confirm.fail.conflict', connection_revoked: 'confirm.fail.revoked' } as Record<string, string>)[code ?? ''] ?? 'confirm.fail.other';
}

export interface ForYouPage {
	generatedAt: string;
	mode: string;
	projectID?: string | null;
	needsYou: ForYouNeed[];
	needsYouTotal: number;
	/** Open confirmation requests of agents; absent on older servers. */
	confirmations?: ForYouConfirmation[];
	/** Connections that asked for a project outside their grant (ADR 0028); absent on older servers. */
	accessRequests?: ForYouAccessRequest[];
	posts: ForYouPost[];
	nextCursor?: string | null;
}

/** Request of an action exactly as the server described it; the user's text goes into `inputField`. Null when the input is required but empty. */
export function actionRequest(action: ForYouAction, input = ''): { method: string; path: string; body: Record<string, unknown> } | null {
	const body: Record<string, unknown> = { ...(action.body ?? {}) };
	const text = input.trim();
	if (action.requiresInput) {
		// An answer and the comment of a plan change are mandatory; the note of a review is optional.
		if ((action.inputField === 'answer' || action.inputField === 'comment') && !text) return null;
		if (action.inputField && text) body[action.inputField] = text;
	}
	return { method: action.method, path: action.path.replace(/^\/v1/, ''), body };
}

/** What an action asks the person to type: a free answer, a note (optional) or a comment (mandatory); null when nothing. */
export type NeedInputKind = 'answer' | 'note' | 'comment';
export function needInputKind(action: Pick<ForYouAction, 'requiresInput' | 'inputField'>): NeedInputKind | null {
	if (!action.requiresInput) return null;
	return action.inputField === 'answer' || action.inputField === 'note' || action.inputField === 'comment' ? action.inputField : null;
}

/** The detail line of an entry as plain text: the first line of a plan is often a Markdown heading, shown without its `#` marks. */
const LEAD_MAX = 140;

/**
 * Short preview of an agent text on "Für dich" (UX step 1): plain text without Markdown marks, split into a headline (a
 * leading heading, the first sentence or the text before the first list item, at most 140 characters) and the rest. The
 * card window renders the original.
 */
export function previewParts(source: string): { lead: string; rest: string } {
	const text = previewText(source);
	const sentence = splitLead(text);
	const bullet = text.indexOf(' · ');
	let { lead, rest } = bullet > 0 && bullet < sentence.lead.length ? { lead: text.slice(0, bullet), rest: text.slice(bullet + 3) } : sentence;
	rest = rest.replace(/^·\s*/, '');
	if (lead.length > LEAD_MAX) {
		const space = lead.lastIndexOf(' ', LEAD_MAX - 1);
		const at = space > LEAD_MAX / 2 ? space : LEAD_MAX - 1;
		rest = `${lead.slice(at).trim()} ${rest}`.trim();
		lead = `${lead.slice(0, at).trimEnd()}…`;
	}
	return { lead, rest };
}

export function needDetailText(n: Pick<ForYouNeed, 'kind' | 'detail'>): string {
	const detail = n.detail ?? '';
	return n.kind === 'plan' ? detail.replace(/^\s{0,3}#{1,6}\s+/, '') : detail;
}

/** i18n key of the label above a needs-you entry; unknown kinds of a newer server get a neutral one instead of nothing. */
export function needKindKey(kind: string): MessageKey {
	return (['question', 'review', 'plan', 'blocked', 'overdue', 'due'] as readonly string[]).includes(kind) ? (`forYou.kind.${kind}` as MessageKey) : 'forYou.kind.other';
}

/**
 * Merges a freshly fetched first page into the loaded feed without losing older pages loaded by scrolling:
 * fresh posts come first (new ones inserted at the front), already loaded posts the page does not contain stay.
 * `keepCursor` is true when older posts survived, so the cursor of the loaded pages must be kept.
 */
export function mergeFirstPage(current: readonly ForYouPost[], fresh: readonly ForYouPost[]): { posts: ForYouPost[]; keepCursor: boolean } {
	const ids = new Set(fresh.map((p) => p.id));
	const oldest = fresh.length > 0 ? fresh[fresh.length - 1].createdAt ?? null : null;
	// Loaded posts missing from the page: older than the page's last post they are simply further down the feed; otherwise deleted.
	const rest = current.filter((p) => !ids.has(p.id) && oldest !== null && p.createdAt != null && p.createdAt <= oldest);
	return { posts: [...fresh, ...rest], keepCursor: rest.length > 0 };
}

/** Appends a later page; posts already known (same id) are dropped. */
export function appendPosts(posts: readonly ForYouPost[], more: readonly ForYouPost[]): ForYouPost[] {
	const known = new Set(posts.map((p) => p.id));
	return [...posts, ...more.filter((p) => !known.has(p.id))];
}

/** i18n key of a post's headline. */
export function postTitleKey(p: Pick<ForYouPost, 'kind' | 'state'> & { event?: string }): string {
	switch (p.kind) {
		case 'progress': return 'forYou.post.progress';
		case 'build': return p.event === 'build.status_changed' ? 'forYou.post.buildStatus' : 'forYou.post.build';
		case 'done': return 'forYou.post.done';
		case 'review': return p.state === 'accepted' ? 'forYou.post.reviewAccepted' : 'forYou.post.reviewChanges';
		case 'question': return 'forYou.post.answered';
		case 'comment': return 'forYou.post.comment';
		case 'plan':
			return ({ 'plan.written': 'forYou.post.planWritten', 'plan.approved': 'forYou.post.planApproved', 'plan.changes_requested': 'forYou.post.planChanges' } as Record<string, string>)[p.event ?? ''] ?? 'forYou.post.plan';
		case 'agent_run':
			return ({ started: 'forYou.post.runStarted', failed: 'forYou.post.runFailed', stopped: 'forYou.post.runStopped' } as Record<string, string>)[p.state ?? ''] ?? 'forYou.post.runFinished';
		default: return 'forYou.post.other';
	}
}

/** Notice "<connection> wanted to reach <project>" (ADR 0028). The connection's access never exceeds `role`, the person's own role. */
export interface ForYouAccessRequest {
	id: string;
	grantID: string;
	connectionName: string;
	projectID: string;
	projectName: string;
	role: 'read' | 'comment' | 'edit' | 'manage';
	count: number;
	firstAt: string;
	lastAt: string;
	allowPath: string;
	ignorePath: string;
}
