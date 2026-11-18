/** Bulk release of reviews (card 9791E2C3): selection rules and the shape of the batch answer. Pure, no DOM. */

import { hasVariants } from './reviewVariants.js';

/** Server ceiling of `POST /v1/reviews/decisions`. */
export const BATCH_MAX = 50;

export type BatchResultCode = 'ok' | 'forbidden' | 'not_found' | 'already_decided' | 'invalid';
export interface BatchItem {
	reviewID: string;
	result: BatchResultCode;
	reason?: string | null;
}
export interface BatchResponse {
	decision: string;
	results: BatchItem[];
	summary: { ok: number; forbidden: number; notFound: number; alreadyDecided: number; invalid: number };
}

export function toggleSelection(sel: ReadonlySet<string>, id: string): Set<string> {
	const next = new Set(sel);
	if (next.has(id)) next.delete(id);
	else if (next.size < BATCH_MAX) next.add(id);
	return next;
}

/** Selects the visible (filtered) rows only, at most `BATCH_MAX`; hidden rows are never selected by this. */
export function selectAllVisible(visibleIDs: readonly string[]): Set<string> {
	return new Set(visibleIDs.slice(0, BATCH_MAX));
}

/** Drops ids that are not listed any more (decided elsewhere, filtered out, refreshed away). */
export function pruneSelection(sel: ReadonlySet<string>, visibleIDs: readonly string[]): Set<string> {
	const shown = new Set(visibleIDs);
	return new Set([...sel].filter((id) => shown.has(id)));
}

export function selectionState(sel: ReadonlySet<string>, visibleIDs: readonly string[]): 'none' | 'some' | 'all' {
	const selectable = visibleIDs.slice(0, BATCH_MAX);
	const chosen = selectable.filter((id) => sel.has(id)).length;
	if (chosen === 0) return 'none';
	return chosen === selectable.length ? 'all' : 'some';
}

/** A review with variants needs a deliberate choice, so the bulk bar cannot accept it (the server refuses with `variant_required`). */
export const bulkSelectable = (review: { id?: string; variants?: unknown }): boolean => !hasVariants(review);

export function selectableReviews<T extends { id?: string; variants?: unknown }>(reviews: readonly T[]): T[] {
	return reviews.filter(bulkSelectable);
}

export const variantBlockedCount = (reviews: readonly { id?: string; variants?: unknown }[]): number => reviews.filter((r) => !bulkSelectable(r)).length;

/** Stable i18n suffix of a failed batch entry: the result, refined by the single-decision reason where the UI has a plainer wording. */
export function reasonCode(f: BatchItem): string {
	if (f.result === 'forbidden' && (f.reason === 'not_the_reviewer' || f.reason === 'cannot_decide_own_review')) return f.reason;
	if (f.result === 'invalid' && f.reason === 'variant_required') return 'variant_required';
	return f.result;
}

/** Entries that did not succeed, in request order. */
export function failureCodes(res: BatchResponse): BatchItem[] {
	return res.results.filter((r) => r.result !== 'ok');
}
