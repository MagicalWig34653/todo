/** Reference to the card shown in the large detail window (`?card=<type>:<id>`) and pure helpers around it. */
import { t } from './i18n/index.js';
import type { ForYouNeed, ForYouPost } from './forYou.js';

export type CardType = 'task' | 'question' | 'review' | 'confirmation';
export interface CardRef {
	type: CardType;
	/** task: task id; question: question id; review: id of the task under review; confirmation: action request id. */
	id: string;
}

export const CARD_TYPES: readonly CardType[] = ['task', 'question', 'review', 'confirmation'];
const ID = /^[A-Za-z0-9-]{8,64}$/;

export function buildCardParam(ref: CardRef): string {
	return `${ref.type}:${ref.id}`;
}

/** Null for anything that is not exactly `<known type>:<plain id>`. */
export function parseCardParam(raw: string | null | undefined): CardRef | null {
	if (!raw) return null;
	const parts = raw.split(':');
	if (parts.length !== 2) return null;
	const [type, id] = parts as [string, string];
	if (!CARD_TYPES.includes(type as CardType) || !ID.test(id)) return null;
	return { type: type as CardType, id };
}

export function cardOfNeed(n: Pick<ForYouNeed, 'kind' | 'taskID' | 'questionID'>): CardRef {
	if (n.kind === 'question' && n.questionID) return { type: 'question', id: n.questionID };
	if (n.kind === 'review') return { type: 'review', id: n.taskID };
	return { type: 'task', id: n.taskID };
}

export function cardOfPost(p: Pick<ForYouPost, 'kind' | 'taskID'>): CardRef {
	return p.kind === 'review' ? { type: 'review', id: p.taskID } : { type: 'task', id: p.taskID };
}

export function cardOfConfirmation(c: { id: string }): CardRef {
	return { type: 'confirmation', id: c.id };
}

/** "vor 5 Min." style relative time; empty for missing or invalid input. */
export function relativeWhen(iso: string | null | undefined, now = new Date()): string {
	if (!iso) return '';
	const ms = now.getTime() - new Date(iso).getTime();
	if (Number.isNaN(ms)) return '';
	const min = Math.floor(ms / 60_000);
	if (min < 1) return t('card.when.now');
	if (min < 60) return t('card.when.minutes', { count: min });
	const hours = Math.floor(min / 60);
	if (hours < 24) return t('card.when.hours', { count: hours });
	const days = Math.floor(hours / 24);
	return t(days === 1 ? 'card.when.day' : 'card.when.days', { count: days });
}

export interface GalleryItem {
	id: string;
	url: string;
	label: string;
}
/** Screenshots of a task for the gallery: build previews first, then image attachments that are not builds already. */
export function galleryOf(
	builds: readonly { attachmentID: string; previewURL: string; label?: string | null; filename: string }[],
	attachments: readonly { id: string; filename: string; mediaType: string }[],
	previewURL: (attachmentID: string) => string
): GalleryItem[] {
	const out: GalleryItem[] = builds.map((b) => ({ id: b.attachmentID, url: b.previewURL, label: b.label || b.filename }));
	const seen = new Set(out.map((i) => i.id));
	for (const a of attachments) {
		if (!a.mediaType.startsWith('image/') || seen.has(a.id)) continue;
		seen.add(a.id);
		out.push({ id: a.id, url: previewURL(a.id), label: a.filename });
	}
	return out;
}
