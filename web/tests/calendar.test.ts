import { describe, expect, it, vi } from 'vitest';
import {
	addCivilDays, berlinParts, formPatch, fromBerlinInput, toBerlinInput, berlinToDate, canDrag, civilKey, commitSchedule, conflictLabels, dayEntries, dropPlan, entryEnd, entryStart,
	inversePatch, keyPlan, layoutDay, monthGrid, shiftAnchor, snapMinutes, unscheduledEntry, visibleRange, weekDays, withLocalConflicts,
	type ScheduleEntry
} from '../src/lib/calendar';
import { ApiError, type PlanningTask } from '../src/lib/api';

const entry = (over: Partial<ScheduleEntry> = {}): ScheduleEntry => ({
	taskID: 't1', projectID: 'p1', title: 'Karte', status: 'open', version: 3, plannedAt: '2026-11-17T09:00:00Z', plannedMinutes: 60,
	plannedAllDay: false, dueAt: null, blocked: false, canEdit: true, autoStart: false, conflicts: [], ...over
});

describe('Berlin time helpers', () => {
	it('reads wall clock parts in Europe/Berlin', () => {
		expect(berlinParts(new Date('2026-11-17T23:30:00Z'))).toMatchObject({ y: 2026, m: 11, d: 18, h: 0, min: 30 });
		expect(berlinParts(new Date('2026-07-01T10:00:00Z'))).toMatchObject({ h: 12 });
	});
	it('converts wall clock back, across summer time', () => {
		expect(berlinToDate(2026, 11, 17, 10, 0).toISOString()).toBe('2026-11-17T09:00:00.000Z');
		expect(berlinToDate(2026, 7, 1, 12, 0).toISOString()).toBe('2026-07-01T10:00:00.000Z');
	});
	it('moves a nonexistent local time (spring gap) to the next valid minute', () => {
		// 2026-03-29 02:30 does not exist in Berlin; the first valid minute is 03:00 CEST = 01:00Z
		expect(berlinToDate(2026, 3, 29, 2, 30).toISOString()).toBe('2026-03-29T01:00:00.000Z');
	});
	it('takes the first of two ambiguous local times (autumn)', () => {
		expect(berlinToDate(2026, 10, 25, 2, 30).toISOString()).toBe('2026-10-25T00:30:00.000Z');
	});
	it('adds civil days without +24h arithmetic', () => {
		expect(addCivilDays({ y: 2026, m: 3, d: 28 }, 1)).toEqual({ y: 2026, m: 3, d: 29 });
		expect(addCivilDays({ y: 2026, m: 12, d: 31 }, 1)).toEqual({ y: 2027, m: 1, d: 1 });
		expect(civilKey({ y: 2026, m: 3, d: 5 })).toBe('2026-03-05');
	});
});

describe('ranges', () => {
	it('week starts on Monday in Berlin', () => {
		const r = visibleRange('week', new Date('2026-11-18T12:00:00Z')); // Wednesday
		expect(r.days.map(civilKey)).toEqual(['2026-11-16', '2026-11-17', '2026-11-18', '2026-11-19', '2026-11-20', '2026-11-21', '2026-11-22']);
		expect(r.from.toISOString()).toBe('2026-11-15T23:00:00.000Z');
		expect(r.to.toISOString()).toBe('2026-11-22T23:00:00.000Z');
		expect(weekDays(new Date('2026-11-22T20:00:00Z'))[0]).toEqual({ y: 2026, m: 11, d: 16 }); // Sunday 21:00 Berlin
	});
	it('month covers whole weeks and stays within the 62 day window', () => {
		const r = visibleRange('month', new Date('2026-11-17T12:00:00Z'));
		expect(civilKey(r.days[0])).toBe('2026-10-26');
		expect(r.days.length % 7).toBe(0);
		expect(r.days.length).toBeLessThanOrEqual(42);
		expect(r.to.getTime() - r.from.getTime()).toBeLessThanOrEqual(62 * 86_400_000);
		expect(monthGrid(new Date('2026-11-17T12:00:00Z')).length).toBe(r.days.length / 7);
	});
	it('shifts by a week or a month', () => {
		expect(shiftAnchor('week', new Date('2026-11-17T12:00:00Z'), 1).toISOString()).toBe('2026-11-24T12:00:00.000Z');
		expect(berlinParts(shiftAnchor('month', new Date('2026-01-31T12:00:00Z'), 1))).toMatchObject({ m: 2, d: 28 });
	});
});

describe('entries on a day', () => {
	it('separates all-day, timed and due marks', () => {
		const day = { y: 2026, m: 11, d: 17 };
		const all = [
			entry({ taskID: 'a', plannedAllDay: true, plannedAt: '2026-11-16T23:00:00Z', plannedMinutes: null }),
			entry({ taskID: 'b' }),
			entry({ taskID: 'c', plannedAt: null, plannedMinutes: null, dueAt: '2026-11-17T15:00:00Z' }),
			entry({ taskID: 'd', plannedAt: '2026-11-18T09:00:00Z' })
		];
		const r = dayEntries(all, day);
		expect(r.allDay.map((e) => e.taskID)).toEqual(['a']);
		expect(r.timed.map((e) => e.taskID)).toEqual(['b']);
		expect(r.due.map((e) => e.taskID)).toEqual(['c']);
	});
	it('defaults the duration to 30 minutes', () => {
		const e = entry({ plannedMinutes: null });
		expect(entryEnd(e).getTime() - entryStart(e)!.getTime()).toBe(30 * 60_000);
	});
	it('lays overlapping blocks side by side and clips to the day', () => {
		const day = { y: 2026, m: 11, d: 17 };
		const a = entry({ taskID: 'a', plannedAt: '2026-11-17T09:00:00Z', plannedMinutes: 60 }); // 10:00-11:00
		const b = entry({ taskID: 'b', plannedAt: '2026-11-17T09:30:00Z', plannedMinutes: 60 });
		const c = entry({ taskID: 'c', plannedAt: '2026-11-17T12:00:00Z', plannedMinutes: 30 });
		const night = entry({ taskID: 'n', plannedAt: '2026-11-17T22:30:00Z', plannedMinutes: 120 }); // 23:30 to 01:30
		const out = layoutDay([a, b, c, night], day);
		const by = Object.fromEntries(out.map((l) => [l.entry.taskID, l]));
		expect(by.a).toMatchObject({ startMin: 600, endMin: 660, col: 0, cols: 2 });
		expect(by.b).toMatchObject({ startMin: 630, col: 1, cols: 2 });
		expect(by.c).toMatchObject({ col: 0, cols: 1 });
		expect(by.n).toMatchObject({ startMin: 1410, endMin: 1440 });
	});
});

function task(): PlanningTask {
	return { task: { id: 'u1', projectID: 'p1', title: 'Ohne Termin', description: '', status: 'open', version: 5 }, position: 0, priority: 2, reminders: [] };
}

describe('drop plans', () => {
	const day = { y: 2026, m: 11, d: 18 };
	it('snaps to 15 minutes', () => {
		expect(snapMinutes(7)).toBe(0);
		expect(snapMinutes(8)).toBe(15);
		expect(snapMinutes(1439)).toBe(1425);
	});
	it('slot drop sets start and keeps duration', () => {
		expect(dropPlan({ kind: 'slot', day, minutes: 615 }, entry())).toEqual({ plannedAt: '2026-11-18T09:15:00.000Z', plannedAllDay: false });
	});
	it('slot drop from the sidebar sets start only', () => {
		const e = unscheduledEntry(task(), true);
		expect(dropPlan({ kind: 'slot', day, minutes: 600 }, e)).toEqual({ plannedAt: '2026-11-18T09:00:00.000Z', plannedAllDay: false });
	});
	it('all-day drop uses the day start in Berlin', () => {
		expect(dropPlan({ kind: 'allDay', day }, entry())).toEqual({ plannedAt: '2026-11-17T23:00:00.000Z', plannedAllDay: true });
	});
	it('sidebar drop clears the start', () => {
		expect(dropPlan({ kind: 'unscheduled' }, entry())).toEqual({ plannedAt: null });
	});
	it('does not plan anything without edit right or for done cards', () => {
		expect(canDrag(entry())).toBe(true);
		expect(canDrag(entry({ canEdit: false }))).toBe(false);
		expect(canDrag(entry({ status: 'done' }))).toBe(false);
		expect(dropPlan({ kind: 'allDay', day }, entry({ canEdit: false }))).toBeNull();
	});
	it('returns null when nothing changes', () => {
		expect(dropPlan({ kind: 'slot', day: { y: 2026, m: 11, d: 17 }, minutes: 600 }, entry())).toBeNull();
	});
});

describe('keyboard', () => {
	it('moves 15 minutes and one day', () => {
		expect(keyPlan(entry(), 'ArrowDown', false)).toEqual({ plannedAt: '2026-11-17T09:15:00.000Z' });
		expect(keyPlan(entry(), 'ArrowUp', false)).toEqual({ plannedAt: '2026-11-17T08:45:00.000Z' });
		expect(keyPlan(entry(), 'ArrowRight', false)).toEqual({ plannedAt: '2026-11-18T09:00:00.000Z' });
	});
	it('keeps local time across the summer time change', () => {
		const e = entry({ plannedAt: '2026-03-28T09:00:00Z' }); // 10:00 CET
		expect(keyPlan(e, 'ArrowRight', false)).toEqual({ plannedAt: '2026-03-29T08:00:00.000Z' }); // 10:00 CEST
	});
	it('Shift changes the duration within 15..1440', () => {
		expect(keyPlan(entry(), 'ArrowDown', true)).toEqual({ plannedMinutes: 75 });
		expect(keyPlan(entry({ plannedMinutes: 15 }), 'ArrowUp', true)).toBeNull();
		expect(keyPlan(entry({ plannedMinutes: null }), 'ArrowDown', true)).toEqual({ plannedMinutes: 45 });
		expect(keyPlan(entry({ plannedMinutes: 1440 }), 'ArrowDown', true)).toBeNull();
	});
	it('all-day cards only move by day', () => {
		const e = entry({ plannedAllDay: true, plannedAt: '2026-11-16T23:00:00Z', plannedMinutes: null });
		expect(keyPlan(e, 'ArrowDown', false)).toBeNull();
		expect(keyPlan(e, 'ArrowRight', false)).toEqual({ plannedAt: '2026-11-17T23:00:00.000Z' });
	});
	it('ignores read-only cards and other keys', () => {
		expect(keyPlan(entry({ canEdit: false }), 'ArrowDown', false)).toBeNull();
		expect(keyPlan(entry(), 'a', false)).toBeNull();
	});
});

describe('conflicts', () => {
	it('labels each conflict with text', () => {
		expect(conflictLabels(entry({ conflicts: ['after_due', 'prerequisite_later', 'prerequisite_open', 'repository_overlap'] }))).toEqual([
			'Nach der Frist', 'Vorgänger liegt später', 'Vorgänger nicht erledigt', 'Gleiches Repository zeitgleich'
		]);
		expect(conflictLabels(entry())).toEqual([]);
	});
	it('recomputes after_due locally after an optimistic move', () => {
		const e = entry({ dueAt: '2026-11-17T09:30:00Z', conflicts: [] });
		expect(withLocalConflicts(e).conflicts).toContain('after_due');
		const ok = entry({ dueAt: '2026-11-17T12:00:00Z', conflicts: ['after_due', 'prerequisite_open'] });
		expect(withLocalConflicts(ok).conflicts).toEqual(['prerequisite_open']);
	});
});

describe('sidebar entries', () => {
	it('derive from planning tasks with the role of the project', () => {
		expect(unscheduledEntry(task(), true)).toMatchObject({ taskID: 'u1', version: 5, plannedAt: null, canEdit: true, conflicts: [] });
		expect(canDrag(unscheduledEntry(task(), false))).toBe(false);
	});
});

describe('commitSchedule', () => {
	it('sends the version and returns an undo patch', async () => {
		const patch = vi.fn().mockResolvedValue({ task: { version: 4 } });
		const r = await commitSchedule(patch, entry(), { plannedAt: '2026-11-18T09:00:00.000Z' });
		expect(patch).toHaveBeenCalledWith('t1', { version: 3, plannedAt: '2026-11-18T09:00:00.000Z' });
		expect(r).toMatchObject({ ok: true, undo: { taskID: 't1', version: 4, patch: { plannedAt: '2026-11-17T09:00:00Z', plannedMinutes: 60, plannedAllDay: false } } });
	});
	it('reports a version conflict with a German message', async () => {
		const patch = vi.fn().mockRejectedValue(new ApiError(409, 'version_conflict'));
		const r = await commitSchedule(patch, entry(), { plannedAt: null });
		expect(r).toMatchObject({ ok: false, key: 'calendar.error.conflict' });
	});
	it('maps other reasons', async () => {
		for (const [e, key] of [
			[new ApiError(409, 'task_done'), 'calendar.error.done'],
			[new ApiError(403, 'forbidden'), 'calendar.error.readOnly'],
			[new ApiError(400, 'recurrence_requires_date'), 'calendar.error.recurrence']
		] as const) {
			expect(await commitSchedule(vi.fn().mockRejectedValue(e), entry(), { plannedAt: null })).toMatchObject({ ok: false, key });
		}
		expect(await commitSchedule(vi.fn().mockRejectedValue(new Error('x')), entry(), { plannedAt: null })).toMatchObject({ ok: false, key: null });
	});
	it('inverse patch restores all three fields and null for unplanned', () => {
		expect(inversePatch(entry({ plannedAt: null, plannedMinutes: null }))).toEqual({ plannedAt: null, plannedMinutes: null, plannedAllDay: false });
	});
});

describe('start and duration form', () => {
	it('shows and parses Berlin wall clock, not the browser zone', () => {
		expect(toBerlinInput('2026-11-17T09:05:00Z')).toBe('2026-11-17T10:05');
		expect(toBerlinInput(null)).toBe('');
		expect(fromBerlinInput('2026-07-01T12:00')?.toISOString()).toBe('2026-07-01T10:00:00.000Z');
		expect(fromBerlinInput('')).toBeNull();
		expect(fromBerlinInput('quatsch')).toBeNull();
	});
	it('builds a timed patch', () => {
		expect(formPatch(entry(), { start: '2026-11-18T10:00', minutes: '45', allDay: false })).toEqual({
			plannedAt: '2026-11-18T09:00:00.000Z', plannedAllDay: false, plannedMinutes: 45
		});
	});
	it('builds an all-day patch at the Berlin day start', () => {
		expect(formPatch(entry(), { start: '2026-11-18T15:30', minutes: '45', allDay: true })).toEqual({ plannedAt: '2026-11-17T23:00:00.000Z', plannedAllDay: true });
	});
	it('accepts a number from a bound number input', () => {
		expect(formPatch(entry(), { start: '2026-11-18T10:00', minutes: 45 as unknown as string, allDay: false })).toMatchObject({ plannedMinutes: 45 });
	});
	it('clears the duration when the field is emptied and rejects bad input', () => {
		expect(formPatch(entry(), { start: '2026-11-18T10:00', minutes: '', allDay: false })).toMatchObject({ plannedMinutes: null });
		expect(formPatch(entry({ plannedMinutes: null }), { start: '2026-11-18T10:00', minutes: '', allDay: false })).not.toHaveProperty('plannedMinutes');
		expect(formPatch(entry(), { start: '', minutes: '30', allDay: false })).toBeNull();
		expect(formPatch(entry(), { start: '2026-11-18T10:00', minutes: '4', allDay: false })).toBeNull();
		expect(formPatch(entry(), { start: '2026-11-18T10:00', minutes: '1441', allDay: false })).toBeNull();
		expect(formPatch(entry(), { start: '2026-11-18T10:00', minutes: '2.5', allDay: false })).toBeNull();
	});
});
