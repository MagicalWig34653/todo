import { describe, expect, it } from 'vitest';
import { mergePlanning, type PlanningForm } from '../src/lib/planning-merge.js';

const base: PlanningForm = { due: '2026-11-02T10:00', planned: '', priority: 0, frequency: 'none', interval: 1, until: '', reminders: [] };

describe('mergePlanning', () => {
	it('adopts server changes in untouched fields', () => {
		const r = mergePlanning(base, { ...base, priority: 2 }, { ...base, due: '2026-11-05T10:00' });
		expect(r.form.due).toBe('2026-11-05T10:00');
		expect(r.form.priority).toBe(2);
		expect(r.conflicts).toEqual([]);
	});
	it('keeps local edits and reports a conflict when both sides changed a field differently', () => {
		const server = { ...base, due: '2026-11-05T10:00' };
		const r = mergePlanning(base, { ...base, due: '2026-11-09T10:00' }, server);
		expect(r.form.due).toBe('2026-11-09T10:00');
		expect(r.conflicts).toEqual(['due']);
		// Saving again is a knowing overwrite: no further conflict.
		expect(mergePlanning(r.base, r.form, server).conflicts).toEqual([]);
	});
	it('is no conflict when both sides made the same change', () => {
		expect(mergePlanning(base, { ...base, priority: 3 }, { ...base, priority: 3 }).conflicts).toEqual([]);
	});
	it('compares reminder lists by content', () => {
		const r = mergePlanning(base, { ...base, reminders: ['b'] }, { ...base, reminders: ['a'] });
		expect(r.conflicts).toEqual(['reminders']);
	});
});
