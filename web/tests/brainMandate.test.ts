import { describe, expect, it } from 'vitest';
import { ApiError, createApi, type FetchLike, type OAuthGrant, type Project } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import {
	MAX_PROJECTS,
	auditCardParam,
	auditKindKey,
	diffMandate,
	eligibleGrants,
	filterProjects,
	mandateErrorKey,
	mandateFor,
	mandateStatus,
	prefillProjects,
	projectLabels,
	resolveScope,
	saveKind,
	selectionProblem,
	toggleProject,
	type BrainMandate
} from '../src/lib/brainMandate';
import { findEntry, normalizeArea, settingsPath } from '../src/lib/settingsNav';

const project = (id: string, name: string, parentID: string | null = null): Project => ({ id, name, parentID, version: 1 });
const grant = (id: string, over: Partial<OAuthGrant> = {}): OAuthGrant => ({ id, client_id: `${id}-client-xyz`, scopes: [], project_ids: [], revoked: false, ...over });
const mandate = (over: Partial<BrainMandate> = {}): BrainMandate => ({
	grantID: 'G1', grantName: 'Brain', projectIDs: ['P1'], active: true,
	createdAt: '2026-11-19T08:00:00Z', updatedAt: '2026-11-19T08:00:00Z', revokedAt: null, lastUsedAt: null, ...over
});
const projects = [project('P1', 'Alpha'), project('P2', 'Beta'), project('P3', 'Gamma'), project('P4', 'Beta', 'P1')];

describe('mandate status', () => {
	it('is active, revoked by the person, or void because the connection itself was revoked', () => {
		expect(mandateStatus(mandate())).toBe('active');
		expect(mandateStatus(mandate({ active: false, revokedAt: '2026-11-19T09:00:00Z' }))).toBe('revoked');
		// Backend: active=false without revokedAt means the grant was revoked (the mandate has no effect).
		expect(mandateStatus(mandate({ active: false, revokedAt: null }))).toBe('grant_revoked');
	});
});

describe('project labels and scope', () => {
	it('names nested projects with their parent path so equal names stay distinguishable', () => {
		const labels = projectLabels(projects);
		expect(labels.get('p1')).toBe('Alpha');
		expect(labels.get('p4')).toBe('Alpha › Beta');
	});
	it('is safe against parent cycles and missing parents', () => {
		const labels = projectLabels([project('A', 'A', 'B'), project('B', 'B', 'A'), project('C', 'Waise', 'GONE')]);
		expect(labels.get('c')).toBe('Waise');
		expect(labels.get('a')).toBeTruthy();
	});
	it('resolves names case-insensitively and marks unreadable projects, which come last', () => {
		const scope = resolveScope(['p2', 'GONE-0001', 'P1'], projects);
		expect(scope.map((s) => [s.label, s.accessible])).toEqual([['Alpha', true], ['Beta', true], ['GONE-0001'.slice(0, 8).toLowerCase(), false]]);
		expect(scope[2].id).toBe('GONE-0001');
	});
});

describe('eligible connections', () => {
	it('lists only the not revoked ones, sorted by name', () => {
		const list = eligibleGrants([
			grant('b', { name: 'Zeta' }), grant('r', { name: 'Alt', revoked: true }), grant('a', { client_name: 'Codex' })
		]);
		expect(list.map((g) => g.id)).toEqual(['a', 'b']);
	});
});

describe('project picking', () => {
	it('finds by words in any case, over the whole path, sorted by label', () => {
		expect(filterProjects(projects, '').map((p) => p.id)).toEqual(['P1', 'P4', 'P2', 'P3']);
		expect(filterProjects(projects, 'BETA').map((p) => p.id)).toEqual(['P4', 'P2']);
		expect(filterProjects(projects, 'alpha beta').map((p) => p.id)).toEqual(['P4']);
		expect(filterProjects(projects, 'nichts')).toEqual([]);
	});
	it('toggles one id without touching the others', () => {
		const a = toggleProject(new Set(['x']), 'y');
		expect([...a].sort()).toEqual(['x', 'y']);
		expect([...toggleProject(a, 'x')]).toEqual(['y']);
	});
	it('refuses a 201st project but always allows removing', () => {
		const full = new Set(Array.from({ length: MAX_PROJECTS }, (_, i) => `p${i}`));
		expect(MAX_PROJECTS).toBe(200);
		expect(toggleProject(full, 'extra').size).toBe(MAX_PROJECTS);
		expect(toggleProject(full, 'p0').size).toBe(MAX_PROJECTS - 1);
	});
	it('needs a connection and 1 to 200 explicit projects (no "all")', () => {
		expect(selectionProblem('', new Set(['p']))).toBe('grant_required');
		expect(selectionProblem('g', new Set())).toBe('projects_required');
		expect(selectionProblem('g', new Set(Array.from({ length: 201 }, (_, i) => `p${i}`)))).toBe('too_many');
		expect(selectionProblem('g', new Set(['p']))).toBeNull();
	});
});

describe('diff before replacing a mandate', () => {
	const before = { grantID: 'G1', projectIDs: ['P1', 'P2', 'GONE-0001'] };
	it('lists added, removed and kept projects by name', () => {
		const d = diffMandate(before, { grantID: 'G1', projectIDs: ['P2', 'P3'] }, projects);
		expect(d.grantChanged).toBe(false);
		expect(d.added.map((p) => p.label)).toEqual(['Gamma']);
		expect(d.removed.map((p) => [p.label, p.accessible])).toEqual([['Alpha', true], ['gone-000', false]]);
		expect(d.kept.map((p) => p.label)).toEqual(['Beta']);
		expect(d.changed).toBe(true);
	});
	it('detects a connection change even with the same projects, compared case-insensitively', () => {
		const d = diffMandate({ grantID: 'G1', projectIDs: ['P1'] }, { grantID: 'g2', projectIDs: ['p1'] }, projects);
		expect(d.grantChanged).toBe(true);
		expect(d.added).toEqual([]);
		expect(d.removed).toEqual([]);
		expect(d.changed).toBe(true);
	});
	it('reports no change for identical scope and connection (any case or order)', () => {
		const d = diffMandate({ grantID: 'G1', projectIDs: ['P1', 'P2'] }, { grantID: 'g1', projectIDs: ['p2', 'p1'] }, projects);
		expect(d.changed).toBe(false);
	});
});

describe('finding the mandate of one connection', () => {
	const list = [mandate({ grantID: 'G1' }), mandate({ grantID: 'G2', projectIDs: ['P2'] })];
	it('matches the connection case-insensitively and knows nothing about the others', () => {
		expect(mandateFor(list, 'g2')?.projectIDs).toEqual(['P2']);
		expect(mandateFor(list, 'G3')).toBeUndefined();
		expect(mandateFor([], 'G1')).toBeUndefined();
	});
});

describe('form prefill', () => {
	it('starts empty (nothing preselected) for a connection without an active mandate', () => {
		expect(prefillProjects(undefined, projects)).toEqual([]);
		expect(prefillProjects(mandate({ active: false, revokedAt: '2026-11-19T09:00:00Z' }), projects)).toEqual([]);
		expect(prefillProjects(mandate({ active: false }), projects)).toEqual([]);
	});
	it('takes over the active mandate of that connection with the real ids of the lists, and drops unreadable projects', () => {
		const m = mandate({ grantID: 'g1', projectIDs: ['p1', 'p3', 'GONE-0001'] });
		expect(prefillProjects(m, projects)).toEqual(['P1', 'P3']);
	});
});

describe('how to save', () => {
	const next = { grantID: 'G2', projectIDs: ['P2'] };
	it('first grant without a mandate needs no confirmation step', () => {
		expect(saveKind(null, next)).toBe('first');
		expect(saveKind(undefined, next)).toBe('first');
	});
	it('a revoked or void mandate gives nobody power, so granting again is a plain save', () => {
		expect(saveKind(mandate({ active: false, revokedAt: '2026-11-19T09:00:00Z' }), next)).toBe('first');
		expect(saveKind(mandate({ active: false }), next)).toBe('first');
	});
	it('changing the projects of an active mandate needs the confirmation diff (other connections are not touched)', () => {
		expect(saveKind(mandate(), { grantID: 'G1', projectIDs: ['P2'] })).toBe('replace');
		expect(saveKind(mandate(), { grantID: 'G1', projectIDs: ['P1', 'P2'] })).toBe('replace');
	});
	it('the very same active mandate is "unchanged"', () => {
		expect(saveKind(mandate(), { grantID: 'g1', projectIDs: ['p1'] })).toBe('unchanged');
	});
});

describe('error messages', () => {
	it('maps the documented answers to German texts that exist', () => {
		const key = (status: number, reason?: string) => mandateErrorKey(new ApiError(status, reason));
		expect(key(400, 'invalid_projects')).toBe('brainMandate.error.invalidProjects');
		expect(key(404)).toBe('brainMandate.error.notFound');
		expect(key(409, 'grant_revoked')).toBe('brainMandate.error.grantRevoked');
		expect(key(401)).toBe('brainMandate.error.session');
		expect(key(500)).toBeNull();
		expect(key(409, 'version_conflict')).toBeNull();
		for (const k of ['invalidProjects', 'notFound', 'grantRevoked', 'session']) expect(de[`brainMandate.error.${k}` as keyof typeof de]).toMatch(/\S/);
	});
	it('ignores foreign errors', () => {
		expect(mandateErrorKey(new Error('x'))).toBeNull();
	});
});

describe('mandate page texts', () => {
	it('say that the mandate also covers plans, with a mandatory quote and never for an own plan', () => {
		expect(de['settings.brain-vollmacht.description']).toContain('Pläne');
		expect(de['brainMandate.intro.allows']).toContain('Pläne freigeben oder Änderungen daran verlangen');
		expect(de['brainMandate.intro.allows']).toContain('Pflichtzitat');
		expect(de['brainMandate.intro.limits']).toContain('nie für Reviews oder Fragen, die die Verbindung selbst gestellt hat, und nie für Pläne, die sie selbst geschrieben hat');
		expect(de['brainMandate.intro.limits']).toContain('keine fremden Reviews, Fragen oder Pläne entscheiden');
		expect(findEntry('brain-vollmacht')?.keywords).toContain('plan');
	});
});

describe('audit helpers', () => {
	it('names the decision kinds and builds the card link', () => {
		expect(auditKindKey('review.accepted')).toBe('brainMandate.audit.kind.accepted');
		expect(auditKindKey('review.changes_requested')).toBe('brainMandate.audit.kind.changes');
		expect(auditKindKey('question.answered')).toBe('brainMandate.audit.kind.answered');
		expect(auditKindKey('connection.project_added')).toBe('brainMandate.audit.kind.projectAdded');
		expect(auditKindKey('connection.project_removed')).toBe('brainMandate.audit.kind.projectRemoved');
		expect(auditKindKey('plan.approved')).toBe('brainMandate.audit.kind.planApproved');
		expect(auditKindKey('plan.changes_requested')).toBe('brainMandate.audit.kind.planChanges');
		expect(de[auditKindKey('plan.approved')]).toBe('Plan freigegeben');
		expect(de[auditKindKey('plan.changes_requested')]).toBe('Änderungen am Plan verlangt');
		expect(auditKindKey('unbekannt')).toBe('brainMandate.audit.kind.other');
		expect(auditCardParam('ABCD1234-0000-0000-0000-000000000000')).toBe('task:ABCD1234-0000-0000-0000-000000000000');
		for (const k of ['accepted', 'changes', 'answered', 'projectAdded', 'projectRemoved', 'other']) expect(de[`brainMandate.audit.kind.${k}` as keyof typeof de]).toMatch(/\S/);
	});
});

describe('settings entry', () => {
	it('is reachable as /settings/brain-mandate with German texts', () => {
		const e = findEntry('brain-vollmacht');
		expect(e?.label).toBe('settings.brain-vollmacht');
		expect(de[e!.label]).toBe('Brain-Vollmacht');
		expect(de[e!.description]).toMatch(/\S/);
		expect(settingsPath('brain-vollmacht')).toBe('/settings/brain-mandate');
		expect(normalizeArea('brain-mandate')).toBe('brain-vollmacht');
	});
});

describe('api', () => {
	function recorder(body: unknown, status = 200) {
		const calls: { url: string; init?: RequestInit }[] = [];
		const fetchFn: FetchLike = async (url, init) => {
			calls.push({ url, init });
			return new Response(status === 204 ? null : JSON.stringify(body), { status });
		};
		return { calls, api: createApi(fetchFn) };
	}
	it('reads the list of mandates (one per connection, empty without any)', async () => {
		const none = recorder({ mandates: [] });
		expect(await none.api.listBrainMandates()).toEqual([]);
		expect(none.calls[0].url).toBe('/v1/settings/brain-mandate');
		const some = recorder({ mandates: [mandate(), mandate({ grantID: 'G2' })] });
		expect((await some.api.listBrainMandates()).map((m) => m.grantID)).toEqual(['G1', 'G2']);
	});
	it('puts exactly grantID and projectIDs', async () => {
		const r = recorder(mandate());
		await r.api.putBrainMandate('G1', ['P1', 'P2']);
		expect(r.calls[0].url).toBe('/v1/settings/brain-mandate');
		expect(r.calls[0].init?.method).toBe('PUT');
		expect(JSON.parse(r.calls[0].init?.body as string)).toEqual({ grantID: 'G1', projectIDs: ['P1', 'P2'] });
	});
	it('revokes exactly one connection with DELETE and reads the audit items', async () => {
		const del = recorder(null, 204);
		await del.api.revokeBrainMandate('G 1/x');
		expect(del.calls[0]).toMatchObject({ url: '/v1/settings/brain-mandate/G%201%2Fx', init: { method: 'DELETE' } });
		const audit = recorder({ items: [{ id: 'a', kind: 'review.accepted' }] });
		expect(await audit.api.listBrainAudit()).toHaveLength(1);
		expect(audit.calls[0].url).toBe('/v1/settings/brain-mandate/audit');
	});
});
