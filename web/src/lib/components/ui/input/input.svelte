<script lang="ts">
	import type { HTMLInputAttributes } from 'svelte/elements';
	import { cn } from '#lib/utils.js';

	let { value = $bindable(), class: className, ...rest }: HTMLInputAttributes = $props();
</script>

<input
	bind:value
	class={cn(
		'border-input bg-background placeholder:text-muted-foreground focus-visible:ring-ring flex h-9 w-full rounded-md border px-3 py-1 text-sm outline-none focus-visible:ring-2 disabled:opacity-50',
		className
	)}
	{...rest}
/>
