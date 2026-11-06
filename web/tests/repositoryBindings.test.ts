import { describe, expect, it } from 'vitest';
import { createApi, ApiError, type ProjectSync } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import { bindingError, bindingList, canAddBinding, MAX_BINDINGS } from '../src/lib/syncState';

const base = { bound: true, state: 'fresh' as const, staleAfterDays: 3 };

describe('bindingList', () => {
	it('uses the bindings array when present', () => {
		const sync: ProjectSync = { ...base, repository: 'a/b', bindings: [{ ...base, repository: 'a/b' }, { ...base, repository: 'c/d', state: 'stale', daysSince: 5 }] };
		expect(bindingList(sync).map((b) => b.repository)).toEqual(['a/b', 'c/d']);
	});
	it('falls back to the flat fields of older servers', () => {
		expect(bindingList({ ...base, repository: 'x/y' })).toHaveLength(1);
	});
	it('is empty when nothing is bound or no data', () => {
		expect(bindingList({ ...base, bound: false })).toEqual([]);
		expect(bindingList({ ...base, bound: false, bindings: [] })).toEqual([]);
		expect(bindingList(null)).toEqual([]);
	});
});

describe('bindingError', () => {
	it('maps backend reasons to localized message keys', () => {
		for (const reason of ['too_many_bindings', 'repository_already_bound', 'not_bound', 'repository_required', 'invalid_repository']) {
			const key = bindingError(new ApiError(reason === 'invalid_repository' ? 400 : 409, reason));
			expect(key).toBe(`sync.error.${reason}`);
			expect(de[key as keyof typeof de]).toBeTruthy();
		}
	});
	it('returns null for other errors', () => {
		expect(bindingError(new ApiError(500))).toBeNull();
		expect(bindingError(new Error('x'))).toBeNull();
	});
});

describe('canAddBinding', () => {
	it('stops at the limit of 10', () => {
		expect(MAX_BINDINGS).toBe(10);
		expect(canAddBinding(9)).toBe(true);
		expect(canAddBinding(10)).toBe(false);
	});
});

describe('bindings api (mocked fetch)', () => {
	it('adds with PUT and removes with DELETE and an encoded repository', async () => {
		const calls: { url: string; init?: RequestInit }[] = [];
		const api = createApi(async (url, init) => {
			calls.push({ url, init });
			return new Response(JSON.stringify({ ...base, bindings: [] }), { status: 200 });
		});
		await api.putProjectSync('p1', { repository: 'github.com/a/b' });
		await api.deleteProjectBinding('p1', 'github.com/a/b');
		expect(JSON.parse(calls[0].init!.body as string)).toEqual({ repository: 'github.com/a/b' });
		expect(calls[1].url).toBe('/v1/projects/p1/bindings?repository=github.com%2Fa%2Fb');
		expect(calls[1].init?.method).toBe('DELETE');
	});
});
