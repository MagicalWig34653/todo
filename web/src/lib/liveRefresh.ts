/**
 * Central live refresh (ADR 0022, contracts/live-refresh.yaml). One service per tab:
 *  - capabilities.liveRefresh present: head token + long-poll (`/v1/sync/wait`), one waiting tab per browser (Web Locks leader,
 *    BroadcastChannel to the other tabs), only while the tab is visible;
 *  - otherwise (old server, disabled, 404): every 5 s while visible all subscribers refetch their existing routes.
 * The service only sends hints; views register what they reload with `subscribe` and replace their data only when it changed.
 */
export const POLL_MS = 5_000;
export const BUNDLE_MS = 1_000;
const WAIT_SECONDS = 25;
const CLIENT_TIMEOUT_MS = 35_000;
const LOCK_NAME = 'todolino-live-leader';
const CHANNEL_NAME = 'todolino-live';

export interface SubscribeOptions {
	/** Skip while the user is typing into a field that holds text or edits inline (retried every second). */
	guardEditing?: boolean;
}

interface Sub {
	fn: () => Promise<unknown> | unknown;
	guardEditing: boolean;
	running: boolean;
	again: boolean;
	deferred: boolean;
}

interface LockManagerLike {
	request(name: string, options: { signal?: AbortSignal }, cb: () => Promise<unknown>): Promise<unknown>;
}
interface ChannelLike {
	postMessage(data: unknown): void;
	close(): void;
	onmessage: ((e: { data: unknown }) => void) | null;
}
type DocLike = Pick<Document, 'visibilityState' | 'addEventListener' | 'removeEventListener'> & Partial<Pick<Document, 'activeElement' | 'querySelector'>>;

export interface LiveEnv {
	fetch: (input: string, init?: RequestInit) => Promise<Response>;
	doc: DocLike;
	locks: LockManagerLike | null;
	channel: ((name: string) => ChannelLike | null) | null;
	random: () => number;
	/** Called when the server answers 401 (session ended). */
	onUnauthorized: () => void;
}

export type LiveMode = 'idle' | 'live' | 'poll' | 'unauthorized';

export function backoffDelay(failures: number, random: () => number = Math.random): number {
	const base = Math.min(30_000, 1_000 * 2 ** Math.max(0, failures - 1));
	return Math.round(base * (0.5 + random() * 0.5));
}

export function createLiveRefresh(overrides: Partial<LiveEnv> = {}) {
	const env: LiveEnv = {
		fetch: (i, init) => fetch(i, init),
		doc: typeof document === 'undefined' ? (undefined as unknown as DocLike) : document,
		locks: typeof navigator !== 'undefined' && 'locks' in navigator ? (navigator.locks as unknown as LockManagerLike) : null,
		channel: typeof BroadcastChannel === 'undefined' ? null : (n) => new BroadcastChannel(n) as unknown as ChannelLike,
		random: Math.random,
		onUnauthorized: () => undefined,
		...overrides
	};

	const subs = new Set<Sub>();
	let started = false;
	let mode: LiveMode = 'idle';
	let generation = 0;
	let token: string | null = null;
	let headSeconds = 5;
	let waitSeconds = WAIT_SECONDS;
	let lead: AbortController | null = null;
	let channel: ChannelLike | null = null;
	let pollTimer: ReturnType<typeof setInterval> | null = null;
	let bundleTimer: ReturnType<typeof setTimeout> | null = null;
	let deferTimer: ReturnType<typeof setTimeout> | null = null;
	let lastRun = -Infinity;
	let dirty = false;
	let dragging = false;

	const visible = () => env.doc.visibilityState === 'visible';

	// ---- subscribers ---------------------------------------------------------------------------------------------
	function busy(sub: Sub): boolean {
		if (dragging) return true;
		const d = env.doc;
		if (d.querySelector?.('[role="menu"],[role="listbox"],[role="dialog"]')) return true;
		if (!sub.guardEditing) return false;
		const a = d.activeElement as (HTMLElement & { value?: string; type?: string }) | null | undefined;
		if (!a) return false;
		if (a.isContentEditable) return true;
		const tag = a.tagName;
		if (tag === 'TEXTAREA') return !!a.value;
		if (tag === 'INPUT') return !['checkbox', 'radio', 'button', 'submit', 'range', 'file'].includes(a.type ?? 'text') && !!a.value;
		return false;
	}
	async function runSub(sub: Sub) {
		if (sub.running) {
			sub.again = true;
			return;
		}
		if (busy(sub)) {
			sub.deferred = true;
			scheduleDeferred();
			return;
		}
		sub.running = true;
		sub.deferred = false;
		try {
			await sub.fn();
		} catch {
			/* silent: a background refetch must never raise a notice */
		} finally {
			sub.running = false;
			if (sub.again) {
				sub.again = false;
				void runSub(sub);
			}
		}
	}
	function scheduleDeferred() {
		if (deferTimer) return;
		deferTimer = setTimeout(() => {
			deferTimer = null;
			for (const s of subs) if (s.deferred) void runSub(s);
		}, 1_000);
	}
	function runAll() {
		lastRun = Date.now();
		dirty = false;
		for (const s of [...subs]) void runSub(s);
	}
	/** Bundles hints: at most one refresh round per second; hidden tabs remember it and refresh when shown. */
	function requestRefresh() {
		if (!started) return;
		if (!visible()) {
			dirty = true;
			return;
		}
		const wait = lastRun + BUNDLE_MS - Date.now();
		if (wait <= 0) runAll();
		else if (!bundleTimer)
			bundleTimer = setTimeout(() => {
				bundleTimer = null;
				if (started && visible()) runAll();
				else dirty = true;
			}, wait);
	}
	function subscribe(fn: Sub['fn'], opts: SubscribeOptions = {}): () => void {
		const sub: Sub = { fn, guardEditing: !!opts.guardEditing, running: false, again: false, deferred: false };
		subs.add(sub);
		return () => {
			subs.delete(sub);
		};
	}

	// ---- transport -----------------------------------------------------------------------------------------------
	interface Reply {
		status: number;
		body?: Record<string, unknown>;
		retryAfter?: number;
	}
	async function call(path: string, o: { signal?: AbortSignal; headers?: Record<string, string>; timeoutMs: number }): Promise<Reply> {
		const ac = new AbortController();
		const onAbort = () => ac.abort();
		o.signal?.addEventListener('abort', onAbort);
		const timer = setTimeout(() => ac.abort(), o.timeoutMs);
		try {
			if (o.signal?.aborted) return { status: 0 };
			const res = await env.fetch(path, { credentials: 'same-origin', headers: { Accept: 'application/json', ...o.headers }, signal: ac.signal });
			let body: Record<string, unknown> | undefined;
			if (res.status === 200) body = (await res.json()) as Record<string, unknown>;
			const ra = Number(res.headers.get('Retry-After'));
			return { status: res.status, body, retryAfter: Number.isFinite(ra) && ra > 0 ? ra : undefined };
		} catch {
			return { status: 0 };
		} finally {
			clearTimeout(timer);
			o.signal?.removeEventListener('abort', onAbort);
		}
	}
	function sleep(ms: number, signal?: AbortSignal): Promise<void> {
		return new Promise((resolve) => {
			if (signal?.aborted) return resolve();
			const done = () => {
				clearTimeout(t);
				signal?.removeEventListener('abort', done);
				resolve();
			};
			const t = setTimeout(done, ms);
			signal?.addEventListener('abort', done);
		});
	}

	function unauthorized() {
		stopInternal();
		mode = 'unauthorized';
		env.onUnauthorized();
	}
	function broadcast() {
		try {
			channel?.postMessage({ type: 'changed', token });
		} catch {
			/* channel closed */
		}
	}

	type HeadResult = 'changed' | 'same' | 'error';
	/** Cheap token check with If-None-Match. Updates the token; the caller decides about notifying. */
	async function headCheck(signal?: AbortSignal): Promise<HeadResult> {
		const gen = generation;
		const r = await call('/v1/sync/head', { signal, timeoutMs: 10_000, headers: token ? { 'If-None-Match': `"${token}"` } : {} });
		if (gen !== generation || signal?.aborted) return 'same';
		if (r.status === 304) return 'same';
		if (r.status === 200 && typeof r.body?.token === 'string') {
			const first = token === null;
			const changed = r.body.token !== token;
			token = r.body.token;
			return changed && !first ? 'changed' : 'same';
		}
		if (r.status === 401) unauthorized();
		else if (r.status === 404) enterPoll();
		return 'error';
	}

	/** Waits `ms`; every `headSeconds` in between a head check can still surface changes. */
	async function backoff(ms: number, signal: AbortSignal) {
		const end = Date.now() + ms;
		while (!signal.aborted) {
			const left = end - Date.now();
			if (left <= 0) return;
			await sleep(Math.min(left, headSeconds * 1000), signal);
			if (signal.aborted || end - Date.now() <= 0) return;
			if ((await headCheck(signal)) === 'changed') {
				broadcast();
				requestRefresh();
			}
		}
	}

	async function leaderLoop(signal: AbortSignal) {
		let failures = 0;
		while (!signal.aborted && mode === 'live') {
			if (token === null) {
				await headCheck(signal);
				if (token === null && !signal.aborted && mode === 'live') await backoff(backoffDelay(++failures, env.random), signal);
				continue;
			}
			const began = Date.now();
			const r = await call(`/v1/sync/wait?since=${encodeURIComponent(token)}&timeout=${waitSeconds}`, { signal, timeoutMs: CLIENT_TIMEOUT_MS });
			if (signal.aborted) return;
			if (r.status === 200 && r.body) {
				failures = 0;
				const changed = r.body.changed === true;
				if (typeof r.body.token === 'string') token = r.body.token;
				if (changed) {
					broadcast();
					requestRefresh();
				}
				const retry = Number(r.body.retryAfter);
				if (retry > 0) await backoff(retry * 1000, signal);
				else if (!changed && Date.now() - began < 100) await sleep(1_000, signal); // misbehaving server: never spin
			} else if (r.status === 401) return unauthorized();
			else if (r.status === 404) return enterPoll();
			else if (r.status === 429) await backoff((r.retryAfter ?? 5) * 1000, signal);
			else await backoff(backoffDelay(++failures, env.random), signal);
		}
	}

	// ---- leadership (one waiting tab per browser) ----------------------------------------------------------------
	function startLeading() {
		if (lead || !started || mode !== 'live' || !visible()) return;
		const ac = new AbortController();
		lead = ac;
		const run = () => leaderLoop(ac.signal);
		if (env.locks) {
			// Queued while another tab leads; granted when that tab hides, closes or logs out.
			env.locks.request(LOCK_NAME, { signal: ac.signal }, run).catch(() => undefined);
		} else void run();
	}
	function stopLeading() {
		lead?.abort();
		lead = null;
	}

	// ---- fallback polling ----------------------------------------------------------------------------------------
	function enterPoll() {
		if (!started || mode === 'poll') return;
		stopLeading();
		mode = 'poll';
		syncPoll();
	}
	function syncPoll() {
		if (pollTimer) clearInterval(pollTimer);
		pollTimer = null;
		if (mode === 'poll' && visible()) pollTimer = setInterval(() => requestRefresh(), POLL_MS);
	}

	// ---- lifecycle -----------------------------------------------------------------------------------------------
	async function onVisibility() {
		if (!started) return;
		if (!visible()) {
			stopLeading();
			syncPoll();
			return;
		}
		if (mode === 'poll') {
			syncPoll();
			requestRefresh();
		} else if (mode === 'live') {
			const gen = generation;
			const r = await headCheck();
			if (gen !== generation) return;
			if (r === 'changed' || dirty) requestRefresh();
			startLeading();
		}
	}
	const onDragStart = () => {
		dragging = true;
	};
	const onDragEnd = () => {
		dragging = false;
	};
	const visibilityHandler = () => void onVisibility();

	async function init(gen: number) {
		const r = await call('/v1/capabilities', { timeoutMs: 10_000 });
		if (gen !== generation) return;
		const lr = r.status === 200 ? (r.body?.liveRefresh as { head?: boolean; wait?: boolean; pollSeconds?: number; waitMaxSeconds?: number } | undefined) : undefined;
		if (!lr || !lr.head || !lr.wait) {
			mode = 'poll';
			syncPoll();
			return;
		}
		headSeconds = lr.pollSeconds && lr.pollSeconds > 0 ? lr.pollSeconds : 5;
		waitSeconds = Math.max(1, Math.min(WAIT_SECONDS, lr.waitMaxSeconds ?? WAIT_SECONDS));
		mode = 'live';
		await headCheck(); // baseline token; views load their data themselves on mount
		if (gen !== generation || mode !== 'live') return;
		startLeading();
	}

	function start() {
		if (started) return;
		started = true;
		mode = 'idle';
		token = null;
		const gen = ++generation;
		env.doc.addEventListener('visibilitychange', visibilityHandler);
		env.doc.addEventListener('dragstart', onDragStart);
		env.doc.addEventListener('dragend', onDragEnd);
		env.doc.addEventListener('drop', onDragEnd);
		try {
			channel = env.channel?.(CHANNEL_NAME) ?? null;
		} catch {
			channel = null;
		}
		if (channel)
			channel.onmessage = (e) => {
				const d = e.data as { type?: string; token?: string } | null;
				if (d?.type !== 'changed') return;
				if (typeof d.token === 'string') token = d.token;
				requestRefresh();
			};
		void init(gen);
	}
	function stopInternal() {
		started = false;
		generation++;
		stopLeading();
		if (pollTimer) clearInterval(pollTimer);
		if (bundleTimer) clearTimeout(bundleTimer);
		if (deferTimer) clearTimeout(deferTimer);
		pollTimer = bundleTimer = deferTimer = null;
		env.doc.removeEventListener('visibilitychange', visibilityHandler);
		env.doc.removeEventListener('dragstart', onDragStart);
		env.doc.removeEventListener('dragend', onDragEnd);
		env.doc.removeEventListener('drop', onDragEnd);
		if (channel) {
			channel.onmessage = null;
			channel.close();
			channel = null;
		}
		token = null;
		dirty = false;
		dragging = false;
		lastRun = -Infinity;
	}
	function stop() {
		stopInternal();
		mode = 'idle';
	}

	return {
		start,
		stop,
		subscribe,
		/** Asks all subscribers to refetch now (still bundled), e.g. after the user's own write. */
		poke: requestRefresh,
		/** Replaces the 401 handler (the PWA signs the user out). */
		set onUnauthorized(fn: () => void) {
			env.onUnauthorized = fn;
		},
		get mode() {
			return mode;
		},
		get leading() {
			return lead !== null;
		}
	};
}

export const liveRefresh = createLiveRefresh();

/** Registers one view's refetch with the central service; returns the unsubscribe function. */
export function startLiveRefresh(refresh: () => Promise<unknown> | unknown, opts: SubscribeOptions = {}): () => void {
	return liveRefresh.subscribe(refresh, opts);
}

/** Structural equality for small API lists; used to skip assignments that would re-render without a change. */
export function sameList<T>(a: readonly T[], b: readonly T[]): boolean {
	return a.length === b.length && JSON.stringify(a) === JSON.stringify(b);
}

/**
 * Merges a freshly fetched newest page into the loaded list (newest first, immutable entries).
 * `fresh` are the entries not yet shown; `gap` means the page shares no entry with the list, so entries
 * in between may be missing and the caller should reload from the start.
 */
export function newerThan<T extends { id: string }>(existing: readonly T[], page: readonly T[]): { fresh: T[]; gap: boolean } {
	const known = new Set(existing.map((e) => e.id));
	const fresh = page.filter((e) => !known.has(e.id));
	const overlap = fresh.length < page.length;
	return { fresh, gap: existing.length > 0 && page.length > 0 && !overlap };
}
