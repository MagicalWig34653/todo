<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { undoRemainingMs } from '#lib/reviewUndo.js';
	import { reviewUndo } from '#lib/reviewUndo.svelte.js';
	import ReviewUndoBar from './ReviewUndoBar.svelte';

	/** Toast right after a decision outside the card window (inside it, the result section carries the same bar). */
	let now = $state(Date.now());
	const timer = setInterval(() => (now = Date.now()), 1000);
	$effect(() => () => clearInterval(timer));
	$effect(() => {
		if (reviewUndo.until && undoRemainingMs(reviewUndo.until, now) <= 0) reviewUndo.clear();
	});
</script>

{#if reviewUndo.taskID && reviewUndo.until && !cardDetail.visible}
	<div class="bg-card text-card-foreground fixed inset-x-4 bottom-[calc(5rem+env(safe-area-inset-bottom))] z-50 mx-auto flex w-fit max-w-[calc(100vw-2rem)] items-center menu:bottom-4 gap-3 rounded-lg border px-3 py-2 shadow-lg" role="status" data-testid="review-undo-toast">
		<span class="text-sm" data-testid="review-undo-message">{reviewUndo.message ?? t('cc.review.decided')}</span>
		<ReviewUndoBar taskID={reviewUndo.taskID} until={reviewUndo.until} />
	</div>
{/if}
