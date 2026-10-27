import { describe, expect, it } from 'vitest';
import { ApiError, createApi, type FetchLike, type Task } from '../src/lib/api';
import { describeError } from '../src/lib/errors';
import { de } from '../src/lib/i18n/de';
import { memberLabel, personName } from '../src/lib/people';
import {
	addReminder,
	buildRecurrence,
	candidateTasks,
	milestoneProgress,
	recurrenceNeedsDate,
	removeReminder
} from '../src/lib/planning';

function recorder(body: unknown = {}, status = 200) {
	const calls: { url: string; init?: RequestInit }[] = [];
	const fetchFn: FetchLike = async (url, init) => {
		calls.push({ url, init });
		return status === 204 ? new Response(null, { status }) : new Response(JSON.stringify(body), { status });
	};
	return { calls, api: createApi(fetchFn) };
}

const task = (id: string, status: Task['status'] = 'open'): Task => ({
	id,
	projectID: 'p',
	title: id,
	description: '',
	status,
	version: 1
});

describe('recurrence and reminders', () => {
	it('builds a rule or null', () => {
		expect(buildRecurrence('none', 1, '')).toBeNull();
		const r = buildRecurrence('weekly', 2, '', 'Europe/Berlin');
		expect(r).toEqual({ frequency: 'weekly', interval: 2, timeZone: 'Europe/Berlin', until: null });
	});
	it('clamps the interval to 1..1000', () => {
		expect(buildRecurrence('daily', 0, '', 'UTC')?.interval).toBe(1);
		expect(buildRecurrence('daily', 5000, '', 'UTC')?.interval).toBe(1000);
		expect(buildRecurrence('daily', Number.NaN, '', 'UTC')?.interval).toBe(1);
		expect(buildRecurrence('daily', 2.9, '', 'UTC')?.interval).toBe(2);
	});
	it('converts until to an instant', () => {
		const r = buildRecurrence('monthly', 1, '2026-12-01T08:00', 'UTC');
		expect(r?.until).toBe(new Date('2026-12-01T08:00').toISOString());
	});
	it('requires an anchor date for a rule', () => {
		const r = buildRecurrence('daily', 1, '', 'UTC');
		expect(recurrenceNeedsDate(r, '', '')).toBe(true);
		expect(recurrenceNeedsDate(r, '2026-10-27T09:00', '')).toBe(false);
		expect(recurrenceNeedsDate(null, '', '')).toBe(false);
	});
	it('keeps reminders unique and sorted, ignores invalid input', () => {
		let list: string[] = [];
		list = addReminder(list, '2026-10-28T09:00');
		list = addReminder(list, '2026-10-27T09:00');
		list = addReminder(list, '2026-10-27T09:00');
		list = addReminder(list, '');
		expect(list).toHaveLength(2);
		expect(list[0] < list[1]).toBe(true);
		expect(removeReminder(list, list[0])).toEqual([list[1]]);
	});
});

describe('pickers and progress', () => {
	it('excludes the task itself and chosen entries', () => {
		const all = [task('a'), task('b'), task('c')];
		expect(candidateTasks(all, 'a', [task('b')]).map((x) => x.id)).toEqual(['c']);
		expect(candidateTasks(all, null, []).map((x) => x.id)).toEqual(['a', 'b', 'c']);
	});
	it('counts done tasks', () => {
		expect(milestoneProgress([task('a', 'done'), task('b'), task('c', 'done')])).toEqual({ done: 2, total: 3 });
		expect(milestoneProgress([])).toEqual({ done: 0, total: 0 });
	});
});

describe('names', () => {
	it('prefers the server name and falls back', () => {
		expect(personName('Anna', 'Andere Person')).toBe('Anna');
		expect(personName(null, 'Andere Person')).toBe('Andere Person');
		expect(personName('  ', 'x')).toBe('x');
		expect(memberLabel({ userID: 'u1', displayName: 'Anna' }, 'me', 'Du')).toBe('Anna');
		expect(memberLabel({ userID: 'u1', displayName: null }, 'me', 'Du')).toBe('u1');
		expect(memberLabel({ userID: 'me', displayName: 'Ich' }, 'me', 'Du')).toBe('Du');
	});
});

describe('api: planning extensions, filters, directory', () => {
	it('dependencies use the planning endpoints', async () => {
		const { calls, api } = recorder([]);
		await api.dependencies('t1');
		await api.addDependency('t1', 't2');
		expect(calls[0].url).toBe('/v1/planning/tasks/t1/dependencies');
		expect(calls[1].init?.method).toBe('PUT');
		expect(JSON.parse(String(calls[1].init?.body))).toEqual({ prerequisiteID: 't2' });
		const del = recorder(undefined, 204);
		await del.api.removeDependency('t1', 't2');
		expect(del.calls[0].url).toBe('/v1/planning/tasks/t1/dependencies/t2');
		expect(del.calls[0].init?.method).toBe('DELETE');
	});
	it('milestones', async () => {
		const { calls, api } = recorder({ id: 'm1' });
		await api.createMilestone('p1', 'Release', null);
		expect(JSON.parse(String(calls[0].init?.body))).toEqual({ projectID: 'p1', title: 'Release', dueAt: null });
		await api.milestones('p1');
		expect(calls[1].url).toBe('/v1/planning/milestones?projectID=p1');
		const del = recorder(undefined, 204);
		await del.api.assignMilestoneTask('m1', 't1');
		await del.api.unassignMilestoneTask('m1', 't1');
		expect(del.calls.map((c) => `${c.init?.method} ${c.url}`)).toEqual([
			'PUT /v1/planning/milestones/m1/tasks/t1',
			'DELETE /v1/planning/milestones/m1/tasks/t1'
		]);
	});
	it('updateFilter sends the version and keeps unchanged fields', async () => {
		const { calls, api } = recorder({});
		const f = { id: 'f1', name: 'Alt', criteria: { q: 'x' }, version: 3 };
		await api.updateFilter(f, { name: 'Neu' });
		expect(calls[0].init?.method).toBe('PATCH');
		expect(JSON.parse(String(calls[0].init?.body))).toEqual({ name: 'Neu', criteria: { q: 'x' }, version: 3 });
		await api.updateFilter(f, { criteria: { status: 'done' } });
		expect(JSON.parse(String(calls[1].init?.body))).toEqual({ name: 'Alt', criteria: { status: 'done' }, version: 3 });
	});
	it('user search encodes the term', async () => {
		const { calls, api } = recorder([]);
		await api.searchUsers('Änne Müller');
		expect(calls[0].url).toBe('/v1/users/search?q=%C3%84nne%20M%C3%BCller&limit=8');
	});
});

describe('error texts', () => {
	it('explains dependency cycles and other 422 answers in German', () => {
		expect(describeError(new ApiError(422, 'dependency_cycle'))).toBe(de['error.dependency_cycle']);
		expect(describeError(new ApiError(422, 'Unprocessable Entity'))).toBe(de['error.unprocessable']);
		expect(describeError(new ApiError(400, 'recurrence_requires_date'))).toBe(de['error.recurrence_requires_date']);
	});
});
