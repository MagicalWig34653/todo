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
	kind: 'progress' | 'build' | 'done' | 'review' | 'question' | 'comment' | 'agent_run' | string;
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
}
export interface ForYouAction {
	key: string;
	label: string;
	method: string;
	path: string;
	body?: { answer?: string; decision?: string; note?: string; status?: string; version?: number } | null;
	requiresInput: boolean;
	inputField?: string | null;
}
export interface ForYouNeed {
	id: string;
	kind: 'question' | 'review' | 'blocked' | 'overdue' | 'due' | string;
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
}
export interface ForYouPage {
	generatedAt: string;
	mode: string;
	projectID?: string | null;
	needsYou: ForYouNeed[];
	needsYouTotal: number;
	posts: ForYouPost[];
	nextCursor?: string | null;
}

/** Request of an action exactly as the server described it; the user's text goes into `inputField`. Null when the input is required but empty. */
export function actionRequest(action: ForYouAction, input = ''): { method: string; path: string; body: Record<string, unknown> } | null {
	const body: Record<string, unknown> = { ...(action.body ?? {}) };
	const text = input.trim();
	if (action.requiresInput) {
		if (action.inputField === 'answer' && !text) return null;
		if (action.inputField && text) body[action.inputField] = text;
	}
	return { method: action.method, path: action.path.replace(/^\/v1/, ''), body };
}

/** Appends a later page; posts already known (same id) are dropped. */
export function appendPosts(posts: readonly ForYouPost[], more: readonly ForYouPost[]): ForYouPost[] {
	const known = new Set(posts.map((p) => p.id));
	return [...posts, ...more.filter((p) => !known.has(p.id))];
}

/** i18n key of a post's headline. */
export function postTitleKey(p: Pick<ForYouPost, 'kind' | 'state'>): string {
	switch (p.kind) {
		case 'progress': return 'forYou.post.progress';
		case 'build': return 'forYou.post.build';
		case 'done': return 'forYou.post.done';
		case 'review': return p.state === 'accepted' ? 'forYou.post.reviewAccepted' : 'forYou.post.reviewChanges';
		case 'question': return 'forYou.post.answered';
		case 'comment': return 'forYou.post.comment';
		case 'agent_run':
			return ({ started: 'forYou.post.runStarted', failed: 'forYou.post.runFailed', stopped: 'forYou.post.runStopped' } as Record<string, string>)[p.state ?? ''] ?? 'forYou.post.runFinished';
		default: return 'forYou.post.other';
	}
}
