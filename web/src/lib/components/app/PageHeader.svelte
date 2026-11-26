<script lang="ts">
	import type { Snippet } from 'svelte';
	import Explainer from './Explainer.svelte';

	/** Page head: one title, an optional explanation (one sentence, the rest behind "Mehr erfahren") and actions that wrap below the title on phones. */
	let { title, description, actions, testid }: { title: string; description?: string; actions?: Snippet; testid?: string } = $props();
</script>

<header class="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
	<div class="min-w-0">
		<h2 class="text-2xl leading-tight font-semibold tracking-tight [overflow-wrap:anywhere] sm:text-[28px]" data-testid={testid}>{title}</h2>
		{#if description}<Explainer class="mt-1" text={description} />{/if}
	</div>
	{#if actions}<div class="flex shrink-0 flex-wrap items-center gap-2">{@render actions()}</div>{/if}
</header>
