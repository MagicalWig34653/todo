import type { Recurrence } from './api.js';
import { t, type MessageKey } from './i18n/index.js';

/** ISO weekdays, 1 = Monday .. 7 = Sunday (contracts: `weekdays`). */
export const WEEKDAYS = [1, 2, 3, 4, 5, 6, 7] as const;

export type RecurrenceBasis = 'due' | 'completion';
export type RecurrenceFrequency = 'none' | 'daily' | 'weekly' | 'monthly';

/** The optional rule fields next to frequency, interval and end. Neutral values mean "as before". */
export interface RecurrenceExtras {
	/** Only for weekly; empty = the plain week interval. */
	weekdays: number[];
	/** `due` (default) = next date counts from the due date, `completion` = from the day it was completed. */
	basis: RecurrenceBasis;
	/** Only for monthly: 1..31, null = as before. */
	monthDay: number | null;
}

export const NO_EXTRAS: RecurrenceExtras = { weekdays: [], basis: 'due', monthDay: null };

/** Valid, unique ISO weekdays in ascending order. */
export function cleanWeekdays(days: readonly number[] | null | undefined): number[] {
	return [...new Set((days ?? []).filter((d) => Number.isInteger(d) && d >= 1 && d <= 7))].sort((a, b) => a - b);
}

/** Day of the month 1..31 (clamped, fraction cut off); anything that is not a number gives null. */
export function cleanMonthDay(day: number | string | null | undefined): number | null {
	if (day === null || day === undefined || day === '') return null;
	const n = Number(day);
	if (!Number.isFinite(n)) return null;
	return Math.min(31, Math.max(1, Math.trunc(n)));
}

/** Extras for the form from a stored rule; a rule without the new fields yields the neutral values. */
export function recurrenceExtras(rule: Recurrence | null | undefined): RecurrenceExtras {
	if (!rule) return { ...NO_EXTRAS, weekdays: [] };
	return {
		weekdays: cleanWeekdays(rule.weekdays),
		basis: rule.basis === 'completion' ? 'completion' : 'due',
		monthDay: cleanMonthDay(rule.monthDay)
	};
}

/** Drops what does not fit the frequency (weekdays only weekly, day of the month only monthly, nothing for none). */
export function extrasForFrequency(frequency: RecurrenceFrequency, extras: RecurrenceExtras): RecurrenceExtras {
	if (frequency === 'none') return { ...NO_EXTRAS, weekdays: [] };
	return {
		weekdays: frequency === 'weekly' ? cleanWeekdays(extras.weekdays) : [],
		basis: extras.basis,
		monthDay: frequency === 'monthly' ? cleanMonthDay(extras.monthDay) : null
	};
}

/** The fields to merge into the API rule: only meaningful, non-default values (never null or empty ones). */
export function extrasPayload(frequency: RecurrenceFrequency, extras: RecurrenceExtras): Partial<Pick<Recurrence, 'weekdays' | 'basis' | 'monthDay'>> {
	const fit = extrasForFrequency(frequency, extras);
	const out: Partial<Pick<Recurrence, 'weekdays' | 'basis' | 'monthDay'>> = {};
	if (fit.weekdays.length > 0) out.weekdays = fit.weekdays;
	if (fit.basis === 'completion') out.basis = 'completion';
	if (fit.monthDay !== null) out.monthDay = fit.monthDay;
	return out;
}

/** Switches a weekday on or off; the result stays sorted. */
export function toggleWeekday(days: readonly number[], day: number): number[] {
	return cleanWeekdays(days.includes(day) ? days.filter((d) => d !== day) : [...days, day]);
}

/** Readable one-line summary, e.g. "Wöchentlich · Mo, Do" or "Monatlich · am 31. (Monatsende gekürzt) · ab Erledigung". */
export function describeRecurrence(frequency: RecurrenceFrequency, interval: number, extras: RecurrenceExtras): string {
	if (frequency === 'none') return '';
	const fit = extrasForFrequency(frequency, extras);
	const parts: string[] = [t(`planning.recurrence.${frequency}` as MessageKey)];
	if (fit.weekdays.length > 0) parts.push(fit.weekdays.map((d) => t(`planning.recurrence.weekdayShort.${d}` as MessageKey)).join(', '));
	if (fit.monthDay !== null) {
		const day = t('planning.recurrence.monthDaySummary', { day: fit.monthDay });
		parts.push(fit.monthDay > 28 ? `${day} ${t('planning.recurrence.monthEndShortened')}` : day);
	}
	if (interval > 1) parts.push(`${t('planning.recurrence.interval', { unit: t(`planning.recurrence.unit.${frequency}` as MessageKey) })} ${interval}`);
	if (fit.basis === 'completion') parts.push(t('planning.recurrence.basisSummary.completion'));
	return parts.join(' · ');
}
