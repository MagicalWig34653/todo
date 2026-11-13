import { describe, expect, it } from 'vitest';
import {
	BATCH_MAX,
	failureCodes,
	pruneSelection,
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
