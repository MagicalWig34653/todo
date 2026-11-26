import { describe, expect, it } from 'vitest';
import { createApi, type FetchLike } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import {
	diffIDs,
	emptySelection,
	groupNameProblem,
	namesSomething,
	selectionBody,
	selectionFrom,
	selectionSummaryKey,
	toggleID
} from '../src/lib/projectGroups';

const A = 'AAAAAAAA-0000-0000-0000-000000000001';
const B = 'BBBBBBBB-0000-0000-0000-000000000002';
const G = 'CCCCCCCC-0000-0000-0000-000000000003';

describe('project selection (ADR 0037)', () => {
	it('sends a plain list without a selection object, so old servers and old meaning stay', () => {
		const sel = { ...emptySelection(), projectIDs: [A] };
		expect(selectionBody(sel)).toEqual({ projectIDs: [A] });
	});

	it('sends the rule with groups, mode and exclusions', () => {
		const sel = { ...emptySelection(), mode: 'all_except' as const, projectIDs: [A], excludedGroupIDs: [G], excludedProjectIDs: [B] };
		expect(selectionBody(sel)).toEqual({
			projectIDs: [A],
			selection: { mode: 'all_except', groupIDs: [], excludedProjectIDs: [B], excludedGroupIDs: [G] }
		});
	});

	it('reads the server answer back into a form state', () => {
		expect(selectionFrom([A], null)).toEqual({ ...emptySelection(), projectIDs: [A] });
		const dto = { mode: 'selected', projectIDs: [A], groupIDs: [G], excludedProjectIDs: [], excludedGroupIDs: [] };
		expect(selectionFrom([A, B], dto)).toEqual({ ...emptySelection(), projectIDs: [A], groupIDs: [G] });
	});

	it('knows whether anything is chosen (an empty group counts, it may get members)', () => {
		expect(namesSomething(emptySelection())).toBe(false);
		expect(namesSomething({ ...emptySelection(), groupIDs: [G] })).toBe(true);
		expect(namesSomething({ ...emptySelection(), mode: 'all_except' })).toBe(true);
	});

	it('toggles ids case-insensitively', () => {
		expect(toggleID([A], A.toLowerCase())).toEqual([]);
		expect(toggleID([A], B)).toEqual([A, B]);
	});

	it('compares before and after', () => {
		expect(diffIDs([A, G], [a(A), B])).toEqual({ added: [B], removed: [G] });
	});

	it('checks group names like the server', () => {
		expect(groupNameProblem('  ', [])).toBe('projectGroups.error.name');
		expect(groupNameProblem('Arbeit', [{ id: G, name: 'arbeit', projectIDs: [] }])).toBe('projectGroups.error.taken');
		expect(groupNameProblem('Arbeit', [{ id: G, name: 'arbeit', projectIDs: [] }], G)).toBeNull();
		expect(groupNameProblem('x'.repeat(81), [])).toBe('projectGroups.error.name');
	});

	it('says that new projects join automatically in mode all_except', () => {
		expect(selectionSummaryKey({ ...emptySelection(), mode: 'all_except' })).toBe('projectGroups.selection.allExceptHint');
		expect(selectionSummaryKey({ ...emptySelection(), groupIDs: [G] })).toBe('projectGroups.selection.groupsHint');
		expect(selectionSummaryKey({ ...emptySelection(), projectIDs: [A] })).toBeNull();
		for (const key of ['projectGroups.selection.allExceptHint', 'projectGroups.selection.groupsHint', 'projectGroups.error.name', 'projectGroups.error.taken'] as const) {
			expect(de[key]).toBeTruthy();
		}
	});
});

function a(id: string) {
	return id.toLowerCase();
}

describe('project group api', () => {
	it('uses the documented endpoints', async () => {
		const calls: string[] = [];
		const fetcher: FetchLike = async (url, init) => {
			calls.push(`${init?.method ?? 'GET'} ${String(url).replace(/^.*\/v1/, '/v1')} ${init?.body ?? ''}`);
			return new Response(JSON.stringify({ groups: [], group: null, changes: [], groupIDs: [], projectIDs: [], agentCreatedProjectIDs: [] }), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			});
		};
		const api = createApi(fetcher);
		await api.listProjectGroups();
		await api.createProjectGroup('Arbeit', [A]);
		await api.updateProjectGroup(G, { projectIDs: [B] }, true);
		await api.deleteProjectGroup(G);
		await api.setGroupsOfProject(A, [G]);
		await api.previewSelection({ ...emptySelection(), mode: 'all_except' });
		expect(calls).toEqual([
			'GET /v1/project-groups ',
			`POST /v1/project-groups {"name":"Arbeit","projectIDs":["${A}"]}`,
			`PATCH /v1/project-groups/${G}?dryRun=true {"projectIDs":["${B}"]}`,
			`DELETE /v1/project-groups/${G} `,
			`PUT /v1/projects/${A}/groups {"groupIDs":["${G}"]}`,
			'POST /v1/project-selection/preview {"projectIDs":[],"selection":{"mode":"all_except","groupIDs":[],"excludedProjectIDs":[],"excludedGroupIDs":[]}}'
		]);
	});
});
