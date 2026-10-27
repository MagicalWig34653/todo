<script lang="ts">
	import type { HTMLInputAttributes } from 'svelte/elements';
	import { cn } from '#lib/utils.js';

	let { value = $bindable(), class: className, ...rest }: HTMLInputAttributes = $props();
</script>

<input
	data-slot="input"
	bind:value
	class={cn(
		'border-input bg-background placeholder:text-muted-foreground flex h-9 w-full min-w-0 rounded-lg border px-3 py-1 text-sm shadow-xs outline-none transition-colors focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40 disabled:opacity-50',
		className
	)}
	{...rest}
/>
