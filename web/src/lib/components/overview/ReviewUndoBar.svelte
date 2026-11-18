<script lang="ts">
	import { onDestroy } from 'svelte';
	import { api } from '#lib/api.js';
	import { liveRefresh } from '#lib/liveRefresh.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatUndoRemaining, undoRemainingMs } from '#lib/reviewUndo.js';
	import { reviewUndo } from '#lib/reviewUndo.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Check from '@lucide/svelte/icons/check';
	import Undo2 from '@lucide/svelte/icons/undo-2';

	/** "Rückgängig" while the server's undo window is open, with the remaining time shown lightly. */
	interface Props {
		taskID: string;
		until: string;
		/** What was decided (e.g. "Variante B gewählt: Radarkarte"); shown as a status line in front of the button. */
		message?: string | null;
		onundone?: () => void | Promise<void>;
	}
	let { taskID, until, message = null, onundone }: Props = $props();

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
	<div
		class="flex flex-wrap items-center gap-x-3 gap-y-2 text-sm {message ? 'border-success/40 bg-success-soft/60 rounded-lg border px-2.5 py-2' : ''}"
		role={message ? 'status' : undefined}
		data-testid="review-undo-bar"
	>
		{#if message}<span class="inline-flex min-w-0 items-center gap-1.5 font-medium" data-testid="review-undo-message"><Check class="text-success size-4 shrink-0" aria-hidden="true" /><span class="break-words">{message}</span></span>{/if}
		<Button size="sm" variant="outline" disabled={busy} data-testid="review-undo" onclick={undo}>
			<Undo2 class="size-3.5" aria-hidden="true" />{t('cc.review.undo')}
		</Button>
		<span class="text-muted-foreground text-xs tabular-nums" data-testid="review-undo-time">{t('cc.review.undoLeft', { time: formatUndoRemaining(remaining) })}</span>
	</div>
{/if}
