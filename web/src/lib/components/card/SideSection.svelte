<script lang="ts">
	import type { Snippet } from 'svelte';
	import Plus from '@lucide/svelte/icons/plus';
	import X from '@lucide/svelte/icons/x';

	/**
	 * One block of the card detail sidebar: heading on the left, "+" (or a custom action) on the right, a fine line below.
	 * `onadd` renders the "+" button (it turns into "x" while `active`, e.g. while an editor is open).
	 */
	let {
		title,
		addLabel = '',
		onadd,
		active = false,
		testid,
		action,
		children
	}: { title: string; addLabel?: string; onadd?: () => void; active?: boolean; testid?: string; action?: Snippet; children?: Snippet } = $props();
</script>

<section class="border-border/70 flex flex-col gap-1.5 border-b py-3 last:border-b-0" data-testid={testid} aria-label={title}>
	<div class="flex min-h-8 items-center justify-between gap-2">
		<h3 class="text-muted-foreground text-sm font-semibold">{title}</h3>
		{#if action}{@render action()}{:else if onadd}
			<button
				type="button"
				class="text-muted-foreground hover:bg-muted hover:text-foreground hit-area relative -mr-1 inline-flex size-8 shrink-0 items-center justify-center rounded-lg"
				aria-label={addLabel || title}
				aria-expanded={active}
				data-testid={testid ? `${testid}-add` : undefined}
				onclick={onadd}
			>
				{#if active}<X class="size-4" aria-hidden="true" />{:else}<Plus class="size-4" aria-hidden="true" />{/if}
			</button>
		{/if}
	</div>
	{#if children}<div class="flex min-w-0 flex-col gap-2 text-sm">{@render children()}</div>{/if}
</section>
