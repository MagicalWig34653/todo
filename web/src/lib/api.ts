import type { AuthenticationPayload, CreationOptionsJSON, RegistrationPayload, RequestOptionsJSON } from './webauthn.js';

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
	/** Only present in task lists. */
	planning?: TaskPlanningSummary;
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
	async function request<T>(method: string, path: string, body?: unknown, bearer?: string): Promise<T> {
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
					...(bearer ? { Authorization: `Bearer ${bearer}` } : {})
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
		deleteProject: (id: string) => request<void>('DELETE', `/projects/${id}`),

		listTasks: (projectID: string) => request<Task[]>('GET', `/tasks?projectID=${encodeURIComponent(projectID)}`),
		createTask: (projectID: string, title: string) => request<Task>('POST', '/tasks', { projectID, title }),
		updateTask: (
			t: Task,
			changes: Partial<Pick<Task, 'title' | 'description' | 'status'>>
		) => request<Task>('PATCH', `/tasks/${t.id}`, { version: t.version, ...changes }),
		deleteTask: (id: string) => request<void>('DELETE', `/tasks/${id}`),

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
