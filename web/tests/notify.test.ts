import { describe, expect, it } from 'vitest';
import { de } from '../src/lib/i18n/de.js';
import { PUSH_CATEGORIES, PUSH_DEFAULTS, fragmentParam, summarizeTest } from '../src/lib/notify.js';

describe('notify helpers', () => {
	it('reads tokens from the url fragment only when well formed', () => {
		expect(fragmentParam('#token=abcDEF0123456789_-xyz', 'token')).toBe('abcDEF0123456789_-xyz');
		expect(fragmentParam('#code=short', 'code')).toBeNull();
		expect(fragmentParam('#token=<script>alert(1)</script>', 'token')).toBeNull();
		expect(fragmentParam('', 'token')).toBeNull();
	});
	it('summarizes a test run', () => {
		const r = summarizeTest({
			sent: 1,
			devices: [
				{ id: 'a', platform: 'ios', environment: 'sandbox', result: 'sent' },
				{ id: 'b', platform: 'macos', environment: 'sandbox', result: 'revoked', detail: 'Unregistered' }
			]
		});
		expect(r).toEqual({ total: 2, sent: 1, none: false });
		expect(summarizeTest({ sent: 0, devices: [] }).none).toBe(true);
	});
	it('has a label for every category and a default', () => {
		for (const c of PUSH_CATEGORIES) {
			expect(`notify.prefs.${c}` in de).toBe(true);
			expect(typeof PUSH_DEFAULTS[c]).toBe('boolean');
		}
	});
});
