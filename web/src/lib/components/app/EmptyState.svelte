<script lang="ts">
	import type { Component, Snippet } from 'svelte';

	let {
		title,
		icon: Icon,
		children
	}: { title: string; icon?: Component<{ class?: string; 'aria-hidden'?: 'true' | boolean }>; children?: Snippet } = $props();
</script>

<div class="text-muted-foreground flex flex-col items-center gap-2 rounded-xl border border-dashed px-6 py-10 text-center text-sm">
	{#if Icon}<Icon class="size-6" aria-hidden="true" />{/if}
	<p>{title}</p>
	{@render children?.()}
</div>
