<script lang="ts">
	import { api, type Review } from '#lib/api.js';
	import { decisionNeedsNote, type ReviewDecision } from '#lib/commandCenter.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { reviewUndo } from '#lib/reviewUndo.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ChatField from '../card/ChatField.svelte';
	import Markdown from '../card/Markdown.svelte';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import ClipboardCheck from '@lucide/svelte/icons/clipboard-check';

	/** A pending review: summary, optional note and the two decisions. */
	interface Props {
		taskID: string;
		summary: string;
		requestedBy?: string | null;
		context?: string;
		/** Render the summary's bullet points and emphasis (card detail) instead of plain text. */
		markdown?: boolean;
		/** Opens the card detail; renders a button inside the card. */
		onopen?: () => void;
		ondecided: () => void | Promise<void>;
	}
	let { taskID, summary, requestedBy, context, markdown = false, onopen, ondecided }: Props = $props();

	let note = $state('');
	let busy = $state(false);
	let needNote = $state(false);

	async function decide(decision: ReviewDecision) {
		if (busy) return;
		if (decisionNeedsNote(decision, note)) {
			needNote = true;
			return;
		}
		needNote = false;
		busy = true;
		let decided: Review | undefined;
		const ok = await attempt(async () => {
			decided = await api.decideReview(taskID, decision, note.trim());
		});
		busy = false;
		if (ok) {
			note = '';
			reviewUndo.offer(taskID, decided?.undoUntil);
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
			{#if markdown}
				<div data-testid="review-summary"><Markdown text={summary} /></div>
			{:else}
				<p class="break-words whitespace-pre-wrap" data-testid="review-summary">{summary}</p>
			{/if}
		</div>
	</div>
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
			<Button type="button" class="rounded-full max-sm:w-full" disabled={busy} data-testid="review-accept" onclick={() => decide('accept')}>{t('cc.review.accept')}</Button>
		</div>
	</form>
	{#if onopen}
		<div class="-mx-2.5 -mb-2.5 flex border-t px-1.5 py-1">
			<Button variant="ghost" size="sm" class="text-ui-accent-ink ml-auto max-sm:w-full max-sm:justify-between" data-testid="card-open" onclick={onopen}>{t('cc.card.open')}<ChevronRight class="size-4" aria-hidden="true" /></Button>
		</div>
	{/if}
</div>
