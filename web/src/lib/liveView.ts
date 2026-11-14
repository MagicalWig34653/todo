import type { LiveEvent, LiveSession } from '#lib/api.js';
import { newerThan } from '#lib/liveRefresh.js';

/** Live view of a card (ADR 0031, contracts/live-session.yaml): pure helpers, no DOM. */

/** Active sessions first, ended ones apart; the server order (most recently active first) is kept inside each group. */
export function splitSessions(sessions: readonly LiveSession[]): { active: LiveSession[]; ended: LiveSession[] } {
	return { active: sessions.filter((s) => s.status === 'active'), ended: sessions.filter((s) => s.status !== 'active') };
}

/**
 * Folds a freshly fetched newest page into the loaded events (newest first). New events go in front, older pages that were
 * loaded with "Mehr laden" stay in place together with their cursor; without a shared event (gap) the list restarts from the page.
 */
export function mergeNewest(
	existing: readonly LiveEvent[],
	existingNext: string | null,
	page: readonly LiveEvent[],
	pageNext: string | null
): { items: LiveEvent[]; next: string | null } {
	if (existing.length === 0) return { items: [...page], next: pageNext };
	const { fresh, gap } = newerThan(existing, page);
	if (gap) return { items: [...page], next: pageNext };
	if (fresh.length === 0) return { items: [...existing], next: existingNext };
	return { items: [...fresh, ...existing], next: existingNext };
}

/** Appends an older page ("Mehr laden"); events that are already known (a refresh raced the click) are dropped. */
export function appendOlder(existing: readonly LiveEvent[], page: readonly LiveEvent[]): LiveEvent[] {
	const known = new Set(existing.map((e) => e.id));
	return [...existing, ...page.filter((e) => !known.has(e.id))];
}

/** Message key of an event kind; unknown kinds from a newer server fall back to the generic label. */
export function liveKindKey(kind: string): 'live.kind.step' | 'live.kind.tool' | 'live.kind.note' | 'live.kind.question' | 'live.kind.progress' | 'live.kind.other' {
	switch (kind) {
		case 'step':
		case 'tool':
		case 'note':
		case 'question':
		case 'progress':
			return `live.kind.${kind}`;
		default:
			return 'live.kind.other';
	}
}

/** Clock time of today ("14:05") or date and time for older moments; empty for invalid input. */
export function absoluteWhen(iso: string | null | undefined, now = new Date(), locale = 'de-DE'): string {
	if (!iso) return '';
	const d = new Date(iso);
	if (Number.isNaN(d.getTime())) return '';
	const sameDay = d.toDateString() === now.toDateString();
	return new Intl.DateTimeFormat(locale, sameDay ? { timeStyle: 'short' } : { dateStyle: 'medium', timeStyle: 'short' }).format(d);
}

/** An active session without a sign of life for this long counts as silent (same threshold as the server's `stale`). */
export const STALE_AFTER_MS = 15 * 60_000;

/** Server flag or, between two refreshes, the local clock: a session can turn silent without any event (and so without a refresh). */
export function isStale(s: Pick<LiveSession, 'status' | 'stale' | 'lastSeenAt'>, now = Date.now()): boolean {
	if (s.status !== 'active') return false;
	if (s.stale) return true;
	const seen = new Date(s.lastSeenAt).getTime();
	return !Number.isNaN(seen) && now - seen > STALE_AFTER_MS;
}

/** Silence as a count and unit (minutes below an hour, hours below a day), never below one minute. */
export function quietFor(lastSeenAt: string, now = Date.now()): { unit: 'minutes' | 'hours' | 'days'; count: number } {
	const ms = Math.max(0, now - new Date(lastSeenAt).getTime());
	const min = Math.max(1, Math.floor(ms / 60_000));
	if (min < 60) return { unit: 'minutes', count: min };
	const hours = Math.floor(min / 60);
	return hours < 24 ? { unit: 'hours', count: hours } : { unit: 'days', count: Math.floor(hours / 24) };
}

/** Cheap structural equality for the small live payload, used to skip assignments that would re-render without a change. */
export function sameLive<T>(a: readonly T[], b: readonly T[]): boolean {
	return a.length === b.length && JSON.stringify(a) === JSON.stringify(b);
}
