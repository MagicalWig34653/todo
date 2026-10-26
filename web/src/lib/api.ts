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
export interface Task {
	id: string;
	projectID: string;
	title: string;
	description: string;
	status: TaskStatus;
	version: number;
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

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export function createApi(fetchFn: FetchLike = (i, init) => fetch(i, init), base = '/v1') {
	async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
		let response: Response;
		try {
			response = await fetchFn(base + path, {
				method,
				credentials: 'same-origin',
				// The backend requires JSON for cookie-authenticated writes (CSRF protection).
				headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
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
		deleteTask: (id: string) => request<void>('DELETE', `/tasks/${id}`)
	};
}

export type Api = ReturnType<typeof createApi>;
export const api = createApi();
