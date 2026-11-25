import { describe, expect, it } from 'vitest';
import type { PlanningTask } from '../src/lib/api.js';
import { mergePlanning, planningForm, type PlanningForm } from '../src/lib/planning-merge.js';

const base: PlanningForm = {
	due: '2026-11-02T10:00',
	planned: '',
	priority: 0,
	frequency: 'none',
	interval: 1,
	until: '',
	weekdays: [],
	basis: 'due',
	monthDay: null,
	reminders: []
};

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

describe('planningForm with the extended recurrence', () => {
	const pt = (recurrence: PlanningTask['recurrence']): PlanningTask => ({
		task: { id: 't', projectID: 'p', title: 't', description: '', status: 'open', version: 1 },
		position: 0,
		priority: 0,
		recurrence,
		reminders: []
	});
	it('gives neutral defaults for no rule and for an old rule', () => {
		expect(planningForm(pt(null))).toMatchObject({ frequency: 'none', weekdays: [], basis: 'due', monthDay: null });
		expect(planningForm(pt({ frequency: 'weekly', interval: 2, timeZone: 'UTC' }))).toMatchObject({ frequency: 'weekly', interval: 2, weekdays: [], basis: 'due', monthDay: null });
	});
	it('carries the new fields into the form', () => {
		expect(planningForm(pt({ frequency: 'weekly', interval: 1, timeZone: 'UTC', weekdays: [4, 1], basis: 'completion' }))).toMatchObject({ weekdays: [1, 4], basis: 'completion', monthDay: null });
		expect(planningForm(pt({ frequency: 'monthly', interval: 1, timeZone: 'UTC', monthDay: 31 }))).toMatchObject({ monthDay: 31 });
	});
	it('reports a conflict when both sides changed the weekdays differently', () => {
		const r = mergePlanning(base, { ...base, frequency: 'weekly', weekdays: [1] }, { ...base, frequency: 'weekly', weekdays: [4] });
		expect(r.conflicts).toEqual(['weekdays']);
		expect(r.form.weekdays).toEqual([1]);
	});
	it('adopts newer server weekdays in an untouched form', () => {
		const r = mergePlanning(base, base, { ...base, frequency: 'weekly', weekdays: [1, 4], basis: 'completion' });
		expect(r.form).toMatchObject({ frequency: 'weekly', weekdays: [1, 4], basis: 'completion' });
		expect(r.conflicts).toEqual([]);
	});
});
