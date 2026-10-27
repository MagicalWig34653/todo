<script lang="ts">
	import type { Snippet } from 'svelte';
	import { cn } from '#lib/utils.js';

	/** Bordered card with optional title row. Used for settings-like groups (account, teams, search metadata). */
	let {
		title,
		description,
		action,
		children,
		class: className
	}: { title?: string; description?: string; action?: Snippet; children?: Snippet; class?: string } = $props();
</script>

<section class={cn('bg-card text-card-foreground flex flex-col gap-3 rounded-xl border p-4 shadow-card sm:p-5', className)}>
	{#if title || action}
		<div class="flex flex-wrap items-start justify-between gap-2">
			<div class="min-w-0">
				{#if title}<h3 class="text-base leading-tight font-semibold">{title}</h3>{/if}
				{#if description}<p class="text-muted-foreground mt-1 text-[13px]">{description}</p>{/if}
			</div>
			{#if action}<div class="flex items-center gap-2">{@render action()}</div>{/if}
		</div>
	{/if}
	{@render children?.()}
</section>
