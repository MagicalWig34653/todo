import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import { createApi } from '../src/lib/api';
import { t } from '../src/lib/i18n/index.js';
import { REVIEW_UNDO_MINUTES, REVIEW_UNDO_WINDOW_MS, formatUndoRemaining } from '../src/lib/reviewUndo.js';
import {
	chooseLabel,
	choiceActivity,
	chosenText,
	chosenVariant,
	hasVariants,
	needsChoice,
	otherVariants,
	previewState,
	roveFocus,
	variantName,
	variantsOf
} from '../src/lib/reviewVariants.js';

const A = { id: 'a', label: 'Windkarte', description: 'Pfeile', attachmentID: 'att-1' };
const B = { id: 'b', label: 'Radarkarte' };

describe('decoding variants tolerantly', () => {
	it('treats missing, null and malformed variants as a review without a choice', () => {
		expect(variantsOf(undefined)).toEqual([]);
		expect(variantsOf(null)).toEqual([]);
		expect(variantsOf({})).toEqual([]);
		expect(variantsOf({ variants: null })).toEqual([]);
		expect(variantsOf({ variants: 'x' })).toEqual([]);
		expect(variantsOf({ variants: [] })).toEqual([]);
		expect(hasVariants({})).toBe(false);
	});
	it('keeps valid entries, drops entries without id or label, normalises optional fields', () => {
		const v = variantsOf({ variants: [A, { id: 'c' }, null, 5, { label: 'x' }, { id: 'd', label: 'Temp', description: null, attachmentID: null }] });
		expect(v).toEqual([A, { id: 'd', label: 'Temp' }]);
		expect(hasVariants({ variants: [A, B] })).toBe(true);
	});
	it('a single usable variant is not a choice (the server only knows 2 to 4)', () => {
		expect(hasVariants({ variants: [A] })).toBe(false);
	});
});

describe('names and texts', () => {
	it('shows one-letter ids upper case like the server chat line, longer ids as they are', () => {
		expect(variantName('b')).toBe('B');
		expect(variantName('radar-1')).toBe('radar-1');
	});
	it('names the button with variant and label', () => {
		expect(chooseLabel(B)).toBe('Wählen: Variante B, Radarkarte');
	});
	it('only a pending review with variants needs a choice', () => {
		expect(needsChoice({ state: 'pending', variants: [A, B] })).toBe(true);
		expect(needsChoice({ state: 'pending' })).toBe(false);
		expect(needsChoice({ state: 'accepted', variants: [A, B], chosenVariantID: 'b' })).toBe(false);
	});
	it('finds the chosen variant and the others', () => {
		const r = { state: 'accepted', variants: [A, B], chosenVariantID: 'b' };
		expect(chosenVariant(r)).toEqual(B);
		expect(otherVariants(r)).toEqual([A]);
		expect(chosenText(r)).toBe('Variante B gewählt: Radarkarte');
		expect(chosenVariant({ variants: [A, B] })).toBeNull();
		expect(chosenVariant({ variants: [A, B], chosenVariantID: 'zz' })).toBeNull();
		expect(chosenText({ variants: [A, B] })).toBeNull();
	});
	it('names the choice on the newest accepting activity of the review only (earlier ones were taken back)', () => {
		const r = { id: 'r1', state: 'accepted', variants: [A, B], chosenVariantID: 'b' };
		const acts = [
			{ id: 'x5', kind: 'review.accepted', sequence: 9, subjectID: 'r1' },
			{ id: 'x4', kind: 'review.undone', sequence: 8, subjectID: 'r1' },
			{ id: 'x3', kind: 'review.accepted', sequence: 7, subjectID: 'r1' },
			{ id: 'x2', kind: 'review.accepted', sequence: 6, subjectID: 'other' },
			{ id: 'x1', kind: 'review.requested', sequence: 5, subjectID: 'r1' }
		];
		expect(choiceActivity(acts, r)).toEqual({ id: 'x5', text: 'Variante B gewählt: Radarkarte' });
		expect(choiceActivity([...acts].reverse(), r)?.id).toBe('x5'); // independent of list order
		expect(choiceActivity(acts.slice(1), r)?.id).toBe('x3');
		expect(choiceActivity([{ id: 'n', kind: 'review.accepted', subjectID: 'other' }], r)).toBeNull();
		expect(choiceActivity(acts, { ...r, state: 'pending', chosenVariantID: null })).toBeNull();
		expect(choiceActivity(acts, { id: 'r1', state: 'accepted' })).toBeNull(); // plain review
		expect(choiceActivity(acts, null)).toBeNull();
	});
});

describe('undo window text matches the window', () => {
	it('names the same number of minutes as the constant and as the bar starts with', () => {
		expect(REVIEW_UNDO_WINDOW_MS).toBe(REVIEW_UNDO_MINUTES * 60_000);
		expect(formatUndoRemaining(REVIEW_UNDO_WINDOW_MS)).toBe(`${REVIEW_UNDO_MINUTES}:00`);
		const hint = t('cc.review.variants.hint', { minutes: REVIEW_UNDO_MINUTES });
		expect(hint).toContain(`${REVIEW_UNDO_MINUTES} Minuten`);
		expect(hint).not.toMatch(/\{minutes\}/);
	});
	it('equals the server window (WorkflowLimits.reviewUndoWindow)', () => {
		const swift = readFileSync(resolve(__dirname, '../../Sources/TodoKit/CommandCenter/WorkflowService.swift'), 'utf8');
		const m = swift.match(/static let reviewUndoWindow: TimeInterval = (\d+) \* (\d+)/);
		expect(m, 'reviewUndoWindow not found in WorkflowService.swift').not.toBeNull();
		expect(Number(m![1]) * Number(m![2]) * 1000).toBe(REVIEW_UNDO_WINDOW_MS);
	});
	it('no German text hard-codes another minute count for the undo window', () => {
		const text = t('cc.review.variants.hint', { minutes: REVIEW_UNDO_MINUTES });
		for (const n of text.match(/\d+(?= Minuten)/g) ?? []) expect(Number(n)).toBe(REVIEW_UNDO_MINUTES);
	});
});

describe('api: choosing a variant', () => {
	const calls: { url: string; init?: RequestInit }[] = [];
	const api = createApi(async (url, init) => {
		calls.push({ url, init });
		return new Response(JSON.stringify({ id: 'r1', state: 'accepted', chosenVariantID: 'b' }), { status: 200, headers: { 'Content-Type': 'application/json' } });
	});
	beforeEach(() => (calls.length = 0));
	it('sends variantID with accept only when given; reviews without variants keep the old body', async () => {
		await api.decideReview('t1', 'accept', '', 'b');
		expect(JSON.parse(String(calls[0].init?.body))).toEqual({ decision: 'accept', variantID: 'b' });
		await api.decideReview('t1', 'accept');
		expect(JSON.parse(String(calls[1].init?.body))).toEqual({ decision: 'accept' });
		await api.decideReview('t1', 'request_changes', 'Mehr Kontrast');
		expect(JSON.parse(String(calls[2].init?.body))).toEqual({ decision: 'request_changes', note: 'Mehr Kontrast' });
	});
	it('builds the preview URL of the variant attachment', () => {
		expect(api.attachmentPreviewURL('att-1')).toBe('/v1/attachments/att-1/preview');
	});
});

describe('image slot of a variant (no empty picture area without an attachment)', () => {
	it('a variant without attachment has no preview at all, not even a placeholder', () => {
		expect(previewState(B, false)).toBe('none');
		expect(previewState(B, true)).toBe('none');
		expect(previewState({ id: 'c', label: 'x', attachmentID: '' }, false)).toBe('none');
	});
	it('a variant with attachment shows the image until it fails to load, then a compact fallback', () => {
		expect(previewState(A, false)).toBe('image');
		expect(previewState(A, true)).toBe('fallback');
	});
});

describe('roving focus over the variant buttons (arrow keys, Home/End; stops at the ends)', () => {
	const key = (k: string, mods: Partial<Record<'altKey' | 'ctrlKey' | 'metaKey' | 'shiftKey', boolean>> = {}) => ({ key: k, ...mods });
	it('right and down go to the next button, left and up to the previous one', () => {
		expect(roveFocus(key('ArrowRight'), 0, 3)).toBe(1);
		expect(roveFocus(key('ArrowDown'), 1, 3)).toBe(2);
		expect(roveFocus(key('ArrowLeft'), 2, 3)).toBe(1);
		expect(roveFocus(key('ArrowUp'), 1, 3)).toBe(0);
	});
	it('stops at the ends instead of wrapping (a stray Enter must not pick a surprising variant)', () => {
		expect(roveFocus(key('ArrowRight'), 2, 3)).toBe(2);
		expect(roveFocus(key('ArrowDown'), 1, 2)).toBe(1);
		expect(roveFocus(key('ArrowLeft'), 0, 3)).toBe(0);
		expect(roveFocus(key('ArrowUp'), 0, 2)).toBe(0);
	});
	it('Home and End jump to the first and last button', () => {
		expect(roveFocus(key('Home'), 2, 4)).toBe(0);
		expect(roveFocus(key('End'), 0, 4)).toBe(3);
	});
	it('ignores other keys and keys with modifiers (Alt+Arrow is browser navigation); Tab, Enter and Space stay native', () => {
		for (const k of ['Tab', 'Enter', ' ', 'a', 'PageDown']) expect(roveFocus(key(k), 0, 3)).toBeNull();
		for (const m of ['altKey', 'ctrlKey', 'metaKey', 'shiftKey'] as const) expect(roveFocus(key('ArrowRight', { [m]: true }), 0, 3)).toBeNull();
	});
	it('is safe without buttons and with an out-of-range current index', () => {
		expect(roveFocus(key('ArrowRight'), 0, 0)).toBeNull();
		expect(roveFocus(key('ArrowRight'), 9, 3)).toBe(2);
		expect(roveFocus(key('ArrowLeft'), -4, 3)).toBe(0);
	});
});
