import { describe, expect, it } from 'vitest';
import { priorityTag, priorityTone } from '../src/lib/planning';

describe('priority display', () => {
	it('maps the stored 0..3 to P4..P1', () => {
		expect([0, 1, 2, 3].map(priorityTag)).toEqual(['P4', 'P3', 'P2', 'P1']);
	});
	it('clamps out-of-range and invalid values', () => {
		expect(priorityTag(9)).toBe('P1');
		expect(priorityTag(-2)).toBe('P4');
		expect(priorityTag(Number.NaN)).toBe('P4');
	});
	it('colours only real priorities', () => {
		expect(priorityTone(3)).toContain('destructive');
		expect(priorityTone(0)).toContain('muted');
	});
});
