/** Page "Jetzt" (contracts/session-status.yaml): grouping, counters and device-local expand state. Pure and testable. */
import type { OverviewBuild, OverviewProject, OverviewRunningTask, OverviewSession } from './api.js';

export const QUIET_AFTER_MS = 24 * 3600 * 1000;
export const ORPHAN_AFTER_SECONDS = 30 * 60;
/** Without live hints (old server: 5 s polling from the central service) the page still refetches at most every 30 s. */
export const MIN_POLL_REFETCH_MS = 30_000;
export const EXPANDED_KEY = 'todo.nowExpanded';

export interface NowStats { running: number; sessions: number; waiting: number; builds: number }
export type ExpandedMap = Record<string, boolean>;
export interface StorageLike { getItem(key: string): string | null; setItem(key: string, value: string): void }

export function projectStats(p: OverviewProject): NowStats {
	return { running: p.runningTasks.length, sessions: p.sessions.length, waiting: p.openQuestions.length + p.pendingReviews.length, builds: p.builds.length };
}

const timeOf = (p: OverviewProject) => {
	const ms = new Date(p.lastActivityAt).getTime();
	return Number.isNaN(ms) ? -Infinity : ms;
};

const waitingOf = (p: OverviewProject) => p.openQuestions.length + p.pendingReviews.length;

/**
 * Quiet = nothing running, no open question/review, no session younger than 24 h and no activity for 24 h.
 * A project that waits for the user is never quiet.
 */
export function isQuiet(p: OverviewProject, now: Date): boolean {
	if (p.runningTasks.length > 0 || waitingOf(p) > 0) return false;
	if (p.sessions.some((s) => s.ageSeconds * 1000 < QUIET_AFTER_MS)) return false;
	return now.getTime() - timeOf(p) > QUIET_AFTER_MS;
}

/** Active: waiting projects first (most waiting items, then newest), then the rest newest first. Quiet: newest first. */
export function groupProjects(projects: readonly OverviewProject[], now: Date): { active: OverviewProject[]; quiet: OverviewProject[] } {
	const byTime = (a: OverviewProject, b: OverviewProject) => timeOf(b) - timeOf(a);
	const byWaiting = (a: OverviewProject, b: OverviewProject) => {
		const wa = waitingOf(a), wb = waitingOf(b);
		if ((wa > 0) !== (wb > 0)) return wa > 0 ? -1 : 1;
		return wb - wa || byTime(a, b);
	};
	const quiet = projects.filter((p) => isQuiet(p, now)).sort(byTime);
	const active = projects.filter((p) => !isQuiet(p, now)).sort(byWaiting);
	return { active, quiet };
}

export const defaultExpanded = (quiet: boolean): boolean => !quiet;
export function isExpanded(map: ExpandedMap, id: string, quiet: boolean): boolean {
	return typeof map[id] === 'boolean' ? map[id]! : defaultExpanded(quiet);
}

const defaultStorage = (): StorageLike | null => {
	try {
		return typeof localStorage === 'undefined' ? null : localStorage;
	} catch {
		return null;
	}
};

export function loadExpanded(storage: StorageLike | null = defaultStorage()): ExpandedMap {
	try {
		const raw = storage?.getItem(EXPANDED_KEY);
		if (!raw) return {};
		const parsed: unknown = JSON.parse(raw);
		if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
		return Object.fromEntries(Object.entries(parsed).filter(([, v]) => typeof v === 'boolean')) as ExpandedMap;
	} catch {
		return {};
	}
}

export function saveExpanded(map: ExpandedMap, storage: StorageLike | null = defaultStorage()): void {
	try {
		storage?.setItem(EXPANDED_KEY, JSON.stringify(map));
	} catch {
		/* storage unavailable: the choice only lasts for this page view */
	}
}

export const isOrphaned = (s: OverviewSession): boolean => s.orphaned || s.ageSeconds > ORPHAN_AFTER_SECONDS;

/** 0..100 when the server reports a percentage, otherwise null (no bar). */
export function percentOf(task: OverviewRunningTask): number | null {
	const v = task.percent;
	return typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : null;
}

export function buildSummary(b: OverviewBuild): string {
	return [b.label, b.platform].filter((x): x is string => !!x).join(' · ') || b.buildID;
}

/** First 7 characters of the optional build commit, otherwise null. */
export function buildCommit(b: OverviewBuild): string | null {
	const c = typeof b.commit === 'string' ? b.commit.trim() : '';
	return c ? c.slice(0, 7) : null;
}

export const isEmptyNow = (projects: readonly OverviewProject[]): boolean => projects.length === 0;

export function allowRefetch(lastFetchAt: number | null, now: number, mode: 'live' | 'poll' | 'idle' | 'unauthorized'): boolean {
	if (lastFetchAt === null || mode !== 'poll') return true;
	return now - lastFetchAt >= MIN_POLL_REFETCH_MS;
}
