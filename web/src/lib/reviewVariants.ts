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

/** Extra text for the activity entry of the decision that accepted `review` with a choice. */
export function activityChoice(activity: { kind: string; subjectID?: string | null }, review: VariantReview | null | undefined): string | null {
	if (activity.kind !== 'review.accepted' || !review?.id || activity.subjectID !== review.id) return null;
	return chosenText(review);
}
