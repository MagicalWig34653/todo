<script lang="ts">
	import type { Snippet } from 'svelte';
	import { cn } from '#lib/utils.js';

	let {
		onclick,
		danger = false,
		active = false,
		children,
		testid,
		disabled = false
	}: { onclick: () => void; danger?: boolean; active?: boolean; children: Snippet; testid?: string; disabled?: boolean } = $props();
</script>

<button
	type="button"
	{disabled}
	data-testid={testid}
	class={cn(
		'flex min-h-9 w-full items-center gap-2 rounded-lg px-2.5 text-left text-sm transition-colors hover:bg-muted disabled:opacity-50',
		danger && 'text-destructive',
		active && 'bg-muted font-medium'
	)}
	{onclick}
>
	{@render children()}
</button>
