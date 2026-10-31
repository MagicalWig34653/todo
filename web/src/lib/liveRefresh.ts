/** Live refresh for comments and activity: no sync feed exists for these objects, so views refetch silently. */
export const LIVE_REFRESH_MS = 30_000;

interface LiveOptions {
	intervalMs?: number;
	doc?: Pick<Document, 'visibilityState' | 'addEventListener' | 'removeEventListener'>;
	win?: Pick<Window, 'addEventListener' | 'removeEventListener'>;
}

/**
 * Calls `refresh` when the page regains focus or becomes visible and every `intervalMs` while visible.
 * Overlapping runs are skipped, failures are swallowed (a background refetch must never raise a notice).
 * Returns the stop function.
 */
export function startLiveRefresh(refresh: () => Promise<unknown> | unknown, opts: LiveOptions = {}): () => void {
	const doc = opts.doc ?? document;
	const win = opts.win ?? window;
	let running = false;
	const run = async () => {
		if (running || doc.visibilityState !== 'visible') return;
		running = true;
		try {
			await refresh();
		} catch {
			/* silent: the next tick retries */
		} finally {
			running = false;
		}
	};
	const timer = setInterval(run, opts.intervalMs ?? LIVE_REFRESH_MS);
	win.addEventListener('focus', run);
	doc.addEventListener('visibilitychange', run);
	return () => {
		clearInterval(timer);
		win.removeEventListener('focus', run);
		doc.removeEventListener('visibilitychange', run);
	};
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
