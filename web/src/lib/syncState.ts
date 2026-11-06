import { ApiError, type ProjectBinding, type ProjectSync, type ProjectSyncEntry, type Role, type SyncBrief, type SyncState } from './api.js';
import type { MessageKey } from './i18n/index.js';

/** Filter of the account overview (contracts/project-sync.yaml, ADR 0018). */
export type SyncFilter = 'all' | 'attention' | 'stale' | 'never' | 'fresh';

export const STALE_AFTER_MIN = 1;
export const STALE_AFTER_MAX = 365;

export type SyncTone = 'success' | 'warning' | 'default';

/** Chip content: message key suffix, tone and the day count for the "stale" text. */
export function syncChip(sync: SyncBrief | null | undefined): { state: SyncState; tone: SyncTone; days: number } {
	const state: SyncState = sync?.state === 'fresh' || sync?.state === 'stale' ? sync.state : 'never';
	const days = Math.max(0, Math.floor(sync?.daysSince ?? 0));
	return { state, tone: state === 'fresh' ? 'success' : state === 'stale' ? 'warning' : 'default', days };
}

/** `attention` = everything that is not fresh (stale and never synced). */
export function filterSync(entries: ProjectSyncEntry[] | null | undefined, filter: SyncFilter): ProjectSyncEntry[] {
	const all = entries ?? [];
	if (filter === 'all') return all;
	if (filter === 'attention') return all.filter((e) => e.sync.state !== 'fresh');
	return all.filter((e) => e.sync.state === filter);
}

/** Stale first (longest outdated on top), then never synced, then fresh; ties by name. */
export function sortSync(entries: ProjectSyncEntry[]): ProjectSyncEntry[] {
	const rank = (s: SyncState) => (s === 'stale' ? 0 : s === 'never' ? 1 : 2);
	return [...entries].sort(
		(a, b) =>
			rank(a.sync.state) - rank(b.sync.state) ||
			(b.sync.daysSince ?? 0) - (a.sync.daysSince ?? 0) ||
			a.name.localeCompare(b.name, 'de')
	);
}

export function syncCounts(entries: ProjectSyncEntry[] | null | undefined): Record<SyncState, number> {
	const out: Record<SyncState, number> = { fresh: 0, stale: 0, never: 0 };
	for (const e of entries ?? []) out[e.sync.state] = (out[e.sync.state] ?? 0) + 1;
	return out;
}

/** Threshold input: whole days between 1 and 365, otherwise `null`. */
export function parseStaleAfter(raw: string | number): number | null {
	const text = String(raw).trim();
	if (!/^\d+$/.test(text)) return null;
	const n = Number(text);
	return n >= STALE_AFTER_MIN && n <= STALE_AFTER_MAX ? n : null;
}

/** Browser link for a bound repository: only normalized remotes (`host.tld/owner/repo`); free keys stay plain text. */
export function repositoryLink(repository: string | null | undefined): string | null {
	const value = (repository ?? '').trim();
	return /^[a-z0-9-]+(\.[a-z0-9-]+)+\/[\w.~-]+(\/[\w.~-]+)+$/i.test(value) ? `https://${value}` : null;
}

/** The contract requires the edit right for PUT; manage includes it. The server enforces the rule either way. */
export function canEditSync(role: Role | null | undefined): boolean {
	return role === 'edit' || role === 'manage';
}

/** Upper limit of repository bindings per project (backend `too_many_bindings`). */
export const MAX_BINDINGS = 10;

export function canAddBinding(count: number): boolean {
	return count < MAX_BINDINGS;
}

/** All bindings of a project; older servers without `bindings` fall back to the flat fields. */
export function bindingList(sync: ProjectSync | null | undefined): ProjectBinding[] {
	if (!sync?.bound) return [];
	if (sync.bindings) return sync.bindings.filter((b) => b.bound !== false);
	const { bindings: _ignored, ...flat } = sync;
	return [flat];
}

const BINDING_REASONS = ['too_many_bindings', 'repository_already_bound', 'not_bound', 'repository_required', 'invalid_repository'];

/** Message key for the known binding errors; `null` leaves the generic error handling. */
export function bindingError(e: unknown): MessageKey | null {
	if (e instanceof ApiError && e.reason && BINDING_REASONS.includes(e.reason)) return `sync.error.${e.reason}` as MessageKey;
	return null;
}
