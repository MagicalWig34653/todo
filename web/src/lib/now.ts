/** Page "Jetzt" (contracts/session-status.yaml): grouping, counters and device-local expand state. Pure and testable. */
import type { MessageKey } from './i18n/de.js';
import { t } from './i18n/index.js';
import type { CardRef } from './cardRef.js';
import type { BuildStatus, CommandSummary, NowActive, NowBlock, NowDone, NowWaiting, OverviewBuild, OverviewNow, OverviewProject, OverviewRunningTask, OverviewSession } from './api.js';

export const QUIET_AFTER_MS = 24 * 3600 * 1000;
export const ORPHAN_AFTER_SECONDS = 30 * 60;
/** Without live hints (old server: 5 s polling from the central service) the page still refetches at most every 30 s. */
export const MIN_POLL_REFETCH_MS = 30_000;
export const EXPANDED_KEY = 'todo.nowExpanded';

export interface NowStats { running: number; sessions: number; waiting: number; builds: number }
export type ExpandedMap = Record<string, boolean>;
export interface StorageLike { getItem(key: string): string | null; setItem(key: string, value: string): void }

/** Sentences that start with "Beendet" (case-insensitive, after trim) mean the session is over: never shown as running. */
export function isEndedText(text: string | null | undefined): boolean {
	return typeof text === 'string' && text.trim().toLowerCase().startsWith('beendet');
}

/** Sessions of a project without the ended ones. */
export function visibleSessions(p: OverviewProject): OverviewSession[] {
	return p.sessions.filter((s) => !isEndedText(s.activity));
}

export function projectStats(p: OverviewProject): NowStats {
	return { running: p.runningTasks.length, sessions: visibleSessions(p).length, waiting: p.openQuestions.length + p.pendingReviews.length, builds: groupBuilds(p.builds).length };
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
	if (visibleSessions(p).some((s) => s.ageSeconds * 1000 < QUIET_AFTER_MS)) return false;
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

/** Below the block "Jetzt" every row starts closed; without it (old server) the rows are the only view and active ones start open. */
export const defaultExpanded = (quiet: boolean, hasBlock = false): boolean => !quiet && !hasBlock;
export function isExpanded(map: ExpandedMap, id: string, quiet: boolean, hasBlock = false): boolean {
	return typeof map[id] === 'boolean' ? map[id]! : defaultExpanded(quiet, hasBlock);
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
export function percentOf(task: OverviewRunningTask | NowActive): number | null {
	const v = task.percent;
	return typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : null;
}

export function buildSummary(b: Partial<OverviewBuild> & { buildID: string }): string {
	return [b.label, b.platform].filter((x): x is string => !!x).join(' · ') || b.buildID;
}

/** First 7 characters of the optional build commit, otherwise null. */
export function buildCommit(b: Partial<OverviewBuild>): string | null {
	const c = typeof b.commit === 'string' ? b.commit.trim() : '';
	return c ? c.slice(0, 7) : null;
}

/** The server sends at most this many build files per project (contracts/session-status.yaml). */
export const BUILD_FILE_LIMIT = 5;

/** One build of one platform; `files` counts its artifacts (screenshots) in the answer. */
export interface BuildGroup {
	key: string;
	buildID: string;
	platform: string | null;
	label: string | null;
	status: BuildStatus | null;
	commit: string | null;
	createdAt: string;
	files: number;
}

/** Builds by `buildID` and platform, newest first; label, status and commit come from the newest file that has one. */
export function groupBuilds(builds: readonly OverviewBuild[]): BuildGroup[] {
	const at = (b: OverviewBuild) => new Date(b.createdAt).getTime() || 0;
	const groups = new Map<string, BuildGroup>();
	for (const b of [...builds].sort((x, y) => at(y) - at(x))) {
		const key = JSON.stringify([b.buildID, b.platform || '']);
		const g = groups.get(key);
		if (!g) {
			groups.set(key, { key, buildID: b.buildID, platform: b.platform || null, label: b.label || null, status: b.status ?? null, commit: b.commit || null, createdAt: b.createdAt, files: 1 });
			continue;
		}
		g.files += 1;
		g.label ??= b.label || null;
		g.status ??= b.status ?? null;
		g.commit ??= b.commit || null;
	}
	return [...groups.values()];
}

export type BuildStatusTone = 'info' | 'ok' | 'danger';
const BUILD_STATUS = {
	building: { key: 'build.status.building', tone: 'info' },
	succeeded: { key: 'build.status.succeeded', tone: 'ok' },
	failed: { key: 'build.status.failed', tone: 'danger' }
} as const;
/** Message key and tone for a reported build status; null when none (or an unknown one) was reported. */
export function buildStatusOf(status: string | null | undefined): { key: (typeof BUILD_STATUS)[keyof typeof BUILD_STATUS]['key']; tone: BuildStatusTone } | null {
	return status && Object.hasOwn(BUILD_STATUS, status) ? BUILD_STATUS[status as keyof typeof BUILD_STATUS] : null;
}

/** Message key and params of the head of a build status line: "Build <label>:" or "Build:" without a label. */
export function buildEventHead(label: string | null | undefined): [key: MessageKey, params?: Record<string, string | number>] {
	const l = typeof label === 'string' ? label.trim() : '';
	return l ? ['build.event.titled', { label: l }] : ['build.event.untitled'];
}

/** First 7 characters of a commit, otherwise null. */
export function shortCommit(commit: string | null | undefined): string | null {
	const c = typeof commit === 'string' ? commit.trim() : '';
	return c ? c.slice(0, 7) : null;
}

export const isEmptyNow = (projects: readonly OverviewProject[] | undefined): boolean => !projects || projects.length === 0;

export function allowRefetch(lastFetchAt: number | null, now: number, mode: 'live' | 'poll' | 'idle' | 'unauthorized'): boolean {
	if (lastFetchAt === null || mode !== 'poll') return true;
	return now - lastFetchAt >= MIN_POLL_REFETCH_MS;
}

// ---- Block "Jetzt" (contract session-status 1.4.0, field `now`) ----

export const NOW_DONE_LIMIT = 5;
export const NOW_DONE_WINDOW_MS = 6 * 3600 * 1000;

const MINUTE = 60;
const HOUR = 3600;
const DAY = 86400;

/** "weniger als 1 Min.", "12 Min.", "3 Std.", "2 Tg." */
export function durationText(seconds: number): string {
	const s = Number.isFinite(seconds) ? Math.max(0, seconds) : 0;
	if (s < MINUTE) return t('now.duration.lessThanMinute');
	if (s < HOUR) return t('now.duration.minutes', { count: Math.floor(s / MINUTE) });
	if (s < DAY) return t('now.duration.hours', { count: Math.floor(s / HOUR) });
	return t('now.duration.days', { count: Math.floor(s / DAY) });
}

const secondsSince = (iso: string | undefined, ref: Date): number | null => {
	const ms = iso ? new Date(iso).getTime() : NaN;
	return Number.isNaN(ms) ? null : Math.max(0, (ref.getTime() - ms) / 1000);
};

/** Reference time for relative texts: the server clock, kept running between fetches (no dependence on the device clock). */
export function serverClock(serverTime: string, fetchedAtMs: number, nowMs: number): Date {
	const server = new Date(serverTime).getTime();
	const elapsed = Math.max(0, nowMs - fetchedAtMs);
	return new Date(Number.isNaN(server) ? nowMs : server + elapsed);
}

/** "Lebenszeichen vor 12 Min." (or "gerade eben" below 30 s). */
export function lifeSignText(item: Pick<NowActive, 'lastSignAt' | 'ageSeconds'>, ref: Date): string {
	const age = secondsSince(item.lastSignAt, ref) ?? item.ageSeconds;
	return age < 30 ? t('now.block.lifeSignNow') : t('now.block.lifeSign', { duration: durationText(age) });
}

/** "seit 20 Min." for a card with a known start, otherwise ''. */
export function sinceText(item: Pick<NowActive, 'since'>, ref: Date): string {
	const age = secondsSince(item.since, ref);
	return age === null ? '' : t('now.block.since', { duration: durationText(age) });
}

const dueFormat = () => new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
/** Due date for the list: "Frist 25.11., 10:30" or "Überfällig seit 2 Tg."; null without a (valid) due date. */
export function dueInfo(dueAt: string | undefined, ref: Date): { text: string; overdue: boolean } | null {
	const ms = dueAt ? new Date(dueAt).getTime() : NaN;
	if (Number.isNaN(ms)) return null;
	if (ms < ref.getTime()) return { overdue: true, text: t('now.block.overdue', { duration: durationText((ref.getTime() - ms) / 1000) }) };
	return { overdue: false, text: t('now.block.due', { date: dueFormat().format(new Date(ms)) }) };
}

const doneTime = (d: NowDone) => new Date(d.doneAt).getTime();
const withinDoneWindow = (d: NowDone, ref: Date) => !Number.isNaN(doneTime(d)) && ref.getTime() - doneTime(d) <= NOW_DONE_WINDOW_MS;

/** Cards done in the last 6 hours, newest first, at most 5 visible. */
export function recentDone(list: readonly NowDone[], ref: Date): NowDone[] {
	return list
		.filter((d) => withinDoneWindow(d, ref))
		.sort((a, b) => doneTime(b) - doneTime(a))
		.slice(0, NOW_DONE_LIMIT);
}

/** Defensive copy of the block: ended sessions never count as running or silent (the server already omits them). */
export function cleanBlock(b: NowBlock): NowBlock {
	const keep = (i: NowActive) => !(i.kind === 'session' && isEndedText(i.text));
	const running = b.running.filter(keep);
	const silent = b.silent.filter(keep);
	return {
		...b,
		running,
		silent,
		counts: {
			...b.counts,
			running: Math.max(0, b.counts.running - (b.running.length - running.length)),
			silent: Math.max(0, b.counts.silent - (b.silent.length - silent.length))
		}
	};
}

/** The block as the view shows it, or null for an old server without `now` (then only the project sections appear). */
export function blockOf(data: OverviewNow | null, ref: Date): NowBlock | null {
	if (!data?.now) return null;
	const b = cleanBlock(data.now);
	// The total follows the server; only entries that left the 6 hour window since the answer are taken off.
	const aged = b.recentlyDone.filter((d) => !withinDoneWindow(d, ref)).length;
	const recentlyDone = recentDone(b.recentlyDone, ref);
	return { ...b, recentlyDone, counts: { ...b.counts, recentlyDone: Math.max(recentlyDone.length, b.counts.recentlyDone - aged) } };
}

export type NowTileID = 'waiting' | 'running' | 'done' | 'silent';
/** The four numbers on top of the page, in display order. */
export function nowTiles(b: NowBlock): { id: NowTileID; count: number }[] {
	return [
		{ id: 'waiting', count: b.counts.waiting },
		{ id: 'running', count: b.counts.running },
		{ id: 'done', count: b.counts.recentlyDone },
		{ id: 'silent', count: b.counts.silent }
	];
}

/** Entries the server counted but did not send (its lists are cut). */
export const notListed = (counted: number, delivered: number): number => Math.max(0, counted - delivered);

export const NOW_WAITING_FIRST = 5;
export const NOW_EVENTS_FIRST = 5;

const blockHasContent = (b: NowBlock) => b.running.length + b.waiting.length + b.recentlyDone.length + b.silent.length + b.counts.silent > 0;
/** The page-wide empty state: no project content and nothing in the block. */
export function showEmptyPage(data: OverviewNow, block: NowBlock | null): boolean {
	return isEmptyNow(data.projects) && !(block && blockHasContent(block));
}

/** Card detail target of a waiting entry, like the project lists: question to answer, review to look at. */
export function waitingCard(w: Pick<NowWaiting, 'kind' | 'id' | 'taskID'>): CardRef {
	return w.kind === 'review' ? { type: 'review', id: w.taskID } : { type: 'question', id: w.id };
}

export interface NowEntry { running: number | null; waiting: number | null }
/**
 * Counters for the shortcut on the start page; null while unknown (old server, not loaded). "Waiting for you" counts what
 * concerns this account, like the navigation counter, when the command center summary says so (the page itself shows all).
 */
export function nowEntry(block: NowBlock | undefined | null, summary?: Pick<CommandSummary, 'concerningQuestions' | 'concerningReviews'> | null): NowEntry {
	if (!block) return { running: null, waiting: null };
	const { concerningQuestions: questions, concerningReviews: reviews } = summary ?? {};
	return { running: block.counts.running, waiting: questions !== undefined && reviews !== undefined ? questions + reviews : block.counts.waiting };
}
export function nowEntryLabel(e: NowEntry): string {
	if (e.running === null) return '';
	if (e.running === 0) return t('now.entry.none');
	return e.running === 1 ? t('now.entry.runningOne') : t('now.entry.running', { count: e.running });
}
