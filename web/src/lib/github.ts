/**
 * GitHub per person (card E51E8B8C, contracts/deploy.yaml 1.3.0, ADR 0042 addendum): types of `/v1/github` and
 * `/v1/projects/{id}/github-repositories` and the pure rules of the PWA pages. No DOM.
 *
 * The operator runs one GitHub App; every person installs it on their own account or organisation. The server decides every
 * right; the PWA only follows addresses that lead to GitHub (or to the local test double) and shows fixed German texts.
 */

import { ApiError, type Api } from './api.js';
import { t, type MessageKey } from './i18n/index.js';
import { de } from './i18n/de.js';

export interface GitHubConnection {
	id: string;
	accountLogin: string;
	accountType: 'User' | 'Organization';
	githubLogin: string;
	manageURL: string;
	createdAt: string;
}
export interface GitHubOverview {
	available: boolean;
	connections: GitHubConnection[];
}
export interface GitHubRepository {
	repository: string;
	id: number;
	private: boolean;
}
export interface GitHubRepositoryList {
	ok: boolean;
	code?: string;
	items: GitHubRepository[];
	truncated?: boolean;
}
export interface GitHubAssignment {
	/** Missing for entries of the operator (old server variables). */
	id?: string;
	repository: string;
	source: 'user' | 'operator';
	assignedBy?: string;
	mine: boolean;
	active: boolean;
}
export type GitHubConnectMode = 'install' | 'existing';
/** `/v1/github/setup` answers with an address (go on to the authorization) or, with a code, with the connections. */
export type GitHubSetupAnswer = { url?: string; connections?: GitHubConnection[] };

export type GitHubReturn =
	| { kind: 'setup'; state: string; installationID: string; code?: string }
	| { kind: 'callback'; state: string; code: string }
	/** The person said no on GitHub. */
	| { kind: 'denied' }
	/** An organisation member asked the owner to install the app; nothing is installed yet. */
	| { kind: 'requested' }
	/** The installation was changed on GitHub itself (no step of ours). */
	| { kind: 'updated' }
	| { kind: 'missing' };

/** The query of `/github/setup` or `/github/callback`. Everything in it can be forged; the server checks it. */
export function parseGitHubReturn(search: string): GitHubReturn {
	const q = new URLSearchParams(search);
	const state = q.get('state') ?? '';
	const code = q.get('code') || undefined;
	const installation = q.get('installation_id');
	if (q.has('error')) return { kind: 'denied' };
	if (q.get('setup_action') === 'request') return { kind: 'requested' };
	if (!state && q.get('setup_action') === 'update') return { kind: 'updated' };
	if (state.length < 16) return { kind: 'missing' };
	if (installation !== null) {
		return /^[0-9]{1,20}$/.test(installation) ? { kind: 'setup', state, installationID: installation, code } : { kind: 'missing' };
	}
	return code ? { kind: 'callback', state, code } : { kind: 'missing' };
}

/** The address if the browser may be sent there: https without credentials, or http on the own machine (test double). */
export function safeGitHubURL(url: string | undefined): string | null {
	if (!url) return null;
	try {
		const u = new URL(url);
		if (u.username || u.password) return null;
		if (u.protocol === 'https:') return url;
		return u.protocol === 'http:' && (u.hostname === '127.0.0.1' || u.hostname === 'localhost') ? url : null;
	} catch {
		return null;
	}
}

export async function finishReturn(
	api: Pick<Api, 'githubSetup' | 'githubCallback'>,
	r: Extract<GitHubReturn, { kind: 'setup' | 'callback' }>
): Promise<{ done: true } | { redirect: string }> {
	if (r.kind === 'callback') {
		await api.githubCallback(r.state, r.code);
		return { done: true };
	}
	const answer = await api.githubSetup(r.state, r.installationID, r.code);
	if (answer.url === undefined) return { done: true };
	const url = safeGitHubURL(answer.url);
	if (!url) throw new ApiError(0, 'github_address_invalid');
	return { redirect: url };
}

/** Fixed German text for a reason code; never the server's own text. */
export function githubErrorText(e: unknown): string {
	const reason = e instanceof ApiError ? e.reason : typeof e === 'string' ? e : undefined;
	const key = `github.error.${reason}` as MessageKey;
	if (reason && key in de) return t(key);
	if (e instanceof ApiError && e.status === 0 && e.reason === 'network') return t('error.network');
	return t('github.error.generic');
}

/** Repositories of a connection that are not mapped to the project yet. Public ones are shown but cannot be chosen. */
export function repositoryChoices(items: GitHubRepository[], assigned: GitHubAssignment[]): { repository: string; disabled: boolean }[] {
	const taken = new Set(assigned.map((a) => a.repository.toLowerCase()));
	return items.filter((r) => !taken.has(r.repository.toLowerCase())).map((r) => ({ repository: r.repository, disabled: !r.private }));
}
