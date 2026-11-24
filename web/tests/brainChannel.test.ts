import { describe, expect, it } from 'vitest';
import { audioUrl, mergePage, oldestFirst, speakerOf, type ChannelMessage } from '../src/lib/brainChannel';

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const msg = (n: number, over: Partial<ChannelMessage> = {}): ChannelMessage => ({
	id: id(n), kind: 'text', author: 'person', text: `m${n}`, attachmentID: null, createdAt: `2026-11-24T06:00:0${n}.000Z`, ...over
});

describe('brain channel', () => {
	it('shows messages oldest first although the server sends newest first', () => {
		expect(oldestFirst([msg(3), msg(2), msg(1)]).map((m) => m.id)).toEqual([id(1), id(2), id(3)]);
		expect(oldestFirst([])).toEqual([]);
	});
	it('names the speaker by author and kind', () => {
		expect(speakerOf(msg(1))).toBe('you');
		expect(speakerOf(msg(2, { kind: 'voice_in' }))).toBe('you');
		expect(speakerOf(msg(3, { kind: 'voice_out', author: 'agent' }))).toBe('brain');
		expect(speakerOf(msg(4, { kind: 'status', author: 'agent' }))).toBe('status');
	});
	it('builds the download path of the audio attachment only for messages with audio', () => {
		expect(audioUrl(msg(1))).toBeNull();
		expect(audioUrl(msg(2, { kind: 'voice_in', attachmentID: id(9) }))).toBe(`/v1/attachments/${id(9)}/download`);
	});
	it('merges a page without duplicates, keeping the order newest first (older and newer pages alike)', () => {
		const first = [msg(5), msg(4)];
		const older = [msg(4), msg(3), msg(2)];
		expect(mergePage(first, older).map((m) => m.id)).toEqual([id(5), id(4), id(3), id(2)]);
		expect(mergePage([], older)).toEqual(older);
		expect(mergePage([msg(3), msg(2)], [msg(5), msg(4), msg(3)]).map((m) => m.id)).toEqual([id(5), id(4), id(3), id(2)]);
	});
});
