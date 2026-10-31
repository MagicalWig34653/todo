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
	token: string;
	expiresAt: string;
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
	return (await res.json()) as T;
}

export const instance = {
	health: () => json<HealthReady>('/health/ready'),
	manual: (section?: string) => json<ManualDoc>(`/v1/manual${section ? `?section=${encodeURIComponent(section)}` : ''}`),
	/** Admin only; the token is shown once. */
	createInvitation: () => json<Invitation>('/v1/invitations', { method: 'POST' })
};
