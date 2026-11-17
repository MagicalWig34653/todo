import { describe, expect, it } from 'vitest';
import { relativeWhen } from '../src/lib/cardRef';
import { formatTimestamp } from '../src/lib/planning';

const now = new Date('2026-11-17T12:00:00Z');
const ago = (milliseconds: number) => new Date(now.getTime() - milliseconds).toISOString();

describe('audit timestamps', () => {
	it.each([
		[59_000, 'gerade eben'],
		[60_000, 'vor 1 Min.'],
		[59 * 60_000 + 59_999, 'vor 59 Min.'],
		[60 * 60_000, 'vor 1 Std.'],
		[23 * 3_600_000 + 3_599_999, 'vor 23 Std.'],
		[24 * 3_600_000, 'vor 1 Tag'],
		[6 * 86_400_000 + 86_399_999, 'vor 6 Tagen'],
		[7 * 86_400_000, '10.11.2026']
	])('floors elapsed time at %i ms', (milliseconds, expected) => {
		expect(relativeWhen(ago(milliseconds), now)).toBe(expected);
	});

	it('keeps older timestamps as Berlin calendar dates', () => {
		expect(relativeWhen('2026-10-24T22:30:00Z', now)).toBe('25.10.2026');
	});

	it('uses elapsed hours across the spring clock change', () => {
		expect(relativeWhen('2026-03-29T00:30:00Z', new Date('2026-03-29T01:30:00Z'))).toBe('vor 1 Std.');
		expect(formatTimestamp('2026-03-29T00:30:00Z')).toContain('01:30:00 GMT+1');
		expect(formatTimestamp('2026-03-29T01:30:00Z')).toContain('03:30:00 GMT+2');
	});

	it('distinguishes the two 02:30 instants at the autumn clock change', () => {
		const summer = formatTimestamp('2026-10-25T00:30:00Z');
		const winter = formatTimestamp('2026-10-25T01:30:00Z');
		expect(summer).toContain('25.10.2026');
		expect(summer).toContain('02:30:00 GMT+2');
		expect(winter).toContain('02:30:00 GMT+1');
		expect(relativeWhen('2026-10-25T00:30:00Z', new Date('2026-10-25T01:30:00Z'))).toBe('vor 1 Std.');
	});

	it('keeps midnight and seconds in the exact tooltip, regardless of the browser timezone', () => {
		expect(formatTimestamp('2026-11-16T23:00:07Z')).toContain('17.11.2026');
		expect(formatTimestamp('2026-11-16T23:00:07Z')).toContain('00:00:07 GMT+1');
	});

	it('omits absent or invalid timestamps and clamps future relative times', () => {
		for (const value of [null, undefined, '', 'invalid']) {
			expect(relativeWhen(value, now)).toBe('');
			expect(formatTimestamp(value)).toBe('');
		}
		expect(relativeWhen('2026-11-17T13:00:00Z', now)).toBe('gerade eben');
	});
});
