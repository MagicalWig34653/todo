import { describe, expect, it } from 'vitest';
import { confirmGate, failureKey, nameMatches, outcomeKey } from '../src/lib/forYou';
import { attentionCount } from '../src/lib/commandCenter';
import { de } from '../src/lib/i18n/de';

const impact = { targetType: 'project', targetID: 'p', targetName: 'Küche', subprojects: 0, tasks: 0, destructive: true };

describe('confirmation requests', () => {
	it('asks for the name when a project is deleted and for a tick otherwise', () => {
		expect(confirmGate({ tool: 'delete_project', impact })).toBe('name');
		expect(confirmGate({ tool: 'delete_task', impact })).toBe('check');
		expect(confirmGate({ tool: 'transfer_project_owner', impact })).toBe('check');
	});
	it('compares the typed name exactly apart from surrounding blanks', () => {
		expect(nameMatches(' Küche ', 'Küche')).toBe(true);
		expect(nameMatches('küche', 'Küche')).toBe(false);
		expect(nameMatches('', '')).toBe(false);
	});
	it('maps outcomes and failure codes to texts that exist', () => {
		const keys = [
			outcomeKey({ tool: 'delete_project', state: 'executed' }),
			outcomeKey({ tool: 'delete_task', state: 'executed' }),
			outcomeKey({ tool: 'transfer_project_owner', state: 'executed' }),
			outcomeKey({ tool: 'x', state: 'executed' }),
			outcomeKey({ tool: 'x', state: 'rejected' }),
			outcomeKey({ tool: 'x', state: 'expired' }),
			outcomeKey({ tool: 'x', state: 'failed' }),
			...['forbidden', 'not_found', 'version_conflict', 'connection_revoked', 'whatever', undefined].map(failureKey)
		];
		for (const k of keys) expect(k in de, k).toBe(true);
		expect(outcomeKey({ tool: 'delete_project', state: 'executed' })).toBe('confirm.done.projectDeleted');
	});
	it('counts pending confirmations in the attention badge', () => {
		expect(attentionCount({ openQuestions: 1, pendingReviews: 1, pendingConfirmations: 2 })).toBe(4);
		expect(attentionCount({ openQuestions: 1, pendingReviews: 1 })).toBe(2);
	});
});
