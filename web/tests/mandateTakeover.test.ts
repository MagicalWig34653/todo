import { describe, expect, it } from 'vitest';
import type { OAuthGrant } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import { auditKindKey, isTakeover, listedMandates, mandateStatus, type BrainMandate } from '../src/lib/brainMandate';
import { revocationKey } from '../src/lib/oauth';

/** Card BEF08998 (ADR 0036): takeover after a new sign-in, as the settings pages show it. */
const mandate = (over: Partial<BrainMandate> = {}): BrainMandate => ({
	grantID: 'G1', grantName: 'Brain', projectIDs: ['P1'], active: false,
	createdAt: '2026-11-26T08:00:00Z', updatedAt: '2026-11-26T08:00:00Z', revokedAt: null, lastUsedAt: null, ...over
});
const grant = (over: Partial<OAuthGrant> = {}): OAuthGrant => ({ id: 'G1', client_id: 'client', scopes: [], project_ids: [], revoked: true, ...over });

describe('mandate of a connection that was signed out', () => {
	it('can still be taken over after a security sign-out, unless the person revoked the mandate', () => {
		expect(mandateStatus(mandate({ grantRevokedReason: 'replay' }))).toBe('recoverable');
		expect(mandateStatus(mandate({ grantRevokedReason: 'replay', revokedAt: '2026-11-26T09:00:00Z' }))).toBe('revoked');
	});
	it('stays void for other causes, including an unknown one', () => {
		for (const grantRevokedReason of ['person', 'account_locked', null, undefined]) {
			expect(mandateStatus(mandate({ grantRevokedReason }))).toBe('grant_revoked');
		}
	});
	it('is not listed any more once a new sign-in replaced the connection', () => {
		const old = mandate({ grantRevokedReason: 'superseded' });
		const next = mandate({ grantID: 'G2', active: true, takenOver: { fromGrantID: 'G1', fromName: 'Brain', at: '2026-11-26T09:00:00Z' } });
		expect(mandateStatus(old)).toBe('superseded');
		expect(listedMandates([next, old])).toEqual([next]);
	});
});

describe('takeover in the protocol', () => {
	it('names both kinds and treats their text as a note of the server, not as a quote of the person', () => {
		expect(auditKindKey('mandate.taken_over')).toBe('brainMandate.audit.kind.takenOver');
		expect(auditKindKey('connection.taken_over')).toBe('brainMandate.audit.kind.accessTakenOver');
		expect(isTakeover('mandate.taken_over')).toBe(true);
		expect(isTakeover('connection.taken_over')).toBe(true);
		expect(isTakeover('connection.project_added')).toBe(false);
	});
});

describe('why a connection is revoked', () => {
	it('names the cause and falls back to the plain word', () => {
		expect(revocationKey(grant({ revoked_reason: 'replay' }))).toBe('account.oauth.revoked.replay');
		expect(revocationKey(grant({ revoked_reason: 'superseded' }))).toBe('account.oauth.revoked.superseded');
		for (const revoked_reason of ['person', 'account_locked', null, undefined]) {
			expect(revocationKey(grant({ revoked_reason }))).toBe('account.oauth.revoked');
		}
	});
	it('has German texts', () => {
		expect(de['brainMandate.current.takenOver']).toContain('{name}');
		expect(de['brainMandate.status.recoverable.text']).toContain('{name}');
		expect(de['account.oauth.revoked.replay.text']).toBeTruthy();
	});
});
