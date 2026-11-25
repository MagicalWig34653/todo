import { describe, expect, it } from 'vitest';
import type { Recurrence } from '../src/lib/api.js';
import { buildRecurrence } from '../src/lib/planning.js';
import { describeRecurrence, extrasForFrequency, recurrenceExtras, toggleWeekday, WEEKDAYS } from '../src/lib/recurrence.js';

const NEW_KEYS = ['weekdays', 'basis', 'monthDay'];
const keysOf = (r: Recurrence | null) => Object.keys(r ?? {});
const plain = { weekdays: [] as number[], basis: 'due' as const, monthDay: null };

describe('buildRecurrence with the extended rules', () => {
	it('sends several weekdays sorted and unique for weekly', () => {
		const r = buildRecurrence('weekly', 1, '', 'Europe/Berlin', { ...plain, weekdays: [4, 1, 4] });
		expect(r).toEqual({ frequency: 'weekly', interval: 1, timeZone: 'Europe/Berlin', until: null, weekdays: [1, 4] });
	});
	it('drops invalid weekday numbers', () => {
		const r = buildRecurrence('weekly', 1, '', 'UTC', { ...plain, weekdays: [0, 8, 3.5, 2, Number.NaN] });
		expect(r?.weekdays).toEqual([2]);
		expect(keysOf(buildRecurrence('weekly', 1, '', 'UTC', { ...plain, weekdays: [0, 9] }))).not.toContain('weekdays');
	});
	it('sends basis completion for every frequency and never the default', () => {
		for (const f of ['daily', 'weekly', 'monthly'] as const) {
			expect(buildRecurrence(f, 1, '', 'UTC', { ...plain, basis: 'completion' })?.basis).toBe('completion');
			expect(keysOf(buildRecurrence(f, 1, '', 'UTC', { ...plain, basis: 'due' }))).not.toContain('basis');
		}
	});
	it('sends the day of the month only for monthly, clamped to 1..31', () => {
		expect(buildRecurrence('monthly', 1, '', 'UTC', { ...plain, monthDay: 31 })?.monthDay).toBe(31);
		expect(buildRecurrence('monthly', 1, '', 'UTC', { ...plain, monthDay: 0 })?.monthDay).toBe(1);
		expect(buildRecurrence('monthly', 1, '', 'UTC', { ...plain, monthDay: 45 })?.monthDay).toBe(31);
		expect(buildRecurrence('monthly', 1, '', 'UTC', { ...plain, monthDay: 15.7 })?.monthDay).toBe(15);
		expect(keysOf(buildRecurrence('monthly', 1, '', 'UTC', { ...plain, monthDay: null }))).not.toContain('monthDay');
		expect(keysOf(buildRecurrence('monthly', 1, '', 'UTC', { ...plain, monthDay: Number.NaN }))).not.toContain('monthDay');
	});
	it('discards fields that do not fit the frequency', () => {
		const stale = { weekdays: [1, 4], basis: 'completion' as const, monthDay: 31 };
		const daily = buildRecurrence('daily', 1, '', 'UTC', stale);
		expect(keysOf(daily)).not.toContain('weekdays');
		expect(keysOf(daily)).not.toContain('monthDay');
		expect(daily?.basis).toBe('completion');
		const weekly = buildRecurrence('weekly', 1, '', 'UTC', stale);
		expect(weekly?.weekdays).toEqual([1, 4]);
		expect(keysOf(weekly)).not.toContain('monthDay');
		const monthly = buildRecurrence('monthly', 1, '', 'UTC', stale);
		expect(monthly?.monthDay).toBe(31);
		expect(keysOf(monthly)).not.toContain('weekdays');
		expect(buildRecurrence('none', 1, '', 'UTC', stale)).toBeNull();
	});
});

describe('old rules round-trip unchanged', () => {
	const old: Recurrence[] = [
		{ frequency: 'daily', interval: 1, timeZone: 'Europe/Berlin', until: null },
		{ frequency: 'weekly', interval: 2, timeZone: 'Europe/Berlin', until: null },
		{ frequency: 'monthly', interval: 3, timeZone: 'UTC', until: null }
	];
	it('form -> request carries none of the new fields', () => {
		for (const rule of old) {
			const back = buildRecurrence(rule.frequency, rule.interval, '', rule.timeZone, recurrenceExtras(rule));
			expect(back).toEqual(rule);
			for (const key of NEW_KEYS) expect(keysOf(back)).not.toContain(key);
		}
	});
	it('extras of a rule without the new fields are the neutral defaults', () => {
		expect(recurrenceExtras(old[1])).toEqual(plain);
		expect(recurrenceExtras(null)).toEqual(plain);
		expect(recurrenceExtras(undefined)).toEqual(plain);
	});
	it('extras of a stored new rule are read back', () => {
		const rule: Recurrence = { frequency: 'weekly', interval: 1, timeZone: 'UTC', weekdays: [4, 1], basis: 'completion' };
		expect(recurrenceExtras(rule)).toEqual({ weekdays: [1, 4], basis: 'completion', monthDay: null });
		expect(recurrenceExtras({ frequency: 'monthly', interval: 1, timeZone: 'UTC', monthDay: 31 })).toEqual({ ...plain, monthDay: 31 });
	});
});

describe('changing the frequency', () => {
	const all = { weekdays: [1, 4], basis: 'completion' as const, monthDay: 31 };
	it('keeps only what fits', () => {
		expect(extrasForFrequency('weekly', all)).toEqual({ weekdays: [1, 4], basis: 'completion', monthDay: null });
		expect(extrasForFrequency('monthly', all)).toEqual({ weekdays: [], basis: 'completion', monthDay: 31 });
		expect(extrasForFrequency('daily', all)).toEqual({ weekdays: [], basis: 'completion', monthDay: null });
		expect(extrasForFrequency('none', all)).toEqual(plain);
	});
});

describe('weekday toggles', () => {
	it('adds sorted and removes again', () => {
		expect(WEEKDAYS).toEqual([1, 2, 3, 4, 5, 6, 7]);
		expect(toggleWeekday([4], 1)).toEqual([1, 4]);
		expect(toggleWeekday([1, 4], 4)).toEqual([1]);
		expect(toggleWeekday([1], 1)).toEqual([]);
	});
});

describe('describeRecurrence', () => {
	it('shows rules without new fields exactly as before', () => {
		expect(describeRecurrence('none', 1, plain)).toBe('');
		expect(describeRecurrence('daily', 1, plain)).toBe('Täglich');
		expect(describeRecurrence('weekly', 1, plain)).toBe('Wöchentlich');
		expect(describeRecurrence('weekly', 2, plain)).toBe('Wöchentlich · Alle … Wochen 2');
		expect(describeRecurrence('monthly', 1, plain)).toBe('Monatlich');
	});
	it('lists weekdays', () => {
		expect(describeRecurrence('weekly', 1, { ...plain, weekdays: [1, 4] })).toBe('Wöchentlich · Mo, Do');
		expect(describeRecurrence('weekly', 1, { ...plain, weekdays: [7, 1, 3] })).toBe('Wöchentlich · Mo, Mi, So');
	});
	it('names the day of the month and the shortened month end', () => {
		expect(describeRecurrence('monthly', 1, { ...plain, monthDay: 31 })).toBe('Monatlich · am 31. (Monatsende gekürzt)');
		expect(describeRecurrence('monthly', 1, { ...plain, monthDay: 29 })).toBe('Monatlich · am 29. (Monatsende gekürzt)');
		expect(describeRecurrence('monthly', 1, { ...plain, monthDay: 15 })).toBe('Monatlich · am 15.');
	});
	it('names the basis when it is the completion', () => {
		expect(describeRecurrence('daily', 1, { ...plain, basis: 'completion' })).toBe('Täglich · ab Erledigung');
		expect(describeRecurrence('weekly', 1, { ...plain, weekdays: [1, 4], basis: 'completion' })).toBe('Wöchentlich · Mo, Do · ab Erledigung');
	});
	it('ignores fields that do not fit the frequency', () => {
		expect(describeRecurrence('daily', 1, { weekdays: [1], basis: 'due', monthDay: 31 })).toBe('Täglich');
	});
});
