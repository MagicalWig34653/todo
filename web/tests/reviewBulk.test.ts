import { describe, expect, it } from 'vitest';
import {
	BATCH_MAX,
	bulkSelectable,
	failureCodes,
	pruneSelection,
	reasonCode,
	selectableReviews,
	variantBlockedCount,
	selectAllVisible,
	selectionState,
	toggleSelection,
	type BatchResponse
} from '../src/lib/reviewBulk.js';

const ids = (n: number) => Array.from({ length: n }, (_, i) => `r${i}`);

describe('review selection', () => {
	it('toggles one id without touching the others', () => {
		const a = toggleSelection(new Set(['x']), 'y');
		expect([...a].sort()).toEqual(['x', 'y']);
		expect([...toggleSelection(a, 'x')]).toEqual(['y']);
	});
	it('selects only the visible (filtered) ones', () => {
		expect([...selectAllVisible(ids(3))].sort()).toEqual(['r0', 'r1', 'r2']);
	});
	it('caps the selection at the batch limit', () => {
		expect(selectAllVisible(ids(80)).size).toBe(BATCH_MAX);
		const full = new Set(ids(BATCH_MAX));
		expect(toggleSelection(full, 'extra').has('extra')).toBe(false);
		expect(toggleSelection(full, 'r0').has('r0')).toBe(false);
	});
	it('prunes ids that are no longer listed (decided elsewhere, filtered out)', () => {
		expect([...pruneSelection(new Set(['a', 'b', 'c']), ['b', 'c', 'd'])].sort()).toEqual(['b', 'c']);
	});
	it('reports none / some / all for the select-all control', () => {
		expect(selectionState(new Set(), ids(3))).toBe('none');
		expect(selectionState(new Set(['r0']), ids(3))).toBe('some');
		expect(selectionState(new Set(ids(3)), ids(3))).toBe('all');
		expect(selectionState(new Set(), [])).toBe('none');
		// The cap counts as "all" when every selectable row is selected.
		expect(selectionState(new Set(ids(BATCH_MAX)), ids(80))).toBe('all');
	});
});

describe('batch result', () => {
	const res: BatchResponse = {
		decision: 'accept',
		summary: { ok: 2, forbidden: 1, notFound: 0, alreadyDecided: 1, invalid: 0 },
		results: [
			{ reviewID: 'a', result: 'ok' },
			{ reviewID: 'b', result: 'forbidden', reason: 'not_the_reviewer' },
			{ reviewID: 'c', result: 'already_decided' },
			{ reviewID: 'd', result: 'ok' }
		]
	};
	it('lists only the entries that did not succeed, in order', () => {
		expect(failureCodes(res).map((f) => [f.reviewID, f.result])).toEqual([
			['b', 'forbidden'],
			['c', 'already_decided']
		]);
	});
});

describe('reviews with variants in the bulk selection', () => {
	const plain = { id: 'p1' };
	const variants = { id: 'v1', variants: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }] };
	it('are not selectable for accepting; reviews without variants are', () => {
		expect(bulkSelectable(plain)).toBe(true);
		expect(bulkSelectable(variants)).toBe(false);
		expect(bulkSelectable({ id: 'x', variants: null })).toBe(true);
		expect(selectableReviews([plain, variants, { id: 'p2' }]).map((r) => r.id)).toEqual(['p1', 'p2']);
	});
	it('counts the ones that need a choice', () => {
		expect(variantBlockedCount([plain, variants, { ...variants, id: 'v2' }])).toBe(2);
		expect(variantBlockedCount([plain])).toBe(0);
	});
	it('select-all over the selectable ones never takes a variants review', () => {
		const sel = selectAllVisible(selectableReviews([plain, variants]).map((r) => r.id));
		expect([...sel]).toEqual(['p1']);
		expect(selectionState(sel, ['p1'])).toBe('all');
	});
	it('refines an invalid result with reason variant_required into its own code', () => {
		expect(reasonCode({ reviewID: 'v1', result: 'invalid', reason: 'variant_required' })).toBe('variant_required');
		expect(reasonCode({ reviewID: 'v1', result: 'invalid', reason: 'other' })).toBe('invalid');
		expect(reasonCode({ reviewID: 'b', result: 'forbidden', reason: 'not_the_reviewer' })).toBe('not_the_reviewer');
		expect(reasonCode({ reviewID: 'b', result: 'forbidden', reason: 'weird' })).toBe('forbidden');
		expect(reasonCode({ reviewID: 'c', result: 'already_decided' })).toBe('already_decided');
	});
});
