import type { AuthenticationPayload, CreationOptionsJSON, RegistrationPayload, RequestOptionsJSON } from './webauthn.js';
import type { ChannelMessagePage } from './brainChannel.js';
import type { ActionRequest, ForYouPage } from './forYou.js';
import type { BatchResponse } from './reviewBulk.js';
import type { ReviewVariant } from './reviewVariants.js';
import type { BrainAuditItem, BrainMandate } from './brainMandate.js';
import type { PipelineStepName, PlanDecisionInput, RetryInput, TaskPipeline } from './pipeline.js';
import type { PipelineSettings, SettingsPatch } from './pipelineSettings.js';
import type { ContinueInput, StartInput } from './pipelineExecution.js';
import type { UpdateWebhook, WebhookDelivery, WebhookSettings } from './webhook.js';

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
	/** The viewer's effective role, ownership and the owner (contracts/openapi.yaml, sharing.yaml); older servers omit them. */
	role?: Role;
	isOwner?: boolean;
	ownerType?: PrincipalType;
	ownerID?: string;
	ownerName?: string;
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
	createdAt?: string | null;
	updatedAt?: string | null;
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
	/** Only with `listTasks(projectID, true)`: names of the caller's own labels. */
	labels?: string[];
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
export interface JobDetail {
	job: AgentJob;
	events: { id?: string; kind: string; detail: string; createdAt?: string | null }[];
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

/** contracts/planning-ext.yaml: GET /planning/dependencies */
export interface TaskGraphData {
	edges: { taskID: string; prerequisiteID: string }[];
	tasks: {
		taskID: string;
		kind: 'task' | 'feature';
		parentTaskID?: string | null;
		createdAt?: string | null;
		updatedAt?: string | null;
		claimedLabel?: string | null;
		/** Only with `details=true`. */
		title?: string;
		status?: TaskStatus;
		projectID?: string;
		dueAt?: string | null;
		/** Only with `details=true`, only for tasks with builds: grouped by build id, newest first. */
		builds?: { buildID: string; label?: string | null; platform?: string | null; count: number; createdAt?: string | null }[];
	}[];
	/** Only with `details=true`: milestones of the project with their visible members. */
	milestones?: { id: string; title: string; dueAt?: string | null; tasks: { taskID: string; status: TaskStatus }[] }[];
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
	/** Display name of the person or name of the team. */
	principalName?: string | null;
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
	/** ISO weekdays 1 = Monday .. 7 = Sunday; only for `weekly`, not empty, unique (contracts, optional). */
	weekdays?: number[];
	/** `due` (default, from the due date) or `completion` (from the day the card is completed). */
	basis?: 'due' | 'completion';
	/** Day of the month 1..31, only for `monthly`; shorter months use their last day. */
	monthDay?: number;
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
	/** contracts/planning-ext.yaml 1.1.0 */
	plannedMinutes?: number | null;
	plannedAllDay?: boolean;
	/** contracts/planning-ext.yaml 1.2.0: one-time permission for the guard; set via `PUT /tasks/{id}/auto-start` only. */
	autoStart?: boolean;
	autoStartedAt?: string | null;
}
/** `PATCH /v1/tasks/{id}/schedule`: only sent keys change, null clears (planning-ext 1.1.0). */
export interface ScheduleUpdate {
	version: number;
	plannedAt?: string | null;
	plannedMinutes?: number | null;
	plannedAllDay?: boolean;
}
export type ScheduleConflict = 'after_due' | 'prerequisite_later' | 'prerequisite_open' | 'repository_overlap';
export interface ScheduleEntry {
	taskID: string;
	projectID: string;
	title: string;
	status: TaskStatus;
	version: number;
	plannedAt?: string | null;
	plannedMinutes?: number | null;
	plannedAllDay: boolean;
	dueAt?: string | null;
	blocked: boolean;
	canEdit: boolean;
	autoStart: boolean;
	autoStartedAt?: string | null;
	jobState?: string | null;
	repositoryKey?: string | null;
	conflicts: ScheduleConflict[];
}
export interface ScheduleResponse {
	from: string;
	to: string;
	truncated: boolean;
	items: ScheduleEntry[];
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
	/** Set when the message belongs to the chat of a question or a review; both unset = chat of the task. */
	questionID?: string | null;
	reviewID?: string | null;
	/** Messages written through MCP or by the runner are `agent`; old rows may lack the field (= person). */
	authorKind?: 'person' | 'agent';
	authorLabel?: string | null;
	createdAt?: string | null;
	/** `attachment` = announces an upload (see `attachments`). */
	kind?: string | null;
	attachments?: { id: string; filename: string; mediaType: string; size: number }[] | null;
}
/** Which chat of a task: its own (`task`), or the chat of one question or review. */
export type CommentThread = { questionID: string } | { reviewID: string } | 'task';
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

/** Live view of a card (contracts/live-session.yaml, ADR 0031): compact events reported by the working agent. */
export interface LiveSession {
	id: string;
	name: string;
	model?: string | null;
	actorType: 'person' | 'integration' | 'run';
	actorLabel?: string | null;
	status: 'active' | 'ended';
	currentStep?: string | null;
	startedAt: string;
	lastSeenAt: string;
	endedAt?: string | null;
	/** Active but silent for more than 15 minutes (display hint only). */
	stale: boolean;
}
export interface LiveEvent {
	id: string;
	sessionID: string;
	sessionName?: string | null;
	kind: 'step' | 'tool' | 'note' | 'question' | 'progress' | (string & {});
	text: string;
	clientUUID?: string | null;
	createdAt: string;
}
export interface LiveTask {
	taskID: string;
	serverTime: string;
	sessions: LiveSession[];
	items: LiveEvent[];
	nextCursor?: string | null;
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
/** contracts/push.yaml */
export interface PushDevice {
	id: string;
	platform: 'ios' | 'macos';
	environment: 'sandbox' | 'production';
	bundleId: string;
	appVersion?: string | null;
	locale?: string | null;
	createdAt?: string | null;
	lastSeenAt: string;
}
export interface PushPrefs {
	categories: Record<string, boolean>;
	showContent: boolean;
	badge: boolean;
}
export interface PushTestDeviceResult {
	id: string;
	platform: string;
	environment: string;
	result: 'sent' | 'failed' | 'revoked';
	detail?: string | null;
}
export interface PushTestResult {
	devices: PushTestDeviceResult[];
	sent: number;
}
/** contracts/mail.yaml */
export interface EmailStatus {
	email?: string | null;
	verifiedAt?: string | null;
	pending?: string | null;
	pendingExpiresAt?: string | null;
	mailEnabled: boolean;
	lastMail?: { kind: string; state: 'pending' | 'sent' | 'failed' | 'skipped' | 'expired'; error?: string | null; at?: string | null } | null;
}
export interface IssuedRecovery extends RecoveryToken {
	/** Only present when the mail was requested: `queued`, `no_verified_email` or `mail_disabled`. */
	mail?: 'queued' | 'no_verified_email' | 'mail_disabled';
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
	/** Suggested connection name (the client name); absent on older servers. */
	default_name?: string;
}
export interface OAuthGrant {
	id: string;
	client_id: string;
	/** Name given at registration; empty when unknown. */
	client_name?: string;
	scopes: string[];
	project_ids: string[];
	revoked: boolean;
	/** Name of the connection (default: client name); absent on older servers. */
	name?: string;
	/** Last MCP request, ISO date; null/absent when never used. */
	last_used_at?: string | null;
}
/** A connection as a participant of a project (`GET /v1/projects/{id}/connections`); its role is the owner's role. */
export interface ProjectConnection {
	grantID: string;
	name: string;
	clientName?: string | null;
	ownerID: string;
	ownerName?: string | null;
	isOwn: boolean;
	role?: Role | null;
	scopes: string[];
	lastUsedAt?: string | null;
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
	/** 2 to 4 offered variants (contract command-center 1.8.0); absent = a plain review. Read it through `variantsOf`. */
	variants?: ReviewVariant[] | null;
}
export type BuildStatus = 'building' | 'succeeded' | 'failed';
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
	/** Reported by register_build (additive, contract session-status 1.2.0); absent if never reported. */
	status?: BuildStatus | null;
	commit?: string | null;
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
	/** The plan of the card waits for approval (pipeline stage 2); absent otherwise. */
	planWaiting?: boolean;
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
	/** Pending confirmation requests of agents (backend ADR 0026); absent on older servers. */
	pendingConfirmations?: number;
	/** Connections that asked for a project outside their grant (open notices); absent on older servers. */
	pendingAccessRequests?: number;
	/** Plans waiting for approval (pipeline stage 2); absent on older servers. */
	plansWaiting?: number;
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
	/** All repository bindings, oldest first (contract 1.1.0); absent on older servers. */
	bindings?: ProjectBinding[];
}
/** One repository binding: the same fields as the flat overview, without nested `bindings`. */
export type ProjectBinding = Omit<ProjectSync, 'bindings'>;
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
/** Situation lights reported by the watcher on the Mac (contracts/system-status.yaml). Known fields are typed loosely on purpose. */
export interface SystemStatusItem {
	source: string;
	label?: string | null;
	reportedAt: string;
	status: Record<string, unknown>;
}
export interface SystemStatusResponse {
	items: SystemStatusItem[];
	/** Server clock; the age of a report is computed against it. */
	now: string;
	/** Account switch "Automatische Starts erlauben" (default false). */
	autoStartAllowed?: boolean;
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
	/** End of the undo window after a person's decision; absent when not undoable. */
	undoUntil?: string | null;
	/** Derived by the server in lists: a comment of the agent "brain" hangs on this review. */
	brainRecommended?: boolean;
	/** 2 to 4 offered variants (contract command-center 1.8.0); absent = a plain review. Read it through `variantsOf`. */
	variants?: ReviewVariant[] | null;
	/** The variant chosen with the acceptance; reset by undo. */
	chosenVariantID?: string | null;
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

/** contracts/session-status.yaml: `GET /v1/overview/now`, what is happening now per readable project. */
export interface OverviewRunningTask {
	taskID: string;
	title: string;
	worker?: string | null;
	lastProgress?: { note: string; at: string } | null;
	ageSeconds: number;
	/** Optional, additive; shown as a progress bar only when the server sends it. */
	percent?: number | null;
}
export interface OverviewSession { sessionName: string; activity: string; updatedAt: string; ageSeconds: number; orphaned: boolean }
export interface OverviewJob { jobID: string; taskID: string; state: string; mode: string; progress: string }
export interface OverviewBuild { taskID: string; buildID: string; label?: string | null; platform?: string | null; commit?: string | null; status?: BuildStatus | null; createdAt: string }
export interface OverviewOpenItem { id: string; taskID: string; taskTitle: string; text: string; createdAt: string }
/** label, platform and status only for build.added / build.status_changed (contract session-status 1.3.0). */
export interface OverviewEvent { taskID: string; taskTitle: string; kind: string; actorType: string; createdAt: string; label?: string | null; platform?: string | null; status?: BuildStatus | null }
export interface OverviewProject {
	projectID: string;
	projectName: string;
	lastActivityAt: string;
	runningTasks: OverviewRunningTask[];
	sessions: OverviewSession[];
	agentJobs: OverviewJob[];
	builds: OverviewBuild[];
	openQuestions: OverviewOpenItem[];
	pendingReviews: OverviewOpenItem[];
	recentActivity: OverviewEvent[];
}
/** Block "Jetzt" over all readable projects (contract session-status 1.4.0, field `now`). */
export interface NowActive {
	kind: 'task' | 'session';
	projectID: string;
	projectName: string;
	/** Only for kind task. */
	taskID?: string;
	/** Card title (task) or session name (session). */
	title: string;
	/** One sentence: last progress note (task) or activity (session); may be empty. */
	text: string;
	worker?: string | null;
	/** Only for tasks: start of the claim, otherwise the last change of the card. */
	since?: string;
	lastSignAt: string;
	ageSeconds: number;
	dueAt?: string;
	percent?: number | null;
}
export interface NowWaiting { kind: 'question' | 'review'; id: string; projectID: string; projectName: string; taskID: string; taskTitle: string; text: string; createdAt: string }
export interface NowDone { taskID: string; title: string; projectID: string; projectName: string; doneAt: string }
export interface NowCounts { running: number; waiting: number; recentlyDone: number; silent: number }
export interface NowBlock { counts: NowCounts; running: NowActive[]; waiting: NowWaiting[]; recentlyDone: NowDone[]; silent: NowActive[] }
/** `now` is missing on old servers, `projects` with `compact=true`. */
export interface OverviewNow { serverTime: string; now?: NowBlock; projects?: OverviewProject[] }

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** How long a prefetched answer waits for its first reader. */
export const PRIME_TTL_MS = 4_000;

export function createApi(fetchFn: FetchLike = (i, init) => fetch(i, init), base = '/v1') {
	/**
	 * Identical GETs that overlap share one request (several views ask for the same list at the same time). Any write clears
	 * the table at its start and end, so a read issued after a write never joins an older, possibly stale one.
	 * `prime` starts reads early; the first reader within `PRIME_TTL_MS` takes the answer.
	 */
	const shared = new Map<string, { promise: Promise<unknown>; primed: boolean; expires: number }>();
	let priming = false;
	const copy = <T>(v: T): T => (v !== null && typeof v === 'object' ? structuredClone(v) : v);

	/** `bearer` replaces the cookie session (recovery token); cookies are then not sent at all. */
	function request<T>(
		method: string,
		path: string,
		body?: unknown,
		bearer?: string,
		extraHeaders?: Record<string, string>
	): Promise<T> {
		if (method !== 'GET') {
			shared.clear();
			return send<T>(method, path, body, bearer, extraHeaders).finally(() => shared.clear());
		}
		if (bearer || extraHeaders) return send<T>(method, path, body, bearer, extraHeaders);
		const hit = shared.get(path);
		if (hit && hit.expires > Date.now()) {
			hit.primed = false;
			if (hit.expires !== Infinity) shared.delete(path);
			return hit.promise.then((v) => copy(v as T));
		}
		const entry = { promise: undefined as unknown as Promise<unknown>, primed: priming, expires: Infinity };
		entry.promise = send<T>(method, path).finally(() => {
			if (shared.get(path) !== entry) return;
			if (entry.primed) entry.expires = Date.now() + PRIME_TTL_MS;
			else shared.delete(path);
		});
		shared.set(path, entry);
		if (priming) entry.promise.catch(() => shared.get(path) === entry && shared.delete(path));
		return entry.promise as Promise<T>;
	}

	async function send<T>(
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
		/** Starts the given reads right away (before the page knows it needs them); the first reader takes the answer. */
		prime: (reads: Array<() => Promise<unknown>>) => {
			priming = true;
			try {
				for (const read of reads) read().catch(() => undefined);
			} finally {
				priming = false;
			}
		},
		capabilities: () => request<Capabilities>('GET', '/capabilities'),
		me: () => request<User>('GET', '/me'),
		/** contracts/voice.yaml: the own channel #brain, newest first; `cursor` is `nextCursor` of the previous page. */
		brainMessages: (cursor?: string | null) => request<ChannelMessagePage>('GET', `/channels/brain/messages${query({ limit: 50, cursor })}`),
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
		actionRequest: (id: string) => request<ActionRequest>('GET', `/action-requests/${id}`),
		confirmActionRequest: (id: string) => request<ActionRequest>('POST', `/action-requests/${id}/confirm`),
		rejectActionRequest: (id: string) => request<ActionRequest>('POST', `/action-requests/${id}/reject`),
		performAction: (method: string, path: string, body: unknown) => request<unknown>(method, path, body),
		overviewNow: (opts: { compact?: boolean; limit?: number } = {}) =>
			request<OverviewNow>('GET', `/overview/now${query({ compact: opts.compact ? 'true' : undefined, limit: opts.compact ? opts.limit : undefined })}`),
		feed: (params: { projectID?: string; before?: string | null; limit?: number } = {}) =>
			request<FeedPage>('GET', `/activity${query({ projectID: params.projectID, before: params.before, limit: params.limit })}`),

		listTasks: (projectID?: string, includeLabels = false) =>
			request<Task[]>('GET', `/tasks${query({ projectID, includeLabels: includeLabels ? 'true' : undefined })}`),
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
		jobDetail: (id: string) => request<JobDetail>('GET', `/agents/jobs/${id}`),
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
		schedule: (from: string, to: string, projectID?: string) =>
			request<ScheduleResponse>('GET', `/planning/schedule${query({ from, to, projectID })}`),
		unscheduled: (projectID?: string) => request<PlanningTask[]>('GET', `/planning/unscheduled${query({ projectID })}`),
		scheduleTask: (taskID: string, body: ScheduleUpdate) => request<PlanningTask>('PATCH', `/tasks/${taskID}/schedule`, body),
		setAutoStart: (taskID: string, body: { version: number; enabled: boolean; deviceID?: string }) =>
			request<PlanningTask>('PUT', `/tasks/${taskID}/auto-start`, body),
		autoStartSetting: () => request<{ allowed: boolean; updatedAt?: string | null }>('GET', '/settings/auto-start'),
		setAutoStartSetting: (allowed: boolean) => request<{ allowed: boolean; updatedAt?: string | null }>('PUT', '/settings/auto-start', { allowed }),
		dependencies: (taskID: string) => request<Task[]>('GET', `/planning/tasks/${taskID}/dependencies`),
		addDependency: (taskID: string, prerequisiteID: string) =>
			request<void>('PUT', `/planning/tasks/${taskID}/dependencies`, { prerequisiteID }),
		removeDependency: (taskID: string, prerequisiteID: string) =>
			request<void>('DELETE', `/planning/tasks/${taskID}/dependencies/${prerequisiteID}`),
		taskGraph: (projectID: string, includeSubprojects: boolean) =>
			request<TaskGraphData>('GET', `/planning/dependencies${query({ projectID, includeSubprojects: includeSubprojects ? 'true' : undefined })}`),
		/** Everything the graph view needs in one call (tasks with title/status/due date, edges, milestones with members). */
		taskGraphDetails: (projectID: string, includeSubprojects: boolean) =>
			request<TaskGraphData>('GET', `/planning/dependencies${query({ projectID, includeSubprojects: includeSubprojects ? 'true' : undefined, details: 'true' })}`),
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
		listComments: (taskID: string, thread?: CommentThread) => {
			const q = !thread ? '' : thread === 'task' ? '?thread=task' : 'questionID' in thread ? `?questionID=${thread.questionID}` : `?reviewID=${thread.reviewID}`;
			return request<Comment[]>('GET', `/tasks/${taskID}/comments${q}`);
		},
		createComment: (taskID: string, body: string, thread?: CommentThread) =>
			request<Comment>('POST', `/tasks/${taskID}/comments`, { body, ...(thread && thread !== 'task' ? thread : {}) }),
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

		/** Live view of a card: sessions (all) and the newest events; `cursor` = nextCursor of the previous page. */
		taskLive: (taskID: string, cursor?: string | null, limit = 50) =>
			request<LiveTask>('GET', `/tasks/${taskID}/live${query({ cursor, limit })}`),

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
		transferOwner: (p: Project, ownerType: PrincipalType, ownerID: string) =>
			request<EffectiveVisibility>('PUT', `/projects/${p.id}/owner`, { version: p.version, ownerType, ownerID }),
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
		completeAttachment: (id: string, thread?: { questionID?: string; reviewID?: string }) =>
			request<Attachment>('POST', `/attachments/${id}/complete`, thread ?? {}),
		abortAttachment: (id: string) => request<void>('DELETE', `/attachments/${id}`),
		attachmentPreviewURL: (id: string) => `${base}/attachments/${id}/preview`,
		attachmentDownloadURL: (id: string) => `${base}/attachments/${id}/download`,

		// Repository sync (contracts/project-sync.yaml)
		getProjectSync: (projectID: string) => request<ProjectSync>('GET', `/projects/${projectID}/sync`),
		deleteProjectBinding: (projectID: string, repository: string) =>
			request<ProjectSync>('DELETE', `/projects/${projectID}/bindings?repository=${encodeURIComponent(repository)}`),
		putProjectSync: (projectID: string, body: { repository?: string; staleAfterDays?: number }) =>
			request<ProjectSync>('PUT', `/projects/${projectID}/sync`, body),

		// Situation lights (contracts/system-status.yaml)
		systemStatus: () => request<SystemStatusResponse>('GET', '/system-status'),

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
		question: (id: string) => request<Question>('GET', `/questions/${id}`),
		answerQuestion: (id: string, answer: string, freeText?: boolean) => request<Question>('POST', `/questions/${id}/answer`, freeText ? { answer, freeText: true } : { answer }),
		listReviews: (p: { projectID?: string; state?: Review['state'] | 'all'; limit?: number; brainRecommended?: boolean } = {}) =>
			request<Review[]>('GET', `/reviews${query({ projectID: p.projectID, state: p.state ?? 'pending', limit: p.limit, brainRecommended: p.brainRecommended === undefined ? undefined : String(p.brainRecommended) })}`),
		/** Bulk decision (contracts/command-center.yaml 1.5.0): one result per review, no overall rollback. */
		decideReviewsBatch: (reviewIDs: string[], decision: 'accept' | 'changes_requested', note?: string) =>
			request<BatchResponse>('POST', '/reviews/decisions', { decisions: reviewIDs.map((reviewID) => ({ reviewID })), decision, note: note || undefined }),
		/** `variantID`: the chosen variant, required by the server when accepting a review with variants. */
		decideReview: (taskID: string, decision: 'accept' | 'request_changes', note?: string, variantID?: string) =>
			request<Review>('POST', `/tasks/${taskID}/review/decision`, { decision, note: note || undefined, variantID: variantID || undefined }),
		undoReviewDecision: (taskID: string) => request<Review>('POST', `/tasks/${taskID}/review/undo`),
		taskContext: (taskID: string) => request<TaskContext>('GET', `/tasks/${taskID}/context`),

		// Plan approval and pipeline of a card (contracts/pipeline.yaml); older servers answer 404.
		taskPipeline: (taskID: string) => request<TaskPipeline>('GET', `/tasks/${taskID}/pipeline`),
		decidePlan: (taskID: string, { decision, version, comment }: PlanDecisionInput) =>
			request<TaskPipeline>('POST', `/tasks/${taskID}/plan/decision`, { decision, version, comment: comment || undefined }),
		/** Stage 2 (card B926E7D8): only a failed step goes back to pending; the server counts the fix round. */
		retryPipelineStep: (taskID: string, step: PipelineStepName, { planVersion, note }: RetryInput) =>
			request<TaskPipeline>('POST', `/tasks/${taskID}/pipeline/steps/${step}/retry`, { planVersion, note: note?.trim() || undefined }),
		/** `planVersion`: the version the state is based on; the server refuses (`plan_changed`) when the plan moved on. */
		// Execution on a runner (stage 3, docs/PLAN-PIPELINE-STUFE-3.md section 3).
		startPipelineExecution: (taskID: string, { id, bindingID }: StartInput) =>
			request<TaskPipeline>('POST', `/tasks/${taskID}/pipeline/execution`, { id, bindingID }),
		continuePipelineExecution: (taskID: string, { planVersion }: ContinueInput) =>
			request<TaskPipeline>('POST', `/tasks/${taskID}/pipeline/execution/continue`, { planVersion }),
		stopPipelineExecution: (taskID: string) => request<TaskPipeline>('POST', `/tasks/${taskID}/pipeline/execution/stop`, {}),
		setPipelineStep: (taskID: string, step: PipelineStepName, body: { state: string; note?: string; planVersion?: number }) =>
			request<TaskPipeline>('PUT', `/tasks/${taskID}/pipeline/steps/${step}`, body),
		pipelineSettings: (projectID: string) => request<PipelineSettings>('GET', `/projects/${projectID}/pipeline-settings`),
		updatePipelineSettings: (projectID: string, body: SettingsPatch & { revision: number }) =>
			request<PipelineSettings>('PATCH', `/projects/${projectID}/pipeline-settings`, body),
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
		issueRecovery: (accountID: string, sendEmail = false) =>
			request<IssuedRecovery>('POST', `/identity/accounts/${encodeURIComponent(accountID)}/recovery`, sendEmail ? { sendEmail: true } : {}),
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
		oauthConsent: (consentToken: string, approve: boolean, projectIDs: string[], connectionName?: string) =>
			request<{ redirect_uri: string }>('POST', '/oauth/consent', {
				consent_token: consentToken,
				approve,
				project_ids: approve ? projectIDs : [],
				...(approve && connectionName !== undefined ? { connection_name: connectionName } : {})
			}),
		listOAuthGrants: () => request<OAuthGrant[]>('GET', '/oauth/grants'),
		// Notifications (contracts/push.yaml) and e-mail (contracts/mail.yaml)
		listPushDevices: () => request<PushDevice[]>('GET', '/push/devices'),
		revokePushDevice: (id: string) => request<void>('DELETE', `/push/devices/${id}`),
		getPushPrefs: () => request<PushPrefs>('GET', '/me/push-prefs'),
		setPushPrefs: (body: Partial<PushPrefs>) => request<PushPrefs>('POST', '/me/push-prefs', body),
		sendPushTest: () => request<PushTestResult>('POST', '/push/test', {}),
		/** Whether the server can send APNs notifications at all (signed-in users; /health/ready no longer says). */
		pushServerEnabled: async () => {
			try {
				return Boolean((await request<{ enabled?: boolean }>('GET', '/push/status')).enabled);
			} catch {
				return false;
			}
		},
		getEmail: () => request<EmailStatus>('GET', '/me/email'),
		setEmail: (email: string) => request<{ status: string; expiresAt: string }>('POST', '/me/email', { email }),
		removeEmail: () => request<void>('DELETE', '/me/email'),
		sendTestEmail: () => request<{ status: string }>('POST', '/me/email/test', {}),
		confirmEmail: (token: string) => request<void>('POST', '/email/confirm', { token }),

		renameOAuthGrant: (id: string, name: string) => request<OAuthGrant>('PATCH', `/oauth/grants/${id}`, { name }),
		/** Connections that reach a project (needs manage); the role is capped by the connection's owner. */
		listProjectConnections: (projectID: string) => request<ProjectConnection[]>('GET', `/projects/${projectID}/connections`),
		addProjectConnection: (projectID: string, grantID: string) => request<ProjectConnection[]>('PUT', `/projects/${projectID}/connections`, { grantID }),
		removeProjectConnection: (projectID: string, grantID: string) => request<void>('DELETE', `/projects/${projectID}/connections/${grantID}`),
		/** Notice "connection wanted a project": allow adds the project to the connection, ignore silences the notice. */
		allowAccessRequest: (id: string) => request<void>('POST', `/connection-access-requests/${id}/allow`, {}),
		ignoreAccessRequest: (id: string) => request<void>('POST', `/connection-access-requests/${id}/ignore`, {}),
		revokeOAuthGrant: (id: string) => request<void>('DELETE', `/oauth/grants/${id}`),
		/** Replaces the projects of an existing connection (authorise and deauthorise afterwards); effective immediately. */
		setOAuthGrantProjects: (id: string, projectIDs: string[]) => request<OAuthGrant>('PUT', `/oauth/grants/${id}/projects`, { project_ids: projectIDs }),

		// Brain mandates (contracts/connections.yaml 1.2.0, ADR 0032 addendum): one per connection; person session only, OAuth tokens get 401.
		/** One entry per connection that ever got a mandate, newest first. After a revocation the entry stays, with `active: false`. */
		listBrainMandates: async () => (await request<{ mandates: BrainMandate[] }>('GET', '/settings/brain-mandate')).mandates,
		/** Gives or overwrites the mandate of that connection only (400 invalid_projects, 404 unknown grant/project, 409 grant_revoked). */
		putBrainMandate: (grantID: string, projectIDs: string[]) => request<BrainMandate>('PUT', '/settings/brain-mandate', { grantID, projectIDs }),
		/** Revokes the mandate of one connection at once; the others stay. Idempotent. */
		revokeBrainMandate: (grantID: string) => request<void>('DELETE', `/settings/brain-mandate/${encodeURIComponent(grantID)}`),
		/** Decisions made under the mandate, newest first (at most 200). */
		listBrainAudit: async () => (await request<{ items: BrainAuditItem[] }>('GET', '/settings/brain-mandate/audit')).items,

		// Outgoing webhook (contracts/webhook.yaml, ADR 0035): person session only. The API never returns the address, only a mask.
		getWebhook: () => request<WebhookSettings>('GET', '/settings/webhook'),
		/** Fields that are left out stay as they are; `url: null` deletes the webhook. Errors: 400 webhook_*, 404 project, 409 encryption_key_missing / webhook_not_configured. */
		updateWebhook: (body: UpdateWebhook) => request<WebhookSettings>('PUT', '/settings/webhook', body),
		deleteWebhook: () => request<void>('DELETE', '/settings/webhook'),
		/** Sends a test call at once and returns its protocol entry (429 rate_limited: one per 10 s). */
		testWebhook: () => request<WebhookDelivery>('POST', '/settings/webhook/test', {}),
		/** The last 50 deliveries, newest first. */
		listWebhookDeliveries: async () => (await request<{ items: WebhookDelivery[] }>('GET', '/settings/webhook/deliveries')).items
	};
}

export type Api = ReturnType<typeof createApi>;
export const api = createApi();
