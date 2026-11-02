import { describe, expect, it } from 'vitest';
import { de } from '../src/lib/i18n/de.js';
import { draftOf, hintFor, isDirty, refreshAfterRoleChange, saveOrder, toValue, TEST_FOR_CATEGORY, type ServerSetting } from '../src/lib/adminSettings.js';
import { SERVER_CATEGORY_BY_ENTRY, SETTINGS_GROUPS } from '../src/lib/settingsNav.js';

const base: ServerSetting = {
	key: 'limits.loginLimit', category: 'limits', label: 'Anmeldungen', help: 'h', type: 'int', env: 'IDENTITY_LOGIN_LIMIT', secret: false, hotReload: true,
	requiresRestart: false, origin: 'default', locked: false, value: 60, defaultValue: 60, isSet: true, unreadable: false, version: 0, min: 1, max: 100
};
const s = (over: Partial<ServerSetting>): ServerSetting => ({ ...base, ...over });

describe('server settings drafts', () => {
	it('starts from the effective value; secrets start empty', () => {
		expect(draftOf(base)).toBe(60);
		expect(draftOf(s({ type: 'bool', value: true }))).toBe(true);
		expect(draftOf(s({ type: 'string', value: undefined }))).toBe('');
		expect(draftOf(s({ secret: true, type: 'string', value: undefined, isSet: true }))).toBe('');
	});
	it('detects changes; locked settings and untouched secrets are never dirty', () => {
		expect(isDirty(base, '60')).toBe(false);
		expect(isDirty(base, '61')).toBe(true);
		expect(isDirty(s({ locked: true, origin: 'env' }), '99')).toBe(false);
		const secret = s({ secret: true, type: 'string', value: undefined });
		expect(isDirty(secret, '')).toBe(false);
		expect(isDirty(secret, 'new')).toBe(true);
	});
	it('converts drafts to typed values', () => {
		expect(toValue(base, ' 12 ')).toBe(12);
		expect(toValue(base, 'abc')).toBeUndefined();
		expect(toValue(s({ type: 'bool' }), true)).toBe(true);
		expect(toValue(s({ type: 'string' }), '  smtp.example.org ')).toBe('smtp.example.org');
		expect(toValue(s({ type: 'string' }), '  ')).toBeUndefined();
	});
	it('gives hints for numbers outside the limits', () => {
		expect(hintFor(base, '50')).toBeNull();
		expect(hintFor(base, '0')?.key).toBe('admin.server.hint.min');
		expect(hintFor(base, '101')?.key).toBe('admin.server.hint.max');
		expect(hintFor(base, 'x')?.key).toBe('admin.server.hint.int');
		expect(hintFor(s({ type: 'string' }), 'anything')).toBeNull();
		for (const k of ['admin.server.hint.int', 'admin.server.hint.min', 'admin.server.hint.max'] as const) expect(de[k]).toBeTruthy();
	});
	it('saves "switch on" last and "switch off" first', () => {
		const enabled = s({ key: 'mail.enabled', type: 'bool' });
		const host = s({ key: 'mail.smtpHost', type: 'string' });
		expect(saveOrder([{ setting: enabled, value: true }, { setting: host, value: 'x' }]).map((c) => c.setting.key)).toEqual(['mail.smtpHost', 'mail.enabled']);
		expect(saveOrder([{ setting: host, value: 'x' }, { setting: enabled, value: false }]).map((c) => c.setting.key)).toEqual(['mail.enabled', 'mail.smtpHost']);
	});
});

describe('server settings navigation', () => {
	it('maps every category entry to an admin-only hub entry', () => {
		const admin = SETTINGS_GROUPS.find((g) => g.id === 'admin')!.entries;
		for (const id of Object.keys(SERVER_CATEGORY_BY_ENTRY)) expect(admin.find((e) => e.id === id)?.adminOnly, id).toBe(true);
		expect(new Set(Object.values(SERVER_CATEGORY_BY_ENTRY)).size).toBe(Object.keys(SERVER_CATEGORY_BY_ENTRY).length);
		expect(admin.find((e) => e.id === 'verwaltung-server')).toBeDefined();
	});
	it('offers tests for mail, push and storage only', () => {
		expect(TEST_FOR_CATEGORY).toEqual({ mail: 'mail', push: 'apns', attachments: 'storage' });
	});
});

describe('admin accounts list', () => {
	it('sorts administrators first, then by name', async () => {
		const { sortUsers } = await import('../src/lib/adminSettings.js');
		const sorted = sortUsers([
			{ id: '1', displayName: 'Zoe', isAdmin: false },
			{ id: '2', displayName: 'Bert', isAdmin: false },
			{ id: '3', displayName: 'Yvi', isAdmin: true }
		]);
		expect(sorted.map((u) => u.id)).toEqual(['3', '2', '1']);
	});
});

describe('refreshAfterRoleChange', () => {
	it('reloads the own profile only when the change concerned the current user', async () => {
		let calls = 0;
		const refresh = async () => { calls++; };
		expect(await refreshAfterRoleChange('u2', 'u1', refresh)).toBe(false);
		expect(await refreshAfterRoleChange('u1', undefined, refresh)).toBe(false);
		expect(calls).toBe(0);
		expect(await refreshAfterRoleChange('u1', 'u1', refresh)).toBe(true);
		expect(calls).toBe(1);
	});
});

import { canTransferProjects, expandSelection, followsParent, transferReady, type AdminUser, type OwnedProject } from '../src/lib/adminSettings.js';

describe('project transfer helpers', () => {
	const user = (over: Partial<AdminUser>): AdminUser => ({ id: 'u', displayName: 'U', isAdmin: false, status: 'disabled', ...over });
	const rows: OwnedProject[] = [
		{ id: 'p', name: 'P', taskCount: 2 },
		{ id: 'c', name: 'C', parentID: 'p', parentName: 'P', taskCount: 0 },
		{ id: 'g', name: 'G', parentID: 'c', parentName: 'C', taskCount: 1 },
		{ id: 'x', name: 'X', parentID: 'other', parentName: 'Fremd', taskCount: 0 }
	];

	it('offers the action only for locked accounts that own projects', () => {
		expect(canTransferProjects(user({ ownedProjects: 2 }))).toBe(true);
		expect(canTransferProjects(user({ status: 'anonymized', ownedProjects: 1 }))).toBe(true);
		expect(canTransferProjects(user({ ownedProjects: 0 }))).toBe(false);
		expect(canTransferProjects(user({}))).toBe(false);
		expect(canTransferProjects(user({ status: 'active', ownedProjects: 3 }))).toBe(false);
	});

	it('adds listed sub-projects of selected parents, nothing else', () => {
		expect([...expandSelection(rows, ['p'])].sort()).toEqual(['c', 'g', 'p']);
		expect([...expandSelection(rows, ['c'])].sort()).toEqual(['c', 'g']);
		expect([...expandSelection(rows, ['x'])]).toEqual(['x']);
		expect(expandSelection(rows, []).size).toBe(0);
	});

	it('marks rows that follow a listed parent', () => {
		const sel = new Set(['p', 'c', 'g']);
		expect(followsParent(rows, rows[1], sel)).toBe(true);
		expect(followsParent(rows, rows[0], sel)).toBe(false);
		expect(followsParent(rows, rows[3], new Set(['other', 'x']))).toBe(false);
	});

	it('needs a selection and a target', () => {
		expect(transferReady({ type: 'person', id: 'a' }, new Set(['p']))).toBe(true);
		expect(transferReady({ type: 'person', id: '' }, new Set(['p']))).toBe(false);
		expect(transferReady({ type: 'team', id: 't' }, new Set())).toBe(false);
	});
});
