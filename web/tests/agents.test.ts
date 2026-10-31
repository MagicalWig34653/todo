import { describe, expect, it } from 'vitest';
import { createApi, type FetchLike, type RunnerDevice } from '../src/lib/api';
import { bindableDevices, bindingsForProject, canStopJob, isUuid, validateBinding, validateRelease } from '../src/lib/agentsLogic';

const dev = (id: string, over: Partial<RunnerDevice> = {}): RunnerDevice => ({ id, label: id, paired: true, activeRunCount: 0, bindings: [], ...over });
const UUID = '123e4567-e89b-12d3-a456-426614174000';

describe('agent logic', () => {
	it('recognises uuids', () => {
		expect(isUuid(UUID)).toBe(true);
		expect(isUuid(` ${UUID} `)).toBe(true);
		expect(isUuid('/Users/me/repo')).toBe(false);
	});
	it('stops only active jobs', () => {
		expect(['queued', 'claimed', 'running', 'waiting_for_answer'].every((s) => canStopJob(s as never))).toBe(true);
		expect(['awaiting_review', 'succeeded', 'failed', 'cancelled'].some((s) => canStopJob(s as never))).toBe(false);
	});
	it('offers only paired, unrevoked devices for bindings', () => {
		const list = [dev('a'), dev('b', { paired: false }), dev('c', { revokedAt: '2026-01-01T00:00:00Z' })];
		expect(bindableDevices(list).map((d) => d.id)).toEqual(['a']);
	});
	it('lists bindings of a project on live devices with the device label', () => {
		const b = (id: string, projectID: string) => ({ id, projectID, deviceID: 'x', repositoryKey: UUID, label: id });
		const list = [dev('a', { label: 'Mac', bindings: [b('1', 'p'), b('2', 'q')] }), dev('c', { revokedAt: 'x', bindings: [b('3', 'p')] })];
		expect(bindingsForProject(list, 'p').map((x) => [x.id, x.deviceLabel])).toEqual([['1', 'Mac']]);
	});
	it('validates the binding form', () => {
		const ok = { projectID: 'p', deviceID: 'd', repositoryKey: UUID, label: 'Repo' };
		expect(validateBinding(ok)).toBeNull();
		expect(validateBinding({ ...ok, repositoryKey: 'nope' })).toBe('key');
		expect(validateBinding({ ...ok, label: '  ' })).toBe('incomplete');
		expect(validateBinding({ ...ok, projectID: '' })).toBe('incomplete');
	});
	it('validates the release form', () => {
		expect(validateRelease({ taskID: 't', bindingID: 'b', scope: 'do it' })).toBe(true);
		expect(validateRelease({ taskID: 't', bindingID: 'b', scope: ' ' })).toBe(false);
		expect(validateRelease({ taskID: 't', bindingID: 'b', scope: 'x'.repeat(4001) })).toBe(false);
		expect(validateRelease({ taskID: '', bindingID: 'b', scope: 'x' })).toBe(false);
	});
});

describe('agent api calls', () => {
	function rec(body: unknown = {}, status = 200) {
		const calls: { url: string; init?: RequestInit }[] = [];
		const fetchFn: FetchLike = async (url, init) => {
			calls.push({ url, init });
			return status === 204 ? new Response(null, { status }) : new Response(JSON.stringify(body), { status });
		};
		return { calls, api: createApi(fetchFn) };
	}
	it('revokes a device with DELETE', async () => {
		const { calls, api } = rec(null, 204);
		await api.revokeDevice('d1');
		expect(calls[0].url).toBe('/v1/agents/devices/d1');
		expect(calls[0].init?.method).toBe('DELETE');
	});
	it('creates a binding', async () => {
		const { calls, api } = rec({ id: 'b' });
		await api.createBinding({ projectID: 'p', deviceID: 'd', repositoryKey: UUID, label: 'R' });
		expect(calls[0].url).toBe('/v1/agents/bindings');
		expect(JSON.parse(calls[0].init!.body as string)).toEqual({ projectID: 'p', deviceID: 'd', repositoryKey: UUID, label: 'R' });
	});
	it('releases and stops a job', async () => {
		const { calls, api } = rec({ id: 'j' });
		await api.releaseJob({ id: 'j', taskID: 't', bindingID: 'b', taskRevision: 3, mode: 'clarify', scope: 's' });
		await api.stopJob('j');
		expect(calls[0].url).toBe('/v1/agents/jobs');
		expect(calls[0].init?.method).toBe('POST');
		expect(JSON.parse(calls[0].init!.body as string).taskRevision).toBe(3);
		expect(calls[1].url).toBe('/v1/agents/jobs/j/stop');
	});
});
