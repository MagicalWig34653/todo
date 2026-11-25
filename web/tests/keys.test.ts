import { describe, expect, it } from 'vitest';
import { uniqueKeys } from '../src/lib/keys';

// Card B0CF5F73: a keyed {#each} throws each_key_duplicate (the "500" page on /now) when two entries share a key.
describe('uniqueKeys', () => {
	it('keeps keys that are already unique, in order', () => {
		expect(uniqueKeys(['a', 'b', 'c'], (x) => x)).toEqual([{ item: 'a', key: 'a' }, { item: 'b', key: 'b' }, { item: 'c', key: 'c' }]);
	});
	it('keeps the first of a repeated key unchanged and numbers the repeats', () => {
		const keys = uniqueKeys(['564a6b4', '564a6b4', 'ios-42', '564a6b4'], (x) => x).map((k) => k.key);
		expect(keys).toEqual(['564a6b4', '564a6b4#2', 'ios-42', '564a6b4#3']);
	});
	it('never collides with a real key that looks like a numbered one', () => {
		const keys = uniqueKeys(['a', 'a', 'a#2'], (x) => x).map((k) => k.key);
		expect(new Set(keys).size).toBe(3);
	});
	it('is stable: the same list yields the same keys, and a prepended unrelated entry does not renumber the others', () => {
		const before = uniqueKeys([{ k: 'x' }, { k: 'x' }], (o) => o.k).map((k) => k.key);
		expect(uniqueKeys([{ k: 'x' }, { k: 'x' }], (o) => o.k).map((k) => k.key)).toEqual(before);
		expect(uniqueKeys([{ k: 'y' }, { k: 'x' }, { k: 'x' }], (o) => o.k).map((k) => k.key).slice(1)).toEqual(before);
	});
	it('handles an empty list', () => {
		expect(uniqueKeys([], (x: string) => x)).toEqual([]);
	});
});
