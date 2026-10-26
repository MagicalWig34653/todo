import { describe, expect, it } from 'vitest';
import { createApi, query, type FetchLike } from '../src/lib/api';
import { checkFile, formatSize, sha256Hex } from '../src/lib/attachments';
import { collectAll, fromLocalInput, isOverdue, moveWithin, toLocalInput } from '../src/lib/planning';

function recorder(response: Response) {
	const calls: { url: string; init?: RequestInit }[] = [];
	const fetchFn: FetchLike = async (url, init) => {
		calls.push({ url, init });
		return response.clone();
	};
	return { calls, api: createApi(fetchFn) };
}

describe('query', () => {
	it('skips empty values and encodes', () => {
		expect(query({ a: 'x y', b: undefined, c: '', d: null })).toBe('?a=x%20y');
		expect(query({})).toBe('');
	});
});

describe('planning helpers', () => {
	it('moveWithin swaps neighbours and ignores edges', () => {
		expect(moveWithin(['a', 'b', 'c'], 'b', -1)).toEqual(['b', 'a', 'c']);
		const same = ['a', 'b'];
		expect(moveWithin(same, 'a', -1)).toBe(same);
		expect(moveWithin(same, 'b', 1)).toBe(same);
	});
	it('local input round trip', () => {
		const iso = fromLocalInput('2026-10-27T09:30');
		expect(iso).not.toBeNull();
		expect(toLocalInput(iso)).toBe('2026-10-27T09:30');
		expect(fromLocalInput('')).toBeNull();
		expect(toLocalInput(null)).toBe('');
	});
	it('overdue only for open tasks', () => {
		const now = new Date('2026-10-26T12:00:00Z');
		expect(isOverdue('2026-10-25T00:00:00Z', false, now)).toBe(true);
		expect(isOverdue('2026-10-25T00:00:00Z', true, now)).toBe(false);
		expect(isOverdue(null, false, now)).toBe(false);
	});
	it('collectAll follows cursors', async () => {
		const pages = [{ items: [1, 2], nextCursor: 'c' }, { items: [3] }];
		let i = 0;
		const seen: (string | null)[] = [];
		const all = await collectAll(async (c) => (seen.push(c), pages[i++]));
		expect(all).toEqual([1, 2, 3]);
		expect(seen).toEqual([null, 'c']);
	});
});

describe('attachments', () => {
	it('validates type, size and name', () => {
		expect(checkFile({ name: 'a.png', size: 10, type: 'image/png' })).toBeNull();
		expect(checkFile({ name: 'a.gif', size: 10, type: 'image/gif' })).toBe('type');
		expect(checkFile({ name: 'a.png', size: 0, type: 'image/png' })).toBe('empty');
		expect(checkFile({ name: 'a.png', size: 11 * 1024 * 1024, type: 'image/png' })).toBe('too_large');
		expect(checkFile({ name: 'a/b.png', size: 1, type: 'image/png' })).toBe('name');
	});
	it('computes lowercase sha256 hex', async () => {
		const hex = await sha256Hex(new Blob(['abc']));
		expect(hex).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
	});
	it('formats sizes', () => {
		expect(formatSize(512)).toBe('512 B');
		expect(formatSize(2048)).toBe('2,0 KB');
	});
});

describe('api requests for new endpoints', () => {
	it('reorder sends the full column', async () => {
		const { calls, api } = recorder(new Response(null, { status: 204 }));
		await api.reorderBoard('p', 'open', ['a', 'b']);
		expect(calls[0].url).toBe('/v1/planning/board/reorder');
		expect(calls[0].init?.method).toBe('PUT');
		expect(JSON.parse(calls[0].init?.body as string)).toEqual({ projectID: 'p', status: 'open', taskIDs: ['a', 'b'] });
	});
	it('search builds query from criteria and cursor', async () => {
		const { calls, api } = recorder(Response.json({ items: [] }));
		await api.search({ q: 'milch', status: 'open' }, 'cur');
		expect(calls[0].url).toBe('/v1/search?q=milch&status=open&cursor=cur');
	});
	it('delete criterion carries the expected version', async () => {
		const { calls, api } = recorder(new Response(null, { status: 204 }));
		await api.deleteCriterion({ id: 'c', taskID: 't', text: 'x', completed: false, version: 4 });
		expect(calls[0].url).toBe('/v1/tasks/t/acceptance-criteria/c');
		expect(JSON.parse(calls[0].init?.body as string)).toEqual({ version: 4 });
	});
	it('upload uses the capability token without cookies', async () => {
		const { calls, api } = recorder(new Response(null, { status: 204 }));
		await api.uploadAttachment(
			{ attachmentID: 'a', uploadURL: '/v1/attachments/a/upload', token: 'tok', expiresAt: '' },
			new Blob(['x'])
		);
		expect(calls[0].init?.credentials).toBe('omit');
		expect((calls[0].init?.headers as Record<string, string>).Authorization).toBe('Bearer tok');
	});
	it('recovery calls use the recovery bearer and no cookies', async () => {
		const { calls, api } = recorder(Response.json({ challengeID: 'c', options: {} }));
		await api.recoveryPasskeyBegin('rec');
		expect(calls[0].init?.credentials).toBe('omit');
		expect((calls[0].init?.headers as Record<string, string>).Authorization).toBe('Bearer rec');
	});
});
