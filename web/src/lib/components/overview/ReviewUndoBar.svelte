<script lang="ts">
	import { onDestroy } from 'svelte';
	import { api } from '#lib/api.js';
	import { liveRefresh } from '#lib/liveRefresh.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatUndoRemaining, undoRemainingMs } from '#lib/reviewUndo.js';
	import { reviewUndo } from '#lib/reviewUndo.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Undo2 from '@lucide/svelte/icons/undo-2';

	/** "Rückgängig" while the server's undo window is open, with the remaining time shown lightly. */
	interface Props {
		taskID: string;
		until: string;
		onundone?: () => void | Promise<void>;
	}
	let { taskID, until, onundone }: Props = $props();

	let now = $state(Date.now());
	let busy = $state(false);
	const remaining = $derived(undoRemainingMs(until, now));
	const timer = setInterval(() => (now = Date.now()), 1000);
	onDestroy(() => clearInterval(timer));

	async function undo() {
		if (busy) return;
		busy = true;
		const ok = await attempt(() => api.undoReviewDecision(taskID));
		busy = false;
		if (ok) reviewUndo.clear();
		liveRefresh.poke();
		await onundone?.();
	}
</script>

{#if remaining > 0}
	<div class="flex flex-wrap items-center gap-2 text-sm" data-testid="review-undo-bar">
		<Button size="sm" variant="outline" disabled={busy} data-testid="review-undo" onclick={undo}>
			<Undo2 class="size-3.5" aria-hidden="true" />{t('cc.review.undo')}
		</Button>
		<span class="text-muted-foreground text-xs tabular-nums" data-testid="review-undo-time">{t('cc.review.undoLeft', { time: formatUndoRemaining(remaining) })}</span>
	</div>
{/if}
