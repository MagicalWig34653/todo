import { describe, expect, it } from 'vitest';
import { formatUndoRemaining, undoRemainingMs } from '../src/lib/reviewUndo.js';

describe('review undo window', () => {
	const now = Date.parse('2026-11-02T12:00:00Z');
	it('computes the remaining time and never goes negative', () => {
		expect(undoRemainingMs('2026-11-02T12:04:30Z', now)).toBe(270_000);
		expect(undoRemainingMs('2026-11-02T11:59:00Z', now)).toBe(0);
		expect(undoRemainingMs(null, now)).toBe(0);
		expect(undoRemainingMs('garbage', now)).toBe(0);
	});
	it('formats m:ss', () => {
		expect(formatUndoRemaining(270_000)).toBe('4:30');
		expect(formatUndoRemaining(5_000)).toBe('0:05');
		expect(formatUndoRemaining(-1)).toBe('0:00');
	});
});
