<script lang="ts">
	import { api } from '#lib/api.js';
	import { decisionNeedsNote, type ReviewDecision } from '#lib/commandCenter.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import ClipboardCheck from '@lucide/svelte/icons/clipboard-check';

	/** A pending review: summary, optional note and the two decisions. */
	interface Props {
		taskID: string;
		summary: string;
		requestedBy?: string | null;
		context?: string;
		ondecided: () => void | Promise<void>;
	}
	let { taskID, summary, requestedBy, context, ondecided }: Props = $props();

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
		const ok = await attempt(() => api.decideReview(taskID, decision, note.trim()));
		busy = false;
		if (ok) note = '';
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
			<p class="break-words whitespace-pre-wrap" data-testid="review-summary">{summary}</p>
		</div>
	</div>
	<Textarea
		bind:value={note}
		rows={2}
		class="min-h-14"
		maxlength={4000}
		placeholder={t('cc.review.note')}
		aria-label={t('cc.review.note')}
		aria-invalid={needNote}
		data-testid="review-note"
		oninput={() => (needNote = false)}
	/>
	{#if needNote}<p class="text-destructive text-xs" role="alert">{t('cc.review.noteRequired')}</p>{/if}
	<div class="flex flex-wrap justify-end gap-1.5">
		<Button size="sm" variant="outline" disabled={busy} data-testid="review-changes" onclick={() => decide('request_changes')}>{t('cc.review.changes')}</Button>
		<Button size="sm" disabled={busy} data-testid="review-accept" onclick={() => decide('accept')}>{t('cc.review.accept')}</Button>
	</div>
</div>
