<script lang="ts">
	import Timestamp from '../Timestamp.svelte';
	import { api, type Review } from '#lib/api.js';
	import { decisionNeedsNote, type ReviewDecision } from '#lib/commandCenter.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { reviewUndo } from '#lib/reviewUndo.svelte.js';
	import { chosenText, variantsOf } from '#lib/reviewVariants.js';
	import ReviewVariants from './ReviewVariants.svelte';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ChatField from '../card/ChatField.svelte';
	import Markdown from '../card/Markdown.svelte';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import ClipboardCheck from '@lucide/svelte/icons/clipboard-check';

	/** A pending review: summary, optional note and the two decisions. */
	interface Props {
		createdAt?: string | null;
		decidedAt?: string | null;
		taskID: string;
		summary: string;
		requestedBy?: string | null;
		context?: string;
		/** The brain recommended this review (derived by the server). */
		brainRecommended?: boolean;
		/** Render the summary's bullet points and emphasis (card detail) instead of plain text. */
		markdown?: boolean;
		/** Opens the card detail; renders a button inside the card. */
		onopen?: () => void;
		/** Offered variants (card 1D9C8B0C): "Freigeben" is replaced by one "Wählen" per variant. Absent or malformed = a plain review. */
		variants?: unknown;
		ondecided: () => void | Promise<void>;
	}
	let { createdAt, decidedAt, taskID, summary, requestedBy, context, brainRecommended = false, markdown = false, onopen, variants: rawVariants, ondecided }: Props = $props();

	let note = $state('');
	let busy = $state(false);
	let needNote = $state(false);
	let choosing = $state<string | null>(null);
	const variants = $derived(variantsOf({ variants: rawVariants }));

	async function decide(decision: ReviewDecision, variantID?: string) {
		if (busy) return;
		if (decisionNeedsNote(decision, note)) {
			needNote = true;
			return;
		}
		needNote = false;
		busy = true;
		choosing = variantID ?? null;
		let decided: Review | undefined;
		const ok = await attempt(async () => {
			decided = await api.decideReview(taskID, decision, note.trim(), variantID);
		});
		busy = false;
		choosing = null;
		if (ok) {
			note = '';
			const picked = variantID ? variants.find((v) => v.id === variantID) : undefined;
			reviewUndo.offer(taskID, decided?.undoUntil, picked ? chosenText({ variants, chosenVariantID: picked.id }) : null);
		}
		// Also after a conflict (already decided elsewhere): show the real state.
		await ondecided();
	}
</script>

<div class="bg-warning-soft/60 flex flex-col gap-2 rounded-lg border p-2.5 text-sm" data-testid="review" data-task-id={taskID}>
	<div class="flex items-start gap-2">
		<ClipboardCheck class="text-warning mt-0.5 size-4 shrink-0" aria-hidden="true" />
		<div class="min-w-0 flex-1">
			{#if context}<p class="text-muted-foreground mb-0.5 text-xs">{context}</p>{/if}
			{#if requestedBy}<p class="text-muted-foreground text-xs">{t('cc.review.title', { who: requestedBy })}</p>{/if}
			<p class="text-muted-foreground text-xs"><Timestamp value={createdAt} label="time.requested" />{#if decidedAt} · <Timestamp value={decidedAt} label="time.decided" />{/if}</p>
			{#if brainRecommended}<Badge variant="accent" class="my-1" data-testid="review-brain-badge">{t('cc.review.brain')}</Badge>{/if}
			{#if variants.length > 0}<Badge variant="warning" class="my-1" data-testid="review-choice-badge">{t('cc.review.variants.badge')}</Badge>{/if}
			{#if markdown}
				<div data-testid="review-summary"><Markdown text={summary} /></div>
			{:else}
				<p class="break-words whitespace-pre-wrap" data-testid="review-summary">{summary}</p>
			{/if}
		</div>
	</div>
	{#if variants.length > 0}
		<ReviewVariants {variants} {busy} {choosing} onchoose={(id) => decide('accept', id)} />
	{/if}
	<form
		class="flex min-w-0 flex-col gap-1.5"
		onsubmit={(e) => {
			e.preventDefault();
			decide('request_changes');
		}}
	>
		<ChatField
			bind:value={note}
			enterSends={false}
			maxlength={4000}
			busy={busy}
			canSend={true}
			onsend={() => decide('request_changes')}
			placeholder={t('cc.review.note')}
			label={t('cc.review.note')}
			sendLabel={t('cc.review.changes')}
			fieldTestid="review-note"
			sendTestid="review-changes"
		/>
		{#if needNote}<p class="text-destructive px-4 text-xs" role="alert">{t('cc.review.noteRequired')}</p>{/if}
		<div class="flex flex-wrap items-center justify-between gap-2 px-1">
			<p class="text-muted-foreground text-xs">{t('cc.review.sendHint')}</p>
			{#if variants.length === 0}
				<Button type="button" class="rounded-full max-sm:w-full" disabled={busy} data-testid="review-accept" onclick={() => decide('accept')}>{t('cc.review.accept')}</Button>
			{/if}
		</div>
	</form>
	{#if onopen}
		<div class="-mx-2.5 -mb-2.5 flex border-t px-1.5 py-1">
			<Button variant="ghost" size="sm" class="text-ui-accent-ink ml-auto max-sm:w-full max-sm:justify-between" data-testid="card-open" onclick={onopen}>{t('cc.card.open')}<ChevronRight class="size-4" aria-hidden="true" /></Button>
		</div>
	{/if}
</div>
