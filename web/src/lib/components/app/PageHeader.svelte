<script lang="ts">
	import type { Snippet } from 'svelte';

	/** Page head: one title, an optional explanatory line and actions that wrap below the title on phones. */
	let { title, description, actions, testid }: { title: string; description?: string; actions?: Snippet; testid?: string } = $props();
</script>

<header class="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
	<div class="min-w-0">
		<h2 class="text-2xl leading-tight font-semibold tracking-tight sm:text-[28px]" data-testid={testid}>{title}</h2>
		{#if description}<p class="text-muted-foreground mt-1 text-sm">{description}</p>{/if}
	</div>
	{#if actions}<div class="flex shrink-0 flex-wrap items-center gap-2">{@render actions()}</div>{/if}
</header>
