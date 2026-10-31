import type { AuthenticationPayload, CreationOptionsJSON, RegistrationPayload, RequestOptionsJSON } from './webauthn.js';
import type { ForYouPage } from './forYou.js';

export interface Capabilities {
	passkey: boolean;
	password: boolean;
	bootstrapOpen: boolean;
}
export interface User {
	id: string;
	displayName: string;
	isAdmin: boolean;
	username: string | null;
}
export interface Session {
	token: string;
	expiresAt: string;
	user: User;
}
export interface Project {
	id: string;
	parentID: string | null;
	name: string;
	version: number;
	/** contracts/openapi.yaml + project-state.yaml (ADR 0012); all optional because older servers omit them. */
	description?: string;
	/** `#RRGGBB`, uppercase; absent = derive a stable colour from the id. */
	color?: string;
	createdAt?: string;
	/** The viewer's own order among visible siblings; absent until the viewer reordered. */
	position?: number;
	isFavorite?: boolean;
	favoritePosition?: number;
}
export type TaskStatus = 'open' | 'in_progress' | 'in_review' | 'done';
/** Compact planning data that `GET /tasks` attaches to every list entry. */
export interface TaskPlanningSummary {
	dueAt?: string | null;
	plannedAt?: string | null;
	priority: number;
	position: number;
	hasRecurrence: boolean;
	reminderCount: number;
}
export interface Task {
	id: string;
	projectID: string;
	title: string;
	description: string;
	status: TaskStatus;
	version: number;
	/** Board column of the project (`null`/missing = no column) and 0-based position inside it. */
	columnID?: string | null;
	boardPosition?: number;
	/** Only present in task lists. */
	planning?: TaskPlanningSummary;
}
/** contracts/project-columns.yaml */
export interface ProjectColumn {
	id: string;
	projectID: string;
	name: string;
	color?: string | null;
	isDone: boolean;
	position: number;
	version: number;
}
export interface BoardColumn {
	/** `null` for the virtual status columns of a project without own columns. */
	id: string | null;
	key?: TaskStatus | null;
	name: string;
	color?: string | null;
	isDone: boolean;
	position: number;
	version?: number | null;
	tasks: Task[];
}
export interface BoardResponse {
	projectID: string;
	mode: 'status' | 'columns';
	columns: BoardColumn[];
	unassigned: Task[];
}
export type ProjectMode = 'classic' | 'management';
/** contracts/project-state.yaml */
export interface ProjectPrefs {
	projectID: string;
	view: 'list' | 'board';
	sort: 'manual' | 'title' | 'due' | 'priority';
	grouping: 'none' | 'column' | 'priority' | 'due';
	showCompleted: boolean;
	/** Per-account project view; absent on servers older than contracts/project-state 1.1 (treated as management). */
	mode?: ProjectMode;
	modeSource?: 'user' | 'default';
	isFavorite?: boolean;
	favoritePosition?: number;
	/** 0 while nothing was stored (the other fields are then defaults). */
	revision: number;
	updatedAt?: string;
}
export type ProjectPrefsChange = Partial<Pick<ProjectPrefs, 'view' | 'sort' | 'grouping' | 'showCompleted' | 'mode'>>;
export interface ProjectComment {
	id: string;
	projectID: string;
	authorID: string;
	authorName?: string | null;
	body: string;
	version: number;
	createdAt?: string;
}
export interface FeedItem {
	id: string;
	source: 'task' | 'project';
	projectID: string;
	projectName: string;
	taskID?: string | null;
	taskTitle?: string | null;
	sequence: number;
	actorType: 'Person' | 'Integration' | 'Run';
	actorID: string;
	actorName?: string | null;
	kind: string;
	subjectID?: string | null;
	createdAt?: string | null;
}
export interface FeedPage {
	items: FeedItem[];
	nextCursor?: string | null;
}
export interface RunnerBinding {
	id: string;
	projectID: string;
	deviceID: string;
	repositoryKey: string;
	label: string;
}
export interface RunnerDevice {
	id: string;
	label: string;
	paired: boolean;
	revokedAt?: string | null;
	activeRunCount: number;
	bindings: RunnerBinding[];
}
export type JobState =
	| 'queued'
	| 'claimed'
	| 'running'
	| 'waiting_for_answer'
	| 'awaiting_review'
	| 'succeeded'
	| 'failed'
	| 'cancelled';
export interface AgentJob {
	id: string;
	taskID: string;
	projectID: string;
	bindingID: string;
	mode: 'clarify' | 'implement';
	state: JobState;
	progress: string;
}
export interface JobListItem {
	job: AgentJob;
	taskTitle: string;
	projectName: string;
	createdAt?: string | null;
}
export interface JobPage {
	items: JobListItem[];
	nextCursor?: string | null;
}
export interface Pairing {
	deviceID: string;
	code: string;
	expiresAt: string;
}
export interface DirectoryUser {
	id: string;
	displayName: string;
}
export interface Milestone {
	id: string;
	projectID: string;
	title: string;
	dueAt?: string | null;
}
export interface MilestoneWithTasks {
	milestone: Milestone;
	tasks: Task[];
}

export type Role = 'read' | 'comment' | 'edit' | 'manage';
export type PrincipalType = 'person' | 'team';
export interface Team {
	id: string;
	name: string;
	founderID: string;
}
export interface TeamMembership {
	id: string;
	teamID: string;
	userID: string;
	isAdmin: boolean;
	accepted: boolean;
	/** Only in the invitation list. */
	teamName?: string | null;
	/** Only in the member list. */
	displayName?: string | null;
}
export interface ProjectGrant {
	id: string;
	projectID: string;
	principalType: PrincipalType;
	principalID: string;
	role: Role;
}
export interface EffectiveVisibility {
	projectID: string;
	role?: Role;
	canTransferOwnership: boolean;
	canDelete: boolean;
	canManageTeam: boolean;
	canStartAgent: boolean;
	inherits: boolean;
	userID: string;
}

export interface Recurrence {
	frequency: 'daily' | 'weekly' | 'monthly';
	interval: number;
	timeZone: string;
	until?: string | null;
}
export interface PlanningData {
	dueAt?: string | null;
	plannedAt?: string | null;
	priority: number;
	recurrence?: Recurrence | null;
	reminders: string[];
}
export interface PlanningTask extends PlanningData {
	task: Task;
	position: number;
}

export interface Label {
	id: string;
	name: string;
	version: number;
}
export interface Criteria {
	q?: string;
	projectID?: string;
	labelID?: string;
	status?: TaskStatus;
}
export interface SavedFilter {
	id: string;
	name: string;
	criteria: Criteria;
	version: number;
}
export interface SearchHit {
	kind: 'project' | 'task';
	id: string;
	project: Project;
	task?: Task;
}
export interface Page<T> {
	items: T[];
	nextCursor?: string | null;
}

export interface Comment {
	id: string;
	taskID: string;
	authorID: string;
	authorName?: string | null;
	body: string;
	version: number;
}
export interface Criterion {
	id: string;
	taskID: string;
	text: string;
	completed: boolean;
	version: number;
}
export interface Activity {
	id: string;
	sequence: number;
	actorType: 'Person' | 'Integration' | 'Run';
	actorID: string;
	actorName?: string | null;
	kind: string;
	subjectID?: string | null;
	createdAt?: string | null;
}

export type AttachmentRole = 'reference' | 'progress' | 'result';
export interface Attachment {
	id: string;
	taskID: string;
	filename: string;
	role: AttachmentRole;
	mediaType: string;
	size: number;
	checksum: string;
	status: 'complete';
}
export interface UploadCapability {
	attachmentID: string;
	uploadURL: string;
	token: string;
	expiresAt: string;
}

export interface Passkey {
	id: string;
	name: string;
	createdAt?: string;
	revokedAt?: string;
}
export interface Preferences {
	version: 1;
	appearance: {
		colorScheme: 'system' | 'light' | 'dark';
		accent: string;
		accentCustomHex?: string | null;
		glow: string;
	};
	/** Server-assigned; 0 while nothing was stored. */
	revision?: number;
	updatedAt?: string | null;
}

export interface SessionInfo {
	id: string;
	createdAt?: string;
	expiresAt: string;
	current: boolean;
}
export interface RecoveryToken {
	token: string;
	expiresAt: string;
}
/** Response of `GET /oauth/authorize` (contracts/oauth-mcp.yaml): what the client asks for. */
export interface ConsentRequest {
	consent_token: string;
	client_name: string;
	client_id: string;
	redirect_uri: string;
	scopes: string[];
	projects: Project[];
}
export interface OAuthGrant {
	id: string;
	client_id: string;
	scopes: string[];
	project_ids: string[];
	revoked: boolean;
}
export interface RegistrationBegin {
	challengeID: string;
	options: CreationOptionsJSON;
}

/** Error from the backend; `reason` is the machine-readable code (e.g. `version_conflict`). */
/** contracts/command-center.yaml (ADR 0014). Dates are ISO strings. */
export type LaneKey = 'running' | 'question' | 'review' | 'ready' | 'blocked' | 'done';
export type ActorType = 'Person' | 'Integration' | 'Run';
export interface Progress {
	percent: number;
	source: 'status' | 'subtasks' | 'criteria' | 'agent' | 'none';
	subtasksDone: number;
	subtasksTotal: number;
	criteriaDone: number;
	criteriaTotal: number;
}
export interface QuestionBrief {
	id: string;
	prompt: string;
	options: string[];
	blocking: boolean;
	askedByType: ActorType;
	askedByLabel?: string | null;
	createdAt?: string | null;
}
export interface ReviewBrief {
	id: string;
	summary: string;
	requestedByType: ActorType;
	requestedByLabel?: string | null;
	reviewerID?: string | null;
	agentJobID?: string | null;
	createdAt?: string | null;
}
export interface BuildArtifact {
	id: string;
	attachmentID: string;
	taskID: string;
	buildID: string;
	label?: string | null;
	platform?: string | null;
	filename: string;
	mediaType: string;
	size: number;
	/** Authenticated image endpoint (cookie), images only. */
	previewURL: string;
	createdAt?: string | null;
}
export interface CardAgent {
	claimedLabel?: string | null;
	claimedAt?: string | null;
	jobID?: string | null;
	jobState?: string | null;
	jobProgress?: string | null;
	runID?: string | null;
	checkpointNextStep?: string | null;
}
export interface CardUpdate {
	kind: 'note' | 'checkpoint' | 'job_progress';
	text: string;
	at?: string | null;
	actorLabel?: string | null;
}
export interface SubtaskBrief {
	id: string;
	title: string;
	status: TaskStatus;
	lane: string;
	progressPercent: number;
}
export interface CommandCard {
	task: { id: string; title: string; status: TaskStatus; version: number; columnID?: string | null; columnName?: string | null; createdAt?: string | null; updatedAt?: string | null };
	project: { id: string; name: string; color?: string | null; parentID?: string | null };
	kind: 'task' | 'feature';
	isFeature: boolean;
	parentTaskID?: string | null;
	lane: LaneKey;
	progress: Progress;
	agent?: CardAgent | null;
	openQuestionCount: number;
	questions: QuestionBrief[];
	pendingReview?: ReviewBrief | null;
	blockedReason?: string | null;
	blockedBy: string[];
	latestUpdate?: CardUpdate | null;
	builds: BuildArtifact[];
	buildCount: number;
	nextDue?: string | null;
	priority: number;
	subtasks: SubtaskBrief[];
}
export interface CommandLane {
	key: LaneKey;
	title: string;
	count: number;
	truncated: boolean;
	cards: CommandCard[];
}
export interface CommandSummary {
	running: number;
	question: number;
	review: number;
	ready: number;
	blocked: number;
	done: number;
	backlog: number;
	openQuestions: number;
	pendingReviews: number;
	features: number;
	activeAgents: number;
	/** Projects whose repository sync is stale (ADR 0018); absent on older servers. */
	staleProjects?: number;
}
/** contracts/project-sync.yaml */
export type SyncState = 'fresh' | 'stale' | 'never';
export interface SyncBrief {
	state: SyncState;
	lastSyncedAt?: string | null;
	daysSince?: number | null;
}
export interface ProjectSyncEntry {
	projectID: string;
	name: string;
	sync: SyncBrief;
}
export interface ProjectSync extends SyncBrief {
	bound: boolean;
	repository?: string | null;
	lastSyncedBy?: string | null;
	staleAfterDays: number;
	repoRef?: string | null;
	lastSummary?: string | null;
}
export interface UpdateItem {
	id: string;
	taskID: string;
	taskTitle: string;
	projectID: string;
	projectName: string;
	/** Activity kind such as `progress.posted`, `question.asked`, `review.requested`. */
	kind: string;
	actorType: ActorType;
	actorID: string;
	actorName?: string | null;
	subjectID?: string | null;
	text?: string | null;
	createdAt?: string | null;
}
export interface BuildGroup {
	buildID: string;
	label?: string | null;
	platform?: string | null;
	taskIDs: string[];
	createdAt?: string | null;
	items: BuildArtifact[];
}
export interface CommandCenter {
	generatedAt: string;
	scope: 'account' | 'project';
	projectID?: string | null;
	view: 'kanban' | 'list';
	summary: CommandSummary;
	lanes?: CommandLane[] | null;
	items?: CommandCard[] | null;
	total?: number | null;
	updates: UpdateItem[];
	builds: BuildGroup[];
	projects?: ProjectSyncEntry[] | null;
}
export interface CommandCenterParams {
	scope: 'account' | 'project';
	projectID?: string;
	view?: 'kanban' | 'list';
	includeSubprojects?: boolean;
	lane?: string;
	kind?: 'task' | 'feature';
	hasQuestion?: boolean;
	sort?: 'attention' | 'updated' | 'due' | 'progress' | 'title';
	includeSubtasks?: boolean;
	laneLimit?: number;
	updatesLimit?: number;
	limit?: number;
	offset?: number;
}
export interface Question {
	id: string;
	taskID: string;
	taskTitle?: string | null;
	projectID?: string | null;
	projectName?: string | null;
	askedByType: ActorType;
	askedByLabel?: string | null;
	askedByName?: string | null;
	prompt: string;
	options: string[];
	blocking: boolean;
	state: 'open' | 'answered' | 'withdrawn';
	answer?: string | null;
	answeredAt?: string | null;
	createdAt?: string | null;
	agentQuestionID?: string | null;
	version: number;
}
export interface Review {
	id: string;
	taskID: string;
	taskTitle?: string | null;
	projectID?: string | null;
	projectName?: string | null;
	state: 'pending' | 'accepted' | 'changes_requested' | 'withdrawn';
	requestedByType: ActorType;
	requestedByLabel?: string | null;
	reviewerID?: string | null;
	summary: string;
	decidedAt?: string | null;
	decisionNote?: string | null;
	createdAt?: string | null;
	version: number;
}
export interface AgentBrief {
	projectID: string;
	text: string;
	/** 0 = never written. */
	version: number;
	updatedAt?: string | null;
}
export interface ProgressNote {
	id: string;
	taskID: string;
	actorType: ActorType;
	actorLabel?: string | null;
	note: string;
	percent?: number | null;
	createdAt?: string | null;
}
export interface TaskContext {
	task: Task;
	projectID: string;
	workflow: { kind: string; isFeature: boolean; parentTaskID?: string | null; blockedReason?: string | null; claimedLabel?: string | null; claimedAt?: string | null };
	progress: Progress;
	progressNotes: ProgressNote[];
	subtasks: Task[];
	questions: Question[];
	review?: Review | null;
	builds: BuildArtifact[];
}
export interface ProjectStructure {
	project: { id: string; name: string };
	brief: AgentBrief;
	columnMode: 'columns' | 'status';
	template: { name: string; complete: boolean; missingRoles: string[] };
}

export class ApiError extends Error {
	constructor(
		readonly status: number,
		readonly reason?: string
	) {
		super(reason ?? `HTTP ${status}`);
	}
	get isConflict() {
		return this.status === 409 && this.reason === 'version_conflict';
	}
	get isRevisionConflict() {
		return this.status === 409 && this.reason === 'revision_conflict';
	}
	get isUnauthorized() {
		return this.status === 401;
	}
}

/** Builds `?a=b&...` from defined, non-empty values only; returns '' when nothing is set. */
export function query(params: Record<string, string | number | null | undefined>): string {
	const parts = Object.entries(params)
		.filter(([, v]) => v !== undefined && v !== null && v !== '')
		.map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`);
	return parts.length ? `?${parts.join('&')}` : '';
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export function createApi(fetchFn: FetchLike = (i, init) => fetch(i, init), base = '/v1') {
	/** `bearer` replaces the cookie session (recovery token); cookies are then not sent at all. */
	async function request<T>(
		method: string,
		path: string,
		body?: unknown,
		bearer?: string,
		extraHeaders?: Record<string, string>
	): Promise<T> {
		let response: Response;
		try {
			// OAuth endpoints live outside the versioned `/v1` namespace.
			response = await fetchFn(path.startsWith('/oauth/') ? path : base + path, {
				method,
				credentials: bearer ? 'omit' : 'same-origin',
				// The backend requires JSON for cookie-authenticated writes (CSRF protection).
				headers: {
					'Content-Type': 'application/json',
					Accept: 'application/json',
					...(bearer ? { Authorization: `Bearer ${bearer}` } : {}),
					...extraHeaders
				},
				body: body === undefined ? undefined : JSON.stringify(body)
			});
		} catch {
			throw new ApiError(0, 'network');
		}
		if (!response.ok) {
			let reason: string | undefined;
			try {
				reason = ((await response.json()) as { reason?: string }).reason;
			} catch {
				/* body is not JSON */
			}
			throw new ApiError(response.status, reason);
		}
		if (response.status === 204) return undefined as T;
		return (await response.json()) as T;
	}

	return {
		capabilities: () => request<Capabilities>('GET', '/capabilities'),
		me: () => request<User>('GET', '/me'),
		registerBegin: (token: string, displayName: string) =>
			request<{ challengeID: string; options: CreationOptionsJSON }>('POST', '/auth/register/begin', {
				token,
				displayName
			}),
		registerFinish: (challengeID: string, credential: RegistrationPayload, passkeyName?: string) =>
			request<Session>('POST', '/auth/register/finish', { challengeID, credential, passkeyName }),
		loginBegin: () =>
			request<{ challengeID: string; options: RequestOptionsJSON }>('POST', '/auth/login/begin', {}),
		loginFinish: (challengeID: string, credential: AuthenticationPayload) =>
			request<Session>('POST', '/auth/login/finish', { challengeID, credential }),
		passwordLogin: (username: string, password: string) =>
			request<Session>('POST', '/auth/password/login', { username, password }),
		logout: () => request<void>('POST', '/auth/logout', {}),

		listProjects: () => request<Project[]>('GET', '/projects'),
		createProject: (name: string, parentID?: string | null) =>
			request<Project>('POST', '/projects', { name, parentID: parentID ?? null }),
		renameProject: (p: Project, name: string) =>
			request<Project>('PATCH', `/projects/${p.id}`, { version: p.version, name }),
		moveProject: (p: Project, parentID: string | null) =>
			request<Project>(
				'PATCH',
				`/projects/${p.id}`,
				parentID === null ? { version: p.version, moveToRoot: true } : { version: p.version, parentID }
			),
		/** Partial update; `description: ''` / `color: ''` clear the value (contracts/openapi.yaml). */
		updateProject: (p: Project, changes: { name?: string; description?: string; color?: string }) =>
			request<Project>('PATCH', `/projects/${p.id}`, { version: p.version, ...changes }),
		deleteProject: (id: string) => request<void>('DELETE', `/projects/${id}`),
		/**
		 * Places a project among its siblings (ADR 0012). Without `parentID` this is the viewer's own order only;
		 * with `parentID` (`null` = top level) the shared tree changes: needs `manage` and the project version.
		 */
		putProjectPosition: (p: Project, index: number, parentID?: string | null) =>
			request<Project>(
				'PUT',
				`/projects/${p.id}/position`,
				parentID === undefined ? { index } : { index, parentID, version: p.version }
			),

		// Per-account project state (contracts/project-state.yaml)
		listFavorites: () => request<{ items: { projectID: string; position: number }[] }>('GET', '/me/favorites'),
		putFavorite: (projectID: string, index?: number) =>
			request<{ items: { projectID: string; position: number }[] }>(
				'PUT',
				`/me/favorites/${projectID}`,
				index === undefined ? undefined : { index }
			),
		deleteFavorite: (projectID: string) => request<void>('DELETE', `/me/favorites/${projectID}`),
		listProjectPrefs: (includeDefaults = false) =>
			request<{ items: ProjectPrefs[] }>('GET', includeDefaults ? '/me/project-prefs?includeDefaults=true' : '/me/project-prefs'),
		getProjectPrefs: (projectID: string) => request<ProjectPrefs>('GET', `/me/project-prefs/${projectID}`),
		patchProjectPrefs: (projectID: string, revision: number, changes: ProjectPrefsChange) =>
			request<ProjectPrefs>('PATCH', `/me/project-prefs/${projectID}`, { revision, ...changes }),
		listProjectComments: (projectID: string) => request<ProjectComment[]>('GET', `/projects/${projectID}/comments`),
		/** `idempotencyKey` makes a retry after a lost response safe (same key + same text returns the original). */
		createProjectComment: (projectID: string, body: string, idempotencyKey?: string) =>
			request<ProjectComment>(
				'POST',
				`/projects/${projectID}/comments`,
				{ body },
				undefined,
				idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : undefined
			),
		updateProjectComment: (c: ProjectComment, body: string) =>
			request<ProjectComment>('PATCH', `/projects/${c.projectID}/comments/${c.id}`, { body, version: c.version }),
		deleteProjectComment: (c: ProjectComment) =>
			request<void>('DELETE', `/projects/${c.projectID}/comments/${c.id}`, { version: c.version }),
		forYou: (params: { cursor?: string | null; limit?: number; projectID?: string; mode?: string } = {}) =>
			request<ForYouPage>('GET', `/feed${query(params)}`),
		performAction: (method: string, path: string, body: unknown) => request<unknown>(method, path, body),
		feed: (params: { projectID?: string; before?: string | null; limit?: number } = {}) =>
			request<FeedPage>('GET', `/activity${query({ projectID: params.projectID, before: params.before, limit: params.limit })}`),

		listTasks: (projectID?: string) => request<Task[]>('GET', `/tasks${query({ projectID })}`),
		createTask: (projectID: string, title: string, extra: { description?: string; columnID?: string | null } = {}) =>
			request<Task>('POST', '/tasks', { projectID, title, ...extra }),
		updateTask: (
			t: Task,
			changes: Partial<Pick<Task, 'title' | 'description' | 'status'>>
		) => request<Task>('PATCH', `/tasks/${t.id}`, { version: t.version, ...changes }),
		deleteTask: (id: string) => request<void>('DELETE', `/tasks/${id}`),

		// Project columns and board (contracts/project-columns.yaml)
		projectBoard: (projectID: string) => request<BoardResponse>('GET', `/projects/${projectID}/board`),
		createColumn: (projectID: string, body: { name: string; color?: string; isDone?: boolean; index?: number }) =>
			request<ProjectColumn>('POST', `/projects/${projectID}/columns`, body),
		applyColumnTemplate: (projectID: string, source: string) =>
			request<ProjectColumn[]>('POST', `/projects/${projectID}/columns/template`, { source }),
		updateColumn: (c: { id: string; projectID: string; version: number }, changes: { name?: string; color?: string; isDone?: boolean; index?: number }) =>
			request<ProjectColumn>('PATCH', `/projects/${c.projectID}/columns/${c.id}`, { version: c.version, ...changes }),
		deleteColumn: (c: { id: string; projectID: string; version: number }, moveTo?: string) =>
			request<void>('DELETE', `/projects/${c.projectID}/columns/${c.id}${query({ moveTo, version: c.version })}`),
		moveTaskToColumn: (t: Task, columnID: string | null, index?: number) =>
			request<Task>('PUT', `/tasks/${t.id}/column`, { version: t.version, columnID, ...(index === undefined ? {} : { index }) }),

		// Agents (contracts/agents.yaml)
		pairDevice: (label: string) => request<Pairing>('POST', '/agents/devices', { label }),
		listDevices: () => request<RunnerDevice[]>('GET', '/agents/devices'),
		revokeDevice: (id: string) => request<void>('DELETE', `/agents/devices/${id}`),
		createBinding: (b: { projectID: string; deviceID: string; repositoryKey: string; label: string }) =>
			request<RunnerBinding>('POST', '/agents/bindings', b),
		releaseJob: (j: { id: string; taskID: string; bindingID: string; taskRevision: number; mode: 'clarify' | 'implement'; scope: string }) =>
			request<AgentJob>('POST', '/agents/jobs', j),
		stopJob: (id: string) => request<AgentJob>('POST', `/agents/jobs/${id}/stop`, {}),
		listJobs: (params: { state?: JobState | ''; projectID?: string; before?: string | null; limit?: number } = {}) =>
			request<JobPage>(
				'GET',
				`/agents/jobs${query({ state: params.state, projectID: params.projectID, before: params.before, limit: params.limit })}`
			),

		// Planning (contracts/planning-ext.yaml)
		getPlanning: (taskID: string) => request<PlanningTask>('GET', `/planning/tasks/${taskID}`),
		putPlanning: (taskID: string, data: PlanningData) =>
			request<PlanningTask>('PUT', `/planning/tasks/${taskID}`, data),
		board: (projectID: string, status: TaskStatus) =>
			request<PlanningTask[]>('GET', `/planning/board${query({ projectID, status })}`),
		reorderBoard: (projectID: string, status: TaskStatus, taskIDs: string[]) =>
			request<void>('PUT', '/planning/board/reorder', { projectID, status, taskIDs }),
		today: (timeZone: string) => request<PlanningTask[]>('GET', `/planning/today${query({ timeZone })}`),
		upcoming: (timeZone: string) => request<PlanningTask[]>('GET', `/planning/upcoming${query({ timeZone })}`),
		upNext: (timeZone: string) => request<PlanningTask[]>('GET', `/planning/up-next${query({ timeZone })}`),
		dependencies: (taskID: string) => request<Task[]>('GET', `/planning/tasks/${taskID}/dependencies`),
		addDependency: (taskID: string, prerequisiteID: string) =>
			request<void>('PUT', `/planning/tasks/${taskID}/dependencies`, { prerequisiteID }),
		removeDependency: (taskID: string, prerequisiteID: string) =>
			request<void>('DELETE', `/planning/tasks/${taskID}/dependencies/${prerequisiteID}`),
		milestones: (projectID: string) =>
			request<MilestoneWithTasks[]>('GET', `/planning/milestones${query({ projectID })}`),
		createMilestone: (projectID: string, title: string, dueAt: string | null) =>
			request<Milestone>('POST', '/planning/milestones', { projectID, title, dueAt }),
		deleteMilestone: (id: string) => request<void>('DELETE', `/planning/milestones/${id}`),
		assignMilestoneTask: (milestoneID: string, taskID: string) =>
			request<void>('PUT', `/planning/milestones/${milestoneID}/tasks/${taskID}`),
		unassignMilestoneTask: (milestoneID: string, taskID: string) =>
			request<void>('DELETE', `/planning/milestones/${milestoneID}/tasks/${taskID}`),

		// Discovery (contracts/discovery.yaml)
		search: (criteria: Criteria, cursor?: string | null) =>
			request<Page<SearchHit>>('GET', `/search${query({ ...criteria, cursor })}`),
		listLabels: (cursor?: string | null) => request<Page<Label>>('GET', `/labels${query({ cursor, limit: 100 })}`),
		createLabel: (name: string) => request<Label>('POST', '/labels', { name }),
		renameLabel: (l: Label, name: string) => request<Label>('PATCH', `/labels/${l.id}`, { name, version: l.version }),
		deleteLabel: (id: string) => request<void>('DELETE', `/labels/${id}`),
		listFilters: (cursor?: string | null) =>
			request<Page<SavedFilter>>('GET', `/filters${query({ cursor, limit: 100 })}`),
		createFilter: (name: string, criteria: Criteria) => request<SavedFilter>('POST', '/filters', { name, criteria }),
		updateFilter: (f: SavedFilter, changes: { name?: string; criteria?: Criteria }) =>
			request<SavedFilter>('PATCH', `/filters/${f.id}`, {
				name: changes.name ?? f.name,
				criteria: changes.criteria ?? f.criteria,
				version: f.version
			}),
		deleteFilter: (id: string) => request<void>('DELETE', `/filters/${id}`),
		filterResults: (id: string, cursor?: string | null) =>
			request<Page<SearchHit>>('GET', `/filters/${id}/results${query({ cursor })}`),
		taskLabels: (taskID: string) => request<Page<Label>>('GET', `/tasks/${taskID}/labels${query({ limit: 100 })}`),
		addTaskLabel: (taskID: string, labelID: string) => request<void>('PUT', `/tasks/${taskID}/labels/${labelID}`),
		removeTaskLabel: (taskID: string, labelID: string) =>
			request<void>('DELETE', `/tasks/${taskID}/labels/${labelID}`),

		// Collaboration (contracts/collaboration.yaml)
		listComments: (taskID: string) => request<Comment[]>('GET', `/tasks/${taskID}/comments`),
		createComment: (taskID: string, body: string) => request<Comment>('POST', `/tasks/${taskID}/comments`, { body }),
		updateComment: (c: Comment, body: string) =>
			request<Comment>('PATCH', `/tasks/${c.taskID}/comments/${c.id}`, { body, version: c.version }),
		deleteComment: (c: Comment) =>
			request<void>('DELETE', `/tasks/${c.taskID}/comments/${c.id}`, { version: c.version }),
		listCriteria: (taskID: string) => request<Criterion[]>('GET', `/tasks/${taskID}/acceptance-criteria`),
		createCriterion: (taskID: string, text: string) =>
			request<Criterion>('POST', `/tasks/${taskID}/acceptance-criteria`, { text }),
		updateCriterion: (c: Criterion, changes: { text?: string; completed?: boolean }) =>
			request<Criterion>('PATCH', `/tasks/${c.taskID}/acceptance-criteria/${c.id}`, {
				...changes,
				version: c.version
			}),
		deleteCriterion: (c: Criterion) =>
			request<void>('DELETE', `/tasks/${c.taskID}/acceptance-criteria/${c.id}`, { version: c.version }),
		activity: (taskID: string, cursor?: string | null) =>
			request<Page<Activity>>('GET', `/tasks/${taskID}/activity${query({ cursor, limit: 100 })}`),

		// Sharing (contracts/sharing.yaml)
		/** Restricted directory: only people with an existing relation; `q` needs at least two characters. */
		searchUsers: (q: string) => request<DirectoryUser[]>('GET', `/users/search${query({ q, limit: 8 })}`),
		listTeams: () => request<Team[]>('GET', '/teams'),
		createTeam: (name: string) => request<Team>('POST', '/teams', { name }),
		teamInvitations: () => request<TeamMembership[]>('GET', '/team-invitations'),
		teamMembers: (teamID: string) => request<TeamMembership[]>('GET', `/teams/${teamID}/members`),
		putTeamMember: (teamID: string, userID: string, isAdmin: boolean) =>
			request<TeamMembership>('PUT', `/teams/${teamID}/members`, { userID, isAdmin }),
		removeTeamMember: (teamID: string, userID: string) =>
			request<void>('DELETE', `/teams/${teamID}/members/${userID}`),
		acceptTeam: (teamID: string) => request<void>('POST', `/teams/${teamID}/accept`, {}),
		listGrants: (projectID: string) => request<ProjectGrant[]>('GET', `/projects/${projectID}/grants`),
		putGrant: (projectID: string, principalType: PrincipalType, principalID: string, role: Role) =>
			request<ProjectGrant>('PUT', `/projects/${projectID}/grants`, { principalType, principalID, role }),
		deleteGrant: (projectID: string, grantID: string) =>
			request<void>('DELETE', `/projects/${projectID}/grants/${grantID}`),
		setInheritance: (p: Project, inherits: boolean) =>
			request<EffectiveVisibility>('PUT', `/projects/${p.id}/inheritance`, { version: p.version, inherits }),
		visibility: (projectID: string, userID?: string) =>
			request<EffectiveVisibility>('GET', `/projects/${projectID}/visibility${query({ userID })}`),

		// Attachments (contracts/attachments.yaml)
		listAttachments: (taskID: string) => request<Attachment[]>('GET', `/tasks/${taskID}/attachments`),
		beginAttachment: (input: Omit<Attachment, 'id' | 'status'>) =>
			request<UploadCapability>('POST', '/attachments/begin', input),
		/** The capability token replaces the session for this single PUT; cookies are not sent. */
		async uploadAttachment(cap: UploadCapability, data: Blob): Promise<void> {
			let response: Response;
			try {
				response = await fetchFn(cap.uploadURL, {
					method: 'PUT',
					credentials: 'omit',
					headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` },
					body: data
				});
			} catch {
				throw new ApiError(0, 'network');
			}
			if (!response.ok) throw new ApiError(response.status, `upload_${response.status}`);
		},
		completeAttachment: (id: string) => request<Attachment>('POST', `/attachments/${id}/complete`, {}),
		abortAttachment: (id: string) => request<void>('DELETE', `/attachments/${id}`),
		attachmentPreviewURL: (id: string) => `${base}/attachments/${id}/preview`,
		attachmentDownloadURL: (id: string) => `${base}/attachments/${id}/download`,

		// Repository sync (contracts/project-sync.yaml)
		getProjectSync: (projectID: string) => request<ProjectSync>('GET', `/projects/${projectID}/sync`),
		putProjectSync: (projectID: string, body: { repository?: string; staleAfterDays?: number }) =>
			request<ProjectSync>('PUT', `/projects/${projectID}/sync`, body),

		// Command center (contracts/command-center.yaml)
		commandCenter: (p: CommandCenterParams) =>
			request<CommandCenter>(
				'GET',
				`/command-center${query({
					scope: p.scope,
					projectID: p.projectID,
					view: p.view,
					includeSubprojects: p.includeSubprojects === undefined ? undefined : String(p.includeSubprojects),
					lane: p.lane,
					kind: p.kind,
					hasQuestion: p.hasQuestion === undefined ? undefined : String(p.hasQuestion),
					sort: p.sort,
					includeSubtasks: p.includeSubtasks === undefined ? undefined : String(p.includeSubtasks),
					laneLimit: p.laneLimit,
					updatesLimit: p.updatesLimit,
					limit: p.limit,
					offset: p.offset
				})}`
			),
		listQuestions: (p: { projectID?: string; state?: 'open' | 'answered' | 'all'; includeSubprojects?: boolean; limit?: number } = {}) =>
			request<Question[]>(
				'GET',
				`/questions${query({ projectID: p.projectID, state: p.state ?? 'open', includeSubprojects: p.includeSubprojects === undefined ? undefined : String(p.includeSubprojects), limit: p.limit })}`
			),
		answerQuestion: (id: string, answer: string) => request<Question>('POST', `/questions/${id}/answer`, { answer }),
		listReviews: (p: { projectID?: string; state?: Review['state'] | 'all'; limit?: number } = {}) =>
			request<Review[]>('GET', `/reviews${query({ projectID: p.projectID, state: p.state ?? 'pending', limit: p.limit })}`),
		decideReview: (taskID: string, decision: 'accept' | 'request_changes', note?: string) =>
			request<Review>('POST', `/tasks/${taskID}/review/decision`, { decision, note: note || undefined }),
		taskContext: (taskID: string) => request<TaskContext>('GET', `/tasks/${taskID}/context`),
		setTaskStructure: (taskID: string, body: { kind?: string; parentTaskID?: string | null }) => request<unknown>('PUT', `/tasks/${taskID}/structure`, body),
		projectStructure: (projectID: string) => request<ProjectStructure>('GET', `/projects/${projectID}/structure`),
		getAgentBrief: (projectID: string) => request<AgentBrief>('GET', `/projects/${projectID}/agent-brief`),
		putAgentBrief: (projectID: string, text: string, version: number) =>
			request<AgentBrief>('PUT', `/projects/${projectID}/agent-brief`, { text, version }),

		// Identity (contracts/identity.yaml)
		listPasskeys: () => request<Passkey[]>('GET', '/me/passkeys'),
		renamePasskey: (id: string, name: string) => request<void>('PATCH', `/me/passkeys/${id}`, { name }),
		revokePasskey: (id: string) => request<void>('DELETE', `/me/passkeys/${id}`),
		addPasskeyBegin: () => request<RegistrationBegin>('POST', '/me/passkeys/begin', {}),
		addPasskeyFinish: (challengeID: string, credential: RegistrationPayload, passkeyName?: string) =>
			request<void>('POST', '/me/passkeys/finish', { challengeID, credential, passkeyName }),
		getPreferences: () => request<Preferences>('GET', '/me/preferences'),
		putPreferences: (body: Preferences) => request<Preferences>('PUT', '/me/preferences', body),
		listSessions: () => request<SessionInfo[]>('GET', '/me/sessions'),
		revokeSession: (id: string) => request<void>('DELETE', `/me/sessions/${id}`),
		revokeOtherSessions: () => request<void>('POST', '/me/sessions/revoke-others', {}),
		/** Admin only: issues a one-time recovery code for an account (shown once, replaces older codes). */
		issueRecovery: (accountID: string) =>
			request<RecoveryToken>('POST', `/identity/accounts/${encodeURIComponent(accountID)}/recovery`, {}),
		redeemRecovery: (code: string) => request<RecoveryToken>('POST', '/identity/recovery/redeem', { code }),
		recoveryPasskeyBegin: (bearer: string) =>
			request<RegistrationBegin>('POST', '/identity/recovery/passkeys/begin', {}, bearer),
		recoveryPasskeyFinish: (bearer: string, challengeID: string, credential: RegistrationPayload, name?: string) =>
			request<void>(
				'POST',
				'/identity/recovery/passkeys/finish',
				{ challengeID, credential, passkeyName: name },
				bearer
			),

		// OAuth consent and grants (contracts/oauth-mcp.yaml)
		/** `search` is the raw query string of the authorization request, passed through unchanged. */
		oauthAuthorize: (search: string) => request<ConsentRequest>('GET', `/oauth/authorize${search}`),
		oauthConsent: (consentToken: string, approve: boolean, projectIDs: string[]) =>
			request<{ redirect_uri: string }>('POST', '/oauth/consent', {
				consent_token: consentToken,
				approve,
				project_ids: approve ? projectIDs : []
			}),
		listOAuthGrants: () => request<OAuthGrant[]>('GET', '/oauth/grants'),
		revokeOAuthGrant: (id: string) => request<void>('DELETE', `/oauth/grants/${id}`)
	};
}

export type Api = ReturnType<typeof createApi>;
export const api = createApi();
