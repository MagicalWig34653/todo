import { t } from './i18n/index.js';

/**
 * Review with variants (card 1D9C8B0C, contract command-center 1.8.0): decoding and display rules. Pure, no DOM.
 * A review without `variants` (older server, plain review) is simply not a choice; every function tolerates that.
 */
export interface ReviewVariant {
	id: string;
	label: string;
	description?: string;
	attachmentID?: string;
}

/** The loosely typed part of a review (`Review`, `ReviewBrief`) these helpers read. */
export interface VariantReview {
	id?: string;
	state?: string;
	variants?: unknown;
	chosenVariantID?: string | null;
}

/** Server limits: 2 to 4 variants. */
export const VARIANTS_MIN = 2;

const text = (v: unknown): string | undefined => (typeof v === 'string' && v.trim() ? v : undefined);

/** Valid variants of a review in server order; malformed entries are dropped, fewer than two mean "no choice". */
export function variantsOf(review: { variants?: unknown } | null | undefined): ReviewVariant[] {
	const raw = review?.variants;
	if (!Array.isArray(raw)) return [];
	const out: ReviewVariant[] = [];
	for (const item of raw) {
		if (typeof item !== 'object' || item === null) continue;
		const e = item as Record<string, unknown>;
		const id = text(e.id);
		const label = text(e.label);
		if (!id || !label) continue;
		const v: ReviewVariant = { id, label };
		const description = text(e.description);
		const attachmentID = text(e.attachmentID);
		if (description) v.description = description;
		if (attachmentID) v.attachmentID = attachmentID;
		out.push(v);
	}
	return out.length >= VARIANTS_MIN ? out : [];
}

export const hasVariants = (review: { variants?: unknown } | null | undefined): boolean => variantsOf(review).length > 0;

/** Pending and offering variants: "Freigeben" is replaced by the choice. */
export const needsChoice = (review: VariantReview | null | undefined): boolean => review?.state === 'pending' && hasVariants(review);

/** One-letter ids are shown upper case, exactly like the server's chat line "Variante B gewählt: Label". */
export const variantName = (id: string): string => (id.length === 1 ? id.toUpperCase() : id);

/** Accessible name of the choose button, e.g. "Wählen: Variante B, Radarkarte". */
export const chooseLabel = (v: ReviewVariant): string => t('cc.review.variants.choose', { name: variantName(v.id), label: v.label });

export function chosenVariant(review: VariantReview | null | undefined): ReviewVariant | null {
	const id = review?.chosenVariantID;
	if (!id) return null;
	return variantsOf(review).find((v) => v.id === id) ?? null;
}

export function otherVariants(review: VariantReview | null | undefined): ReviewVariant[] {
	const id = review?.chosenVariantID;
	return variantsOf(review).filter((v) => v.id !== id);
}

/** "Variante B gewählt: Radarkarte", or null when nothing was chosen. */
export function chosenText(review: VariantReview | null | undefined): string | null {
	const v = chosenVariant(review);
	return v ? t('cc.review.variants.chosen', { name: variantName(v.id), label: v.label }) : null;
}

/**
 * The activity entry that carries the current choice: the newest `review.accepted` of this review. Earlier acceptances were
 * taken back (undo) and may have chosen another variant, so they must not claim the current choice. Null without a choice.
 */
export function choiceActivity(
	activities: readonly { id: string; kind: string; sequence?: number; subjectID?: string | null }[],
	review: VariantReview | null | undefined
): { id: string; text: string } | null {
	const text = chosenText(review);
	if (!text || !review?.id || review.state !== 'accepted') return null;
	let latest: { id: string; sequence: number } | null = null;
	activities.forEach((a, i) => {
		if (a.kind !== 'review.accepted' || a.subjectID !== review.id) return;
		const seq = a.sequence ?? -i; // list order is newest first when there is no sequence
		if (!latest || seq > latest.sequence) latest = { id: a.id, sequence: seq };
	});
	return latest ? { id: (latest as { id: string }).id, text } : null;
}

/**
 * What the card shows for the picture of a variant. Only a variant that has an attachment gets a picture slot: without one there
 * is nothing to show, so no empty area and no "no image" placeholder (compact card). An attachment whose preview does not load
 * (e.g. a PDF, 415) becomes a small fallback with the label.
 */
export function previewState(v: ReviewVariant, loadFailed: boolean): 'image' | 'fallback' | 'none' {
	if (!v.attachmentID) return 'none';
	return loadFailed ? 'fallback' : 'image';
}

/**
 * Roving focus over the "Wählen" buttons of one review (one tab stop per group). Arrow right/down = next, left/up = previous,
 * Home/End = first/last. Stops at the ends (no wrapping): a stray Enter then never lands on a surprising variant.
 * Returns the new index, or null when the key is not ours (Tab, Enter, Space stay native; modified keys such as Alt+Arrow
 * are browser navigation).
 */
export function roveFocus(
	e: { key: string; altKey?: boolean; ctrlKey?: boolean; metaKey?: boolean; shiftKey?: boolean },
	current: number,
	count: number
): number | null {
	if (count <= 0 || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return null;
	const last = count - 1;
	const at = Math.min(Math.max(current, 0), last);
	switch (e.key) {
		case 'ArrowRight':
		case 'ArrowDown':
			return Math.min(at + 1, last);
		case 'ArrowLeft':
		case 'ArrowUp':
			return Math.max(at - 1, 0);
		case 'Home':
			return 0;
		case 'End':
			return last;
		default:
			return null;
	}
}
