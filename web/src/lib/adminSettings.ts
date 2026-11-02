import { ApiError } from './api.js';

/**
 * Server settings for administrators (contracts/admin-settings.yaml, ADR 0025). Kept out of api.ts: the forms are generated
 * from the metadata that GET /v1/admin/settings returns, so this module only carries the types, a small client and the
 * pure helpers (drafts, validation hints, save order) that tests/adminSettings.test.ts covers.
 */
export type SettingType = 'bool' | 'int' | 'string' | 'enum' | 'text' | 'stringList';
export type SettingOrigin = 'env' | 'db' | 'default';
export type SettingValue = boolean | number | string;

export interface ServerSetting {
	key: string;
	category: string;
	label: string;
	help: string;
	type: SettingType;
	/** Name of the environment variable that would lock this setting. */
	env: string;
	secret: boolean;
	hotReload: boolean;
	requiresRestart: boolean;
	origin: SettingOrigin;
	/** An environment value exists: read-only here. */
	locked: boolean;
	/** Never present for secrets. */
	value?: SettingValue;
	defaultValue?: SettingValue;
	isSet: boolean;
	unreadable: boolean;
	fingerprint?: string;
	version: number;
	updatedAt?: string;
	updatedBy?: string;
	min?: number;
	max?: number;
	options?: string[];
	placeholder?: string;
}
export interface ServerSettingCategory {
	id: string;
	label: string;
	help: string;
}
export interface FixedSetting {
	name: string;
	label: string;
	help: string;
	isSet: boolean;
	value?: string;
}
export interface ServerSettingsOverview {
	encryptionKeyConfigured: boolean;
	categories: ServerSettingCategory[];
	settings: ServerSetting[];
	fixed: FixedSetting[];
	lastError?: string;
}
export interface AuditEntry {
	id: string;
	key: string;
	action: 'set' | 'reset' | 'test' | 'admin';
	actorName: string;
	detail?: string;
	version?: number;
	at?: string;
}
export interface TestResult {
	ok: boolean;
	message: string;
	durationMs?: number;
	details?: Record<string, string>;
}
export type TestKind = 'mail' | 'apns' | 'storage';

/** Failure of an admin settings call. `serverMessage` is already German and names the setting. */
export class SettingsApiError extends ApiError {
	constructor(
		status: number,
		reason: string | undefined,
		readonly serverMessage?: string,
		readonly key?: string,
		readonly currentVersion?: number
	) {
		super(status, reason);
	}
	get isVersionConflict() {
		return this.status === 409 && this.reason === 'version_conflict';
	}
}

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
	let res: Response;
	try {
		res = await fetch(`/v1/admin${path}`, {
			method,
			credentials: 'same-origin',
			headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
			body: body === undefined ? undefined : JSON.stringify(body)
		});
	} catch {
		throw new ApiError(0, 'network');
	}
	if (!res.ok) {
		let p: { reason?: string; message?: string; key?: string; currentVersion?: number } = {};
		try {
			p = await res.json();
		} catch {
			/* not JSON */
		}
		throw new SettingsApiError(res.status, p.reason, p.message, p.key, p.currentVersion);
	}
	return (await res.json()) as T;
}

export const adminSettings = {
	overview: () => call<ServerSettingsOverview>('GET', '/settings'),
	put: (key: string, value: SettingValue, version: number) => call<ServerSetting>('PUT', `/settings/${encodeURIComponent(key)}`, { value, version }),
	reset: (key: string, version: number) => call<ServerSetting>('DELETE', `/settings/${encodeURIComponent(key)}?version=${version}`),
	audit: (limit = 50) => call<AuditEntry[]>('GET', `/settings/audit?limit=${limit}`),
	test: (kind: TestKind, body?: { to?: string }) => call<TestResult>('POST', `/settings/test/${kind}`, body ?? {}),
	users: () => call<AdminUser[]>('GET', '/users'),
	setAdmin: (id: string, isAdmin: boolean) => call<AdminUser>('PUT', `/users/${encodeURIComponent(id)}/admin`, { isAdmin }),
	lock: (id: string, action: LockAction) => call<AdminUser>('POST', `/users/${encodeURIComponent(id)}/${action}`),
	ownedProjects: (id: string) => call<OwnedProject[]>('GET', `/users/${encodeURIComponent(id)}/projects`),
	transferProjects: (id: string, to: TransferTarget, projectIDs: string[]) =>
		call<TransferResult>('POST', `/users/${encodeURIComponent(id)}/transfer-projects`, { to, projectIDs }),
	transferTeams: () => call<TransferTeam[]>('GET', '/teams')
};

export type LockAction = 'disable' | 'enable' | 'anonymize';
export type AccountStatus = 'active' | 'disabled' | 'anonymized';

/** contracts/admin-settings.yaml AdminUser */
export interface AdminUser {
	id: string;
	displayName: string;
	isAdmin: boolean;
	username?: string;
	/** Absent on servers from before account locking: treated as active. */
	status?: AccountStatus;
	disabledAt?: string;
	anonymizedAt?: string;
	/** Only for locked accounts: projects they still own. */
	ownedProjects?: number;
}

/** contracts/admin-settings.yaml OwnedProject */
export interface OwnedProject {
	id: string;
	name: string;
	parentID?: string;
	parentName?: string;
	taskCount: number;
}
export interface TransferTarget {
	type: 'person' | 'team';
	id: string;
}
export interface TransferResult {
	transferred: number;
	projects: { id: string; name: string }[];
	to: TransferTarget;
}
export interface TransferTeam {
	id: string;
	name: string;
	activeAdmins: number;
}

export const statusOf = (u: AdminUser): AccountStatus => u.status ?? 'active';

/** Active accounts first (administrators on top), then disabled, then anonymized; by name inside each group. */
export function sortUsers(users: AdminUser[]): AdminUser[] {
	const rank = (u: AdminUser) => ({ active: 0, disabled: 1, anonymized: 2 })[statusOf(u)];
	return [...users].sort((a, b) => rank(a) - rank(b) || Number(b.isAdmin) - Number(a.isAdmin) || a.displayName.localeCompare(b.displayName, 'de'));
}

/** Lock actions the accounts page offers for a row. The own account is never offered here (the server answers 409). */
export function lockActions(u: AdminUser, selfID: string | undefined): LockAction[] {
	const status = statusOf(u);
	if (status === 'anonymized' || u.id === selfID) return [];
	return status === 'disabled' ? ['enable', 'anonymize'] : ['disable', 'anonymize'];
}

/** The "transfer projects" action is offered for locked or anonymized accounts that still own projects. */
export function canTransferProjects(u: AdminUser): boolean {
	return statusOf(u) !== 'active' && (u.ownedProjects ?? 0) > 0;
}

/**
 * Selected IDs plus every listed sub-project whose parent is selected (the server moves owned children with their parent;
 * the list shows exactly that so nobody is surprised).
 */
export function expandSelection(rows: OwnedProject[], selected: Iterable<string>): Set<string> {
	const out = new Set(selected);
	let grew = true;
	while (grew) {
		grew = false;
		for (const r of rows) if (r.parentID && out.has(r.parentID) && !out.has(r.id)) (out.add(r.id), (grew = true));
	}
	return out;
}

/** Rows that are selected only because their parent is: shown ticked and locked. */
export function followsParent(rows: OwnedProject[], r: OwnedProject, selected: Set<string>): boolean {
	return !!r.parentID && selected.has(r.parentID) && rows.some((x) => x.id === r.parentID);
}

/** Whether the target is complete enough to confirm. */
export function transferReady(target: { type: 'person' | 'team'; id: string }, selected: Set<string>): boolean {
	return selected.size > 0 && target.id.trim() !== '';
}

/** After an admin flag changed: refreshes the signed-in user's own profile when the change concerned themselves. */
export async function refreshAfterRoleChange(changedUserID: string, currentUserID: string | undefined, refresh: () => Promise<void>): Promise<boolean> {
	if (!currentUserID || changedUserID !== currentUserID) return false;
	await refresh();
	return true;
}

// --- Pure helpers ----------------------------------------------------------------------------------------------

/** The editable text of a setting (secrets start empty: their value is never delivered). */
export function draftOf(s: ServerSetting): SettingValue {
	if (s.secret) return '';
	if (s.type === 'bool') return s.value === true;
	return s.value === undefined ? '' : s.value;
}

/** Whether the draft differs from what is stored/effective. Secrets differ as soon as something was typed. */
export function isDirty(s: ServerSetting, draft: SettingValue | undefined): boolean {
	if (s.locked || draft === undefined) return false;
	if (s.secret) return String(draft) !== '';
	return String(draft).trim() !== String(draftOf(s)).trim();
}

/** Typed value for the PUT body. Empty text returns undefined (the field is left alone; use "reset" to remove). */
export function toValue(s: ServerSetting, draft: SettingValue): SettingValue | undefined {
	if (s.type === 'bool') return draft === true || draft === 'true';
	if (s.type === 'int') {
		const text = String(draft).trim();
		return /^-?\d+$/.test(text) ? Number(text) : undefined;
	}
	const text = String(draft).trim();
	return text === '' ? undefined : text;
}

/** Client-side hint before sending (the server validates again): message key plus parameters, or null. */
export function hintFor(s: ServerSetting, draft: SettingValue): { key: 'admin.server.hint.int' | 'admin.server.hint.min' | 'admin.server.hint.max'; params?: Record<string, number> } | null {
	if (s.type !== 'int') return null;
	const text = String(draft).trim();
	if (text === '') return null;
	if (!/^-?\d+$/.test(text)) return { key: 'admin.server.hint.int' };
	const n = Number(text);
	if (s.min !== undefined && n < s.min) return { key: 'admin.server.hint.min', params: { min: s.min } };
	if (s.max !== undefined && n > s.max) return { key: 'admin.server.hint.max', params: { max: s.max } };
	return null;
}

/**
 * Order for saving several changes of one category. Switching a feature on must come last (it validates the whole
 * configuration), switching it off must come first (so the remaining fields can be cleared without errors).
 */
export function saveOrder(changes: { setting: ServerSetting; value: SettingValue }[]): { setting: ServerSetting; value: SettingValue }[] {
	const rank = (c: { setting: ServerSetting; value: SettingValue }) => {
		if (!c.setting.key.endsWith('.enabled')) return 1;
		return c.value === true ? 2 : 0;
	};
	return [...changes].sort((a, b) => rank(a) - rank(b));
}

export const TEST_FOR_CATEGORY: Record<string, TestKind | undefined> = { mail: 'mail', push: 'apns', attachments: 'storage' };
