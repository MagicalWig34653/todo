/**
 * Length of the server's undo window after a person's review decision (`WorkflowLimits.reviewUndoWindow` = 5 * 60 s).
 * The single place on the PWA side: the variant hint text and the expected start of the countdown derive from it, and
 * `tests/reviewVariants.test.ts` compares it with the Swift constant.
 */
export const REVIEW_UNDO_MINUTES = 5;
export const REVIEW_UNDO_WINDOW_MS = REVIEW_UNDO_MINUTES * 60_000;

/** Milliseconds left until `until` (ISO string), 0 when passed or invalid. */
export function undoRemainingMs(until: string | null | undefined, now: number = Date.now()): number {
	if (!until) return 0;
	const end = Date.parse(until);
	return Number.isFinite(end) ? Math.max(0, end - now) : 0;
}

/** `m:ss` for the light countdown next to the undo button. */
export function formatUndoRemaining(ms: number): string {
	const total = Math.ceil(Math.max(0, ms) / 1000);
	const minutes = Math.floor(total / 60);
	const seconds = total % 60;
	return `${minutes}:${String(seconds).padStart(2, '0')}`;
}
