import { describe, expect, it } from 'vitest';
import { findByShortID, parseShortIdQuery, shortID } from '../src/lib/shortId';

const A = 'fc7e2b77-1111-4222-8333-444455556666';
const B = 'FC7E2B77-AAAA-4BBB-8CCC-DDDDEEEEFFFF';
const C = '0a1b2c3d-1111-4222-8333-444455556666';

describe('shortID', () => {
	it('takes the first 8 characters in upper case', () => {
		expect(shortID(A)).toBe('FC7E2B77');
		expect(shortID(C)).toBe('0A1B2C3D');
	});
	it('is empty for missing ids', () => {
		expect(shortID(null)).toBe('');
		expect(shortID(undefined)).toBe('');
	});
});

describe('parseShortIdQuery', () => {
	it('accepts exactly 8 hex characters, any case, optional leading #', () => {
		expect(parseShortIdQuery('fc7e2b77')).toBe('FC7E2B77');
		expect(parseShortIdQuery('#FC7E2B77')).toBe('FC7E2B77');
		expect(parseShortIdQuery('  #fc7e2b77  ')).toBe('FC7E2B77');
	});
	it('rejects everything else', () => {
		for (const bad of ['', 'fc7e2b7', 'fc7e2b777', 'fc7e2b7g', '##fc7e2b77', 'fc7e 2b77', 'fc7e2b77-1111']) expect(parseShortIdQuery(bad)).toBeNull();
	});
});

describe('findByShortID', () => {
	const tasks = [{ id: A, title: 'T1' }, { id: C, title: 'T2' }];
	const questions = [{ id: B, taskID: C, prompt: 'Q' }];
	const reviews = [{ id: '99999999-0000-4000-8000-000000000000', taskID: A, summary: 'R' }];
	it('finds tasks and questions with the matching prefix, tasks first', () => {
		const hits = findByShortID('FC7E2B77', { tasks, questions, reviews });
		expect(hits.map((h) => [h.kind, h.id])).toEqual([['task', A], ['question', B]]);
	});
	it('a review is found by its own id and opens the card of its task', () => {
		const hits = findByShortID('99999999', { tasks, questions, reviews });
		expect(hits).toEqual([{ kind: 'review', id: reviews[0]!.id, cardID: A, title: 'R' }]);
	});
	it('returns nothing for unknown ids', () => {
		expect(findByShortID('DEADBEEF', { tasks, questions, reviews })).toEqual([]);
	});
});
