import { ApiError } from './api.js';

/** Small reads and one admin write that talk to the instance itself (health, manual, invitations). */
export interface HealthReady {
	status: string;
	maintenance?: { enabled: boolean; lastRunAt?: string | null; lastStatus: string };
	push?: { enabled: boolean; environment: string };
	mail?: { enabled: boolean };
}
export interface ManualDoc {
	version: string | number;
	sections: { id: string; title: string }[];
	section?: string;
	content: string;
}
export interface Invitation {
	id: string;
	token: string;
	expiresAt: string;
}
/** contracts/openapi.yaml InvitationSummary; the code itself is never listed. */
export interface InvitationSummary {
	id: string;
	status: 'open' | 'used' | 'expired';
	expiresAt: string;
	usedAt?: string | null;
	createdBy: string;
	createdByName: string;
}
/** Open ones first (soonest expiry first), then used and expired (newest first). */
export function sortInvitations(list: InvitationSummary[]): InvitationSummary[] {
	const open = list.filter((i) => i.status === 'open').sort((a, b) => a.expiresAt.localeCompare(b.expiresAt));
	const rest = list.filter((i) => i.status !== 'open').sort((a, b) => b.expiresAt.localeCompare(a.expiresAt));
	return [...open, ...rest];
}

async function json<T>(path: string, init?: RequestInit): Promise<T> {
	let res: Response;
	try {
		res = await fetch(path, { credentials: 'same-origin', ...init, headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...init?.headers } });
	} catch {
		throw new ApiError(0, 'network');
	}
	if (!res.ok) {
		let reason: string | undefined;
		try {
			reason = ((await res.json()) as { reason?: string }).reason;
		} catch {
			/* not JSON */
		}
		throw new ApiError(res.status, reason);
	}
	if (res.status === 204) return undefined as T;
	return (await res.json()) as T;
}

export const instance = {
	health: () => json<HealthReady>('/health/ready'),
	/** Administrators only: maintenance, mail and push details (the public probe shows readiness only). */
	adminHealth: () => json<HealthReady>('/v1/admin/health'),
	manual: (section?: string) => json<ManualDoc>(`/v1/manual${section ? `?section=${encodeURIComponent(section)}` : ''}`),
	/** Admin only; the token is shown once. */
	createInvitation: () => json<Invitation>('/v1/invitations', { method: 'POST' }),
	listInvitations: () => json<InvitationSummary[]>('/v1/invitations'),
	withdrawInvitation: (id: string) => json<void>(`/v1/invitations/${encodeURIComponent(id)}`, { method: 'DELETE' })
};
