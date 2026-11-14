import { describe, expect, it } from 'vitest';
import type { LiveEvent, LiveSession } from '../src/lib/api';
import { absoluteWhen, appendOlder, isStale, liveKindKey, mergeNewest, quietFor, sameLive, splitSessions } from '../src/lib/liveView';

const session = (id: string, status: 'active' | 'ended'): LiveSession => ({ id, name: id, actorType: 'integration', status, startedAt: '2026-11-13T11:00:00.000Z', lastSeenAt: '2026-11-13T11:05:00.000Z', stale: false });
const ev = (id: string): LiveEvent => ({ id, sessionID: 's', kind: 'tool', text: id, createdAt: '2026-11-13T11:00:00.000Z' });

describe('live view helpers', () => {
	it('splits active and ended sessions and keeps the order', () => {
		const { active, ended } = splitSessions([session('a', 'active'), session('b', 'ended'), session('c', 'active')]);
		expect(active.map((s) => s.id)).toEqual(['a', 'c']);
		expect(ended.map((s) => s.id)).toEqual(['b']);
	});

	it('puts new events in front and keeps loaded older pages and their cursor', () => {
		const r = mergeNewest([ev('3'), ev('2'), ev('1')], 'cursor-old', [ev('4'), ev('3'), ev('2')], 'cursor-page');
		expect(r.items.map((e) => e.id)).toEqual(['4', '3', '2', '1']);
		expect(r.next).toBe('cursor-old');
	});
	it('keeps the very same content when nothing is new', () => {
		const r = mergeNewest([ev('2'), ev('1')], null, [ev('2'), ev('1')], 'x');
		expect(r.items.map((e) => e.id)).toEqual(['2', '1']);
		expect(r.next).toBeNull();
	});
	it('restarts from the page when it shares no event with the list (gap)', () => {
		const r = mergeNewest([ev('1')], null, [ev('9'), ev('8')], 'c9');
		expect(r.items.map((e) => e.id)).toEqual(['9', '8']);
		expect(r.next).toBe('c9');
	});
	it('takes the first page as is', () => {
		expect(mergeNewest([], null, [ev('1')], 'c')).toEqual({ items: [ev('1')], next: 'c' });
	});
	it('appends older events without duplicates', () => {
		expect(appendOlder([ev('3'), ev('2')], [ev('2'), ev('1')]).map((e) => e.id)).toEqual(['3', '2', '1']);
	});

	it('maps event kinds to labels with a fallback', () => {
		expect(liveKindKey('question')).toBe('live.kind.question');
		expect(liveKindKey('step')).toBe('live.kind.step');
		expect(liveKindKey('hologram')).toBe('live.kind.other');
	});

	it('formats absolute times: clock today, date and time otherwise, empty when invalid', () => {
		const now = new Date(2026, 10, 14, 15, 0);
		expect(absoluteWhen(new Date(2026, 10, 14, 9, 5).toISOString(), now)).toBe('09:05');
		expect(absoluteWhen(new Date(2026, 10, 12, 9, 5).toISOString(), now)).toContain('2026');
		expect(absoluteWhen('nonsense', now)).toBe('');
		expect(absoluteWhen(null, now)).toBe('');
	});

	it('knows a silent session from the server flag or the local clock, never for ended ones', () => {
		const now = Date.parse('2026-11-13T12:00:00.000Z');
		const s = session('a', 'active');
		expect(isStale({ ...s, lastSeenAt: '2026-11-13T11:50:00.000Z' }, now)).toBe(false);
		expect(isStale({ ...s, lastSeenAt: '2026-11-13T11:40:00.000Z' }, now)).toBe(true);
		expect(isStale({ ...s, stale: true, lastSeenAt: '2026-11-13T11:59:00.000Z' }, now)).toBe(true);
		expect(isStale({ ...session('b', 'ended'), stale: true, lastSeenAt: '2026-11-13T09:00:00.000Z' }, now)).toBe(false);
	});
	it('describes the silence in minutes, hours or days', () => {
		const now = Date.parse('2026-11-13T12:00:00.000Z');
		expect(quietFor('2026-11-13T11:30:00.000Z', now)).toEqual({ unit: 'minutes', count: 30 });
		expect(quietFor('2026-11-13T11:59:59.000Z', now)).toEqual({ unit: 'minutes', count: 1 });
		expect(quietFor('2026-11-13T09:00:00.000Z', now)).toEqual({ unit: 'hours', count: 3 });
		expect(quietFor('2026-11-10T12:00:00.000Z', now)).toEqual({ unit: 'days', count: 3 });
	});

	it('compares small lists structurally', () => {
		expect(sameLive([ev('1')], [ev('1')])).toBe(true);
		expect(sameLive([ev('1')], [ev('2')])).toBe(false);
	});
});
