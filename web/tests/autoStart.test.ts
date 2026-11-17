import { describe, expect, it, vi } from 'vitest';
import {
	autoStartBlock, autoStartErrorKey, autoStartMarks, autoStartNeedsDevice, releasedInfo, releasedNote, revokedTitles, saveAutoStart
} from '../src/lib/autoStart';
import { ApiError, type ScheduleEntry } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';

const entry = (over: Partial<ScheduleEntry> = {}): ScheduleEntry => ({
	taskID: 't1', projectID: 'p1', title: 'Karte', status: 'open', version: 3, plannedAt: '2026-11-17T09:00:00Z', plannedMinutes: 60,
	plannedAllDay: false, dueAt: null, blocked: false, canEdit: true, autoStart: false, conflicts: [], ...over
});
const NOW = new Date('2026-11-17T12:00:00Z');
const ok = { status: 'open', plannedAt: '2026-11-17T09:00:00Z', plannedAllDay: false, isOwner: true, bindings: 1 } as const;

describe('autoStartBlock', () => {
	it('is null when everything is in place', () => expect(autoStartBlock(ok)).toBeNull());
	it('names the first missing precondition', () => {
		expect(autoStartBlock({ ...ok, isOwner: false })).toBe('autostart.block.owner');
		expect(autoStartBlock({ ...ok, status: 'done' })).toBe('autostart.block.done');
		expect(autoStartBlock({ ...ok, plannedAt: null })).toBe('autostart.block.start');
		expect(autoStartBlock({ ...ok, plannedAllDay: true })).toBe('autostart.block.allDay');
		expect(autoStartBlock({ ...ok, bindings: 0 })).toBe('autostart.block.binding');
	});
	it('owner check wins over the rest', () => expect(autoStartBlock({ ...ok, isOwner: false, plannedAt: null })).toBe('autostart.block.owner'));
});

describe('autoStartNeedsDevice', () => {
	it('only when bindings sit on more than one device', () => {
		expect(autoStartNeedsDevice([{ deviceID: 'a' }, { deviceID: 'a' }])).toBe(false);
		expect(autoStartNeedsDevice([{ deviceID: 'a' }, { deviceID: 'b' }])).toBe(true);
		expect(autoStartNeedsDevice([])).toBe(false);
	});
});

describe('autoStartErrorKey', () => {
	it.each([
		['version_conflict', 'autostart.error.version_conflict'],
		['task_done', 'autostart.error.task_done'],
		['planned_start_required', 'autostart.error.planned_start_required'],
		['all_day_not_allowed', 'autostart.error.all_day_not_allowed'],
		['no_binding', 'autostart.error.no_binding'],
		['device_required', 'autostart.error.device_required']
	])('maps %s', (reason, key) => expect(autoStartErrorKey(new ApiError(409, reason))).toBe(key));
	it('maps 403 to owner/session text and the rest to generic', () => {
		expect(autoStartErrorKey(new ApiError(403, 'forbidden'))).toBe('autostart.error.forbidden');
		expect(autoStartErrorKey(new ApiError(500))).toBe('autostart.error.generic');
		expect(autoStartErrorKey(new Error('x'))).toBe('autostart.error.generic');
	});
	it('every key exists in de', () => {
		for (const k of ['version_conflict', 'task_done', 'planned_start_required', 'all_day_not_allowed', 'no_binding', 'device_required', 'forbidden', 'generic'])
			expect(`autostart.error.${k}` in de).toBe(true);
	});
});

describe('autoStartMarks', () => {
	it('shows nothing for a plain card', () => expect(autoStartMarks(entry(), NOW)).toEqual({ badge: false, overdue: false, startedAt: null }));
	it('marks a card with permission', () => expect(autoStartMarks(entry({ autoStart: true, plannedAt: '2026-11-17T15:00:00Z' }), NOW)).toEqual({ badge: true, overdue: false, startedAt: null }));
	it('marks overdue when the start is past and still waiting', () => expect(autoStartMarks(entry({ autoStart: true }), NOW)).toEqual({ badge: true, overdue: true, startedAt: null }));
	it('shows the automatic start time and no badge or overdue after hand-over', () => {
		const m = autoStartMarks(entry({ autoStart: false, autoStartedAt: '2026-11-17T09:02:00Z' }), NOW);
		expect(m.badge).toBe(false);
		expect(m.overdue).toBe(false);
		expect(m.startedAt?.toISOString()).toBe('2026-11-17T09:02:00.000Z');
	});
	it('ignores a card without a start time', () => expect(autoStartMarks(entry({ autoStart: true, plannedAt: null }), NOW).overdue).toBe(false));
});

describe('revokedTitles', () => {
	it('lists cards that lost the permission without having been started', () => {
		const prev = [entry({ taskID: 'a', title: 'A', autoStart: true }), entry({ taskID: 'b', title: 'B', autoStart: true }), entry({ taskID: 'c', title: 'C', autoStart: true })];
		const next = [entry({ taskID: 'a', autoStart: false }), entry({ taskID: 'b', autoStart: false, autoStartedAt: '2026-11-17T09:00:00Z' }), entry({ taskID: 'c', autoStart: true })];
		expect(revokedTitles(prev, next)).toEqual(['A']);
	});
	it('a card that vanished from the window is not a revocation', () => expect(revokedTitles([entry({ autoStart: true })], [])).toEqual([]));
});

describe('released event', () => {
	const ev = (detail: string, kind = 'released') => ({ id: 'e', kind, detail, createdAt: '2026-11-17T09:10:00Z' });
	it('reads the scheduler detail', () => {
		expect(releasedInfo([ev('{"origin":"scheduler","catchup":false,"delayMinutes":1,"plannedAt":"2026-11-17T09:00:00Z"}')]))
			.toEqual({ origin: 'scheduler', catchup: false, delayMinutes: 1, plannedAt: '2026-11-17T09:00:00Z' });
	});
	it('is null for manual releases, empty or broken detail', () => {
		expect(releasedInfo([ev('')])).toBeNull();
		expect(releasedInfo([ev('{oops')])).toBeNull();
		expect(releasedInfo([ev('{"origin":"manual"}')])).toBeNull();
		expect(releasedInfo([ev('{"origin":"scheduler","plannedAt":"2026-11-17T09:00:00Z"}', 'started')])).toBeNull();
		expect(releasedInfo([])).toBeNull();
	});
	it('builds the note texts', () => {
		const normal = releasedNote([ev('{"origin":"scheduler","catchup":false,"delayMinutes":0,"plannedAt":"2026-11-17T09:00:00Z"}')]);
		expect(normal).toContain('automatisch gestartet durch Wächter, geplant für');
		expect(normal).not.toContain('nachgeholt');
		const late = releasedNote([ev('{"origin":"scheduler","catchup":true,"delayMinutes":95,"plannedAt":"2026-11-17T09:00:00Z"}')]);
		expect(late).toContain('automatisch nachgeholt');
		expect(late).toContain('95 Minuten');
		expect(releasedNote([])).toBeNull();
	});
});

describe('saveAutoStart', () => {
	const pt = { task: { id: 't1', version: 4 }, autoStart: true } as never;
	it('sends version, enabled and device', async () => {
		const send = vi.fn().mockResolvedValue(pt);
		const r = await saveAutoStart(send, { taskID: 't1', version: 3 }, true, 'd1');
		expect(send).toHaveBeenCalledWith('t1', { version: 3, enabled: true, deviceID: 'd1' });
		expect(r).toEqual({ ok: true, task: pt });
	});
	it('omits deviceID when none is chosen', async () => {
		const send = vi.fn().mockResolvedValue(pt);
		await saveAutoStart(send, { taskID: 't1', version: 3 }, false);
		expect(send).toHaveBeenCalledWith('t1', { version: 3, enabled: false });
	});
	it('returns a message key on failure', async () => {
		const send = vi.fn().mockRejectedValue(new ApiError(409, 'no_binding'));
		expect(await saveAutoStart(send, { taskID: 't1', version: 3 }, true)).toMatchObject({ ok: false, key: 'autostart.error.no_binding' });
	});
});
