import { describe, expect, it } from 'vitest';
import { de } from '../src/lib/i18n/de.js';
import {
	ACTION_ROLE, accessRows, ancestors, can, hasRole, inheritedChain, initialsOf, isOwner, maxRole, missingRole, participants, roleOf, roleRank, ROLES, sharedWithMe, splitRoots, whoCanSee,
	type AccessRow
} from '../src/lib/access.js';
import type { Project, ProjectGrant } from '../src/lib/api.js';

const proj = (id: string, parentID: string | null, extra: Partial<Project> = {}): Project => ({ id, parentID, name: id, version: 1, ...extra });
const grant = (id: string, type: 'person' | 'team', pid: string, role: ProjectGrant['role'], name?: string): ProjectGrant => ({
	id, projectID: 'x', principalType: type, principalID: pid, role, principalName: name
});

describe('roles', () => {
	it('orders roles weakest first and compares them', () => {
		expect(ROLES).toEqual(['read', 'comment', 'edit', 'manage']);
		expect(roleRank(undefined)).toBe(-1);
		expect(hasRole('edit', 'comment')).toBe(true);
		expect(hasRole('comment', 'edit')).toBe(false);
		expect(hasRole(undefined, 'read')).toBe(false);
		expect(maxRole('read', 'edit')).toBe('edit');
		expect(maxRole(undefined, 'read')).toBe('read');
	});
	it('maps actions to the lowest sufficient role', () => {
		expect(can('read', 'addTask')).toBe(false);
		expect(can('comment', 'comment')).toBe(true);
		expect(can('comment', 'addTask')).toBe(false);
		expect(can('edit', 'addTask')).toBe(true);
		expect(can('edit', 'editProject')).toBe(false);
		expect(can('manage', 'share')).toBe(true);
		expect(missingRole('read', 'addTask')).toBe('edit');
		expect(missingRole('manage', 'addTask')).toBeNull();
		expect(ACTION_ROLE.share).toBe('manage');
	});
	it('treats projects without role data as own', () => {
		expect(roleOf(proj('a', null))).toBe('manage');
		expect(isOwner(proj('a', null))).toBe(true);
		expect(isOwner(proj('a', null, { isOwner: false }))).toBe(false);
	});
	it('has a German name and explanation for every role and a tooltip for every action', () => {
		for (const r of ROLES) {
			expect(de[`sharing.role.${r}` as keyof typeof de]).toBeTruthy();
			expect(de[`access.roleHelp.${r}` as keyof typeof de]).toBeTruthy();
		}
		expect(de['access.need']).toContain('{role}');
	});
});

describe('shared projects', () => {
	const all = [
		proj('mine', null, { isOwner: true }),
		proj('mine-sub', 'mine', { isOwner: true }),
		proj('theirs', null, { isOwner: false, ownerName: 'Berta' }),
		proj('theirs-sub', 'theirs', { isOwner: false }),
		proj('orphan', 'hidden-parent', { isOwner: false })
	];
	it('splits visible roots by ownership; a project below an invisible parent is a root', () => {
		const { mine, shared } = splitRoots(all);
		expect(mine.map((p) => p.id)).toEqual(['mine']);
		expect(shared.map((p) => p.id)).toEqual(['theirs', 'orphan']);
		expect(sharedWithMe(all).map((p) => p.id)).toEqual(['theirs', 'theirs-sub', 'orphan']);
	});
	it('lists visible ancestors nearest first and survives cycles', () => {
		const tree = [proj('a', null), proj('b', 'a'), proj('c', 'b')];
		expect(ancestors(tree, 'c').map((p) => p.id)).toEqual(['b', 'a']);
		const cyc = [proj('a', 'b'), proj('b', 'a')];
		expect(ancestors(cyc, 'a').map((p) => p.id)).toEqual(['b']);
	});
});

describe('inheritance', () => {
	const tree = [proj('root', null), proj('mid', 'root'), proj('leaf', 'mid')];
	const grants: Record<string, { inherits: boolean; grants: ProjectGrant[] | null }> = {
		mid: { inherits: true, grants: [grant('g2', 'person', 'bob', 'edit', 'Bob')] },
		root: { inherits: true, grants: [grant('g1', 'person', 'ann', 'read', 'Ann'), grant('g3', 'person', 'bob', 'read', 'Bob')] }
	};
	it('collects ancestor grants only while inheritance is on', async () => {
		const loaded: string[] = [];
		const load = async (p: Project) => (loaded.push(p.id), grants[p.id]!);
		expect((await inheritedChain(tree[2]!, false, tree, load)).length).toBe(0);
		expect(loaded).toEqual([]);
		const chain = await inheritedChain(tree[2]!, true, tree, load);
		expect(chain.map((c) => c.project.id)).toEqual(['mid', 'root']);
		const stop = await inheritedChain(tree[2]!, true, tree, async (p) => (p.id === 'mid' ? { inherits: false, grants: grants.mid!.grants } : grants[p.id]!));
		expect(stop.map((c) => c.project.id)).toEqual(['mid']);
	});
	it('marks inherited rows and lets a direct grant win over an inherited one', async () => {
		const chain = await inheritedChain(tree[2]!, true, tree, async (p) => grants[p.id]!);
		const rows = accessRows([grant('d1', 'person', 'ann', 'manage', 'Ann')], chain, (g) => g.principalID);
		expect(rows.map((r) => [r.principal.name, r.role, r.inheritedFrom?.name ?? null])).toEqual([
			['Ann', 'manage', null],
			['Bob', 'edit', 'mid']
		]);
	});
	it('uses a fallback when the name is unknown', () => {
		const rows = accessRows([grant('d1', 'person', 'zed', 'read')], [], (g) => `Konto ${g.principalID}`);
		expect(rows[0]!.principal.name).toBe('Konto zed');
	});
});

describe('whoCanSee', () => {
	const labels = { owner: 'Eigentümer', direct: 'Direkt', team: (n: string) => `Team ${n}`, inherited: (n: string) => `geerbt von ${n}` };
	const rows: AccessRow[] = [
		{ key: '1', principal: { type: 'person', id: 'bob', name: 'Bob' }, role: 'read' },
		{ key: '2', principal: { type: 'team', id: 't1', name: 'Familie' }, role: 'edit' },
		{ key: '3', principal: { type: 'person', id: 'cy', name: 'Cy' }, role: 'comment', inheritedFrom: { id: 'root', name: 'Haus' } }
	];
	const teamMembers = {
		t1: [
			{ userID: 'bob', displayName: 'Bob', accepted: true },
			{ userID: 'dora', displayName: 'Dora', accepted: true },
			{ userID: 'eve', displayName: 'Eve', accepted: false }
		]
	};
	it('takes the highest role per person and lists why', () => {
		const out = whoCanSee({ owner: { type: 'person', id: 'ann', name: 'Ann' }, rows, teamMembers, labels });
		expect(out.map((p) => [p.name, p.role])).toEqual([['Ann', 'manage'], ['Bob', 'edit'], ['Dora', 'edit'], ['Cy', 'comment']]);
		expect(out.find((p) => p.name === 'Bob')!.via).toEqual(['Direkt', 'Team Familie']);
		expect(out.find((p) => p.name === 'Cy')!.via).toEqual(['geerbt von Haus']);
		expect(out.some((p) => p.name === 'Eve')).toBe(false);
	});
	it('gives members of an owning team read', () => {
		const out = whoCanSee({ owner: { type: 'team', id: 't1', name: 'Familie' }, rows: [], teamMembers, labels });
		expect(out.map((p) => [p.name, p.role])).toEqual([['Bob', 'read'], ['Dora', 'read']]);
	});
});

describe('avatars', () => {
	it('derives initials', () => {
		expect(initialsOf('Mara Beispiel')).toBe('MB');
		expect(initialsOf('  ')).toBe('?');
	});
	it('deduplicates participants and keeps the owner first', () => {
		const rows: AccessRow[] = [
			{ key: '1', principal: { type: 'person', id: 'ann', name: 'Ann' }, role: 'read' },
			{ key: '2', principal: { type: 'team', id: 't', name: 'Familie' }, role: 'read' }
		];
		expect(participants({ id: 'ann', name: 'Ann' }, rows)).toEqual([
			{ id: 'ann', name: 'Ann', team: false },
			{ id: 't', name: 'Familie', team: true }
		]);
	});
});
