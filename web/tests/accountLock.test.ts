import { describe, expect, it } from 'vitest';
import { de } from '../src/lib/i18n/de.js';
import { lockActions, sortUsers, statusOf, type AdminUser } from '../src/lib/adminSettings.js';
import { ANONYMIZE_PHRASE, anonymizeMyAccount, exportFileName, fetchMyExport, phraseMatches } from '../src/lib/accountData.js';
import { ApiError } from '../src/lib/api.js';

const u = (over: Partial<AdminUser>): AdminUser => ({ id: 'u', displayName: 'Anna', isAdmin: false, status: 'active', ...over });

describe('account status helpers', () => {
	it('treats servers without a status as active', () => {
		expect(statusOf(u({ status: undefined }))).toBe('active');
	});
	it('sorts active first (admins on top), then disabled, then anonymized', () => {
		const sorted = sortUsers([
			u({ id: 'a', displayName: 'Zoe', status: 'anonymized' }),
			u({ id: 'b', displayName: 'Ben', status: 'disabled' }),
			u({ id: 'c', displayName: 'Cem' }),
			u({ id: 'd', displayName: 'Dora', isAdmin: true })
		]);
		expect(sorted.map((x) => x.id)).toEqual(['d', 'c', 'b', 'a']);
	});
	it('offers lock actions by status and never for the own or an anonymized account', () => {
		expect(lockActions(u({}), 'me')).toEqual(['disable', 'anonymize']);
		expect(lockActions(u({ status: 'disabled' }), 'me')).toEqual(['enable', 'anonymize']);
		expect(lockActions(u({ status: 'anonymized' }), 'me')).toEqual([]);
		expect(lockActions(u({ id: 'me' }), 'me')).toEqual([]);
	});
});

describe('own account data', () => {
	it('accepts the confirmation phrase regardless of case and spaces, nothing else', () => {
		expect(phraseMatches(ANONYMIZE_PHRASE)).toBe(true);
		expect(phraseMatches('  anonymisieren ')).toBe(true);
		expect(phraseMatches('anonymize')).toBe(false);
		expect(phraseMatches('')).toBe(false);
	});
	it('names the export file with the local date', () => {
		expect(exportFileName(new Date(2026, 10, 2))).toBe('todolino-export-2026-11-02.json');
	});
	it('sends the explicit confirmation and surfaces the error reason', async () => {
		let sent: { url: string; init?: RequestInit } | undefined;
		await anonymizeMyAccount(async (url, init) => {
			sent = { url, init };
			return new Response(null, { status: 204 });
		});
		expect(sent?.url).toBe('/v1/me/anonymize');
		expect(sent?.init?.method).toBe('POST');
		expect(JSON.parse(String(sent?.init?.body))).toEqual({ confirm: 'ANONYMIZE' });
		const failing = async () => new Response(JSON.stringify({ error: true, reason: 'last_admin_required' }), { status: 409 });
		await expect(anonymizeMyAccount(failing)).rejects.toMatchObject({ status: 409, reason: 'last_admin_required' });
		await expect(fetchMyExport(async () => new Response('{}', { status: 413 }))).rejects.toBeInstanceOf(ApiError);
	});
	it('has German texts for every error the lock functions can return', () => {
		for (const reason of ['cannot_lock_self', 'account_anonymized', 'account_disabled', 'confirmation_required', 'export_too_large', 'last_admin_self']) {
			expect(de[`error.${reason}` as keyof typeof de], reason).toBeTruthy();
		}
	});
});
