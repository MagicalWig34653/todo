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
