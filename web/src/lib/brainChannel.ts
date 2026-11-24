/** Channel #brain (contracts/voice.yaml, ADR 0030): pure helpers for the read-only history in the PWA. */

export type ChannelMessageKind = 'text' | 'voice_in' | 'voice_out' | 'status';

export interface ChannelMessage {
	id: string;
	kind: ChannelMessageKind;
	author: 'person' | 'agent';
	/** Message text, or the transcript of a voice message. */
	text: string | null;
	/** Audio attachment (role voice); downloaded through the attachment route with the session. */
	attachmentID: string | null;
	clientUUID?: string | null;
	createdAt: string;
}

export interface ChannelMessagePage {
	items: ChannelMessage[];
	nextCursor?: string | null;
}

export type Speaker = 'you' | 'brain' | 'status';

/** The server lists newest first; a conversation reads oldest first. */
export const oldestFirst = (items: readonly ChannelMessage[]): ChannelMessage[] => [...items].reverse();

export function speakerOf(m: ChannelMessage): Speaker {
	if (m.kind === 'status') return 'status';
	return m.author === 'person' ? 'you' : 'brain';
}

export const audioUrl = (m: ChannelMessage): string | null => (m.attachmentID ? `/v1/attachments/${m.attachmentID}/download` : null);

/** Union by id, newest first: used for the first page, live refreshes (newer) and "load older". */
export function mergePage(current: readonly ChannelMessage[], page: readonly ChannelMessage[]): ChannelMessage[] {
	const byID = new Map<string, ChannelMessage>();
	for (const m of [...page, ...current]) byID.set(m.id, m);
	return [...byID.values()].sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0));
}
