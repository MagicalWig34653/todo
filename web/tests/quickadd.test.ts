import { describe, expect, it } from 'vitest';
import { matchByName, parseQuickAdd } from '../src/lib/quickAdd';

// Friday 30 Oct 2026, 10:00 local time (same reference as the Apple QuickAddParserTests).
const now = new Date(2026, 9, 30, 10, 0, 0);
const parse = (s: string) => parseQuickAdd(s, now);
const day = (d: number, h = 0, m = 0, month = 11) => new Date(2026, month - 1, d, h, m, 0);

describe('parseQuickAdd (Apple parser examples)', () => {
	it('leaves a plain title untouched', () => {
		const p = parse('Milch kaufen');
		expect(p.title).toBe('Milch kaufen');
		expect(p.due).toBeNull();
		expect(p.priority).toBeNull();
	});
	it('tomorrow and priority', () => {
		const p = parse('Zahnarzt anrufen morgen p1');
		expect(p.title).toBe('Zahnarzt anrufen');
		expect(p.due).toEqual(day(31, 0, 0, 10));
		expect(p.priority).toBe(3);
	});
	it('time, project and label', () => {
		const p = parse('Meeting heute um 14:30 #Arbeit @dringend');
		expect(p.title).toBe('Meeting');
		expect(p.due).toEqual(day(30, 14, 30, 10));
		expect(p.hasTime).toBe(true);
		expect(p.projectToken).toBe('Arbeit');
		expect(p.labelTokens).toEqual(['dringend']);
	});
	it('weekday with "am"', () => {
		const p = parse('Sport am Montag');
		expect(p.title).toBe('Sport');
		expect(p.due).toEqual(day(2));
	});
	it('in N days', () => expect(parse('Rechnung in 3 Tagen').due).toEqual(day(2)));
	it('recurrence', () => {
		const p = parse('Pflanzen giessen jeden Tag');
		expect(p.title).toBe('Pflanzen giessen');
		expect(p.recurrence).toBe('daily');
		expect(p.due).toEqual(day(30, 0, 0, 10));
	});
	it('"um 9 Uhr"', () => {
		const p = parse('Anruf morgen um 9 Uhr');
		expect(p.due).toEqual(day(31, 9, 0, 10));
		expect(p.title).toBe('Anruf');
	});
	it('next week', () => expect(parse('Planung naechste Woche').due).toEqual(day(2)));
});

describe('parseQuickAdd (rules beyond the examples)', () => {
	it('priorities p1..p4 map to 3..0', () => {
		expect(parse('a p1').priority).toBe(3);
		expect(parse('a p2').priority).toBe(2);
		expect(parse('a p3').priority).toBe(1);
		expect(parse('a p4').priority).toBe(0);
		expect(parse('a !1').priority).toBe(3);
	});
	it('accepts umlaut spellings', () => {
		expect(parse('x übermorgen').due).toEqual(day(1));
		expect(parse('x nächste Woche').due).toEqual(day(2));
		expect(parse('x täglich').recurrence).toBe('daily');
		expect(parse('x wöchentlich').recurrence).toBe('weekly');
	});
	it('weekday names: a bare short name stays in the title, a weekday is strictly in the future', () => {
		expect(parse('Do Bescheid sagen').title).toBe('Do Bescheid sagen');
		expect(parse('Treffen am Do').due).toEqual(day(5));
		expect(parse('Treffen Freitag').due).toEqual(day(6));
	});
	it('weekend, weeks, recurrence words', () => {
		expect(parse('Putzen am Wochenende').due).toEqual(day(31, 0, 0, 10));
		expect(parse('x in 2 Wochen').due).toEqual(day(13));
		expect(parse('x jede Woche').recurrence).toBe('weekly');
		expect(parse('x jeden Monat').recurrence).toBe('monthly');
		expect(parse('x monatlich').recurrence).toBe('monthly');
	});
	it('a time already past today rolls to tomorrow; with a day it does not', () => {
		expect(parse('x um 9:00').due).toEqual(day(31, 9, 0, 10));
		expect(parse('x um 18:00').due).toEqual(day(30, 18, 0, 10));
		expect(parse('x heute um 9:00').due).toEqual(day(30, 9, 0, 10));
		expect(parse('x 14.30 Uhr').due).toEqual(day(30, 14, 30, 10));
	});
	it('section token and recognized phrases', () => {
		const p = parse('Bericht /Review morgen @a @b');
		expect(p.sectionToken).toBe('Review');
		expect(p.labelTokens).toEqual(['a', 'b']);
		expect(p.recognized).toEqual(['/Review', 'morgen', '@a', '@b']);
		expect(p.title).toBe('Bericht');
	});
	it('ignores lone # and @ and large day counts', () => {
		expect(parse('# @ x').title).toBe('# @ x');
		expect(parse('in 500 Tagen').due).toBeNull();
	});
});

describe('matchByName', () => {
	const items = [{ n: 'Arbeit' }, { n: 'Haushalt' }, { n: 'Haus Bau' }];
	it('exact, unique prefix, ambiguous', () => {
		expect(matchByName(items, (x) => x.n, 'arbeit')?.n).toBe('Arbeit');
		expect(matchByName(items, (x) => x.n, 'arb')?.n).toBe('Arbeit');
		expect(matchByName(items, (x) => x.n, 'haus')).toBeNull();
		expect(matchByName(items, (x) => x.n, 'xyz')).toBeNull();
	});
});
