import { describe, expect, it } from 'vitest';
import { buildCardParam, cardOfConfirmation, cardOfNeed, cardOfPost, galleryOf, parseCardParam, relativeWhen } from '../src/lib/cardRef';
import { buildPath, parseRoute } from '../src/lib/routing';

const ID = '3F23FF45-7A01-4D28-BEF1-8694F9DE23DA';

describe('card reference in the URL', () => {
	it('builds and parses type:id', () => {
		expect(buildCardParam({ type: 'question', id: ID })).toBe(`question:${ID}`);
		expect(parseCardParam(`review:${ID}`)).toEqual({ type: 'review', id: ID });
		expect(parseCardParam(`task:${ID}`)).toEqual({ type: 'task', id: ID });
		expect(parseCardParam(`confirmation:${ID}`)).toEqual({ type: 'confirmation', id: ID });
	});
	it('rejects unknown types, bad ids and junk', () => {
		for (const bad of ['', 'x', 'task:', 'foo:' + ID, 'task:a b', 'task:../../etc', `task:${ID}:more`, ':' + ID]) expect(parseCardParam(bad)).toBeNull();
		expect(parseCardParam(null)).toBeNull();
	});
	it('routing carries ?card= next to ?task=', () => {
		const r = parseRoute('/for-you', `?card=question:${ID}`);
		expect(r.view).toBe('forYou');
		expect(r.card).toEqual({ type: 'question', id: ID });
		expect(buildPath(r)).toBe(`/for-you?card=question:${ID}`);
		const both = parseRoute(`/project/${ID}`, `?task=${ID}&card=task:${ID}`);
		expect(buildPath(both)).toBe(`/project/${ID}?task=${ID}&card=task:${ID}`);
	});
	it('flags an invalid card parameter instead of dropping it silently', () => {
		const r = parseRoute('/for-you', '?card=nonsense');
		expect(r.card).toBeUndefined();
		expect(r.cardInvalid).toBe(true);
		expect(buildPath(r)).toBe('/for-you');
	});
});

describe('type mapping of feed entries', () => {
	const base = { projectID: 'p', taskID: ID, taskTitle: 'T', projectName: 'P' };
	it('needs map to their own card type', () => {
		expect(cardOfNeed({ ...base, id: 'n', kind: 'question', questionID: 'Q1ABCDEF' } as never)).toEqual({ type: 'question', id: 'Q1ABCDEF' });
		expect(cardOfNeed({ ...base, id: 'n', kind: 'review', reviewID: 'r' } as never)).toEqual({ type: 'review', id: ID });
		for (const kind of ['blocked', 'overdue', 'due', 'x']) expect(cardOfNeed({ ...base, id: 'n', kind } as never)).toEqual({ type: 'task', id: ID });
	});
	it('posts map to review or task cards', () => {
		expect(cardOfPost({ ...base, id: 'x', kind: 'review' } as never)).toEqual({ type: 'review', id: ID });
		for (const kind of ['progress', 'build', 'done', 'question', 'comment', 'agent_run']) expect(cardOfPost({ ...base, id: 'x', kind } as never)).toEqual({ type: 'task', id: ID });
	});
	it('confirmations map by request id', () => {
		expect(cardOfConfirmation({ id: 'abc12345' })).toEqual({ type: 'confirmation', id: 'abc12345' });
	});
});

describe('relative time', () => {
	const now = new Date('2026-11-02T12:00:00Z');
	it('says just now, minutes, hours, days', () => {
		expect(relativeWhen('2026-11-02T11:59:40Z', now)).toBe('gerade eben');
		expect(relativeWhen('2026-11-02T11:55:00Z', now)).toBe('vor 5 Min.');
		expect(relativeWhen('2026-11-02T09:00:00Z', now)).toBe('vor 3 Std.');
		expect(relativeWhen('2026-10-30T12:00:00Z', now)).toBe('vor 3 Tagen');
		expect(relativeWhen('2026-11-01T12:00:00Z', now)).toBe('vor 1 Tag');
		expect(relativeWhen(null, now)).toBe('');
	});
});

describe('gallery', () => {
	it('lists builds first and adds only new image attachments', () => {
		const items = galleryOf(
			[{ attachmentID: 'a1', previewURL: '/p/a1', label: 'Login', filename: 'x.png' }],
			[
				{ id: 'a1', filename: 'x.png', mediaType: 'image/png' },
				{ id: 'a2', filename: 'y.jpg', mediaType: 'image/jpeg' },
				{ id: 'a3', filename: 'z.pdf', mediaType: 'application/pdf' }
			],
			(id) => `/p/${id}`
		);
		expect(items).toEqual([
			{ id: 'a1', url: '/p/a1', label: 'Login' },
			{ id: 'a2', url: '/p/a2', label: 'y.jpg' }
		]);
	});
});
