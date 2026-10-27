<script lang="ts">
	import type { HTMLTextareaAttributes } from 'svelte/elements';
	import { cn } from '#lib/utils.js';

	let { value = $bindable(), class: className, ...rest }: HTMLTextareaAttributes = $props();
</script>

<textarea
	bind:value
	class={cn(
		'border-input bg-background placeholder:text-muted-foreground flex min-h-20 w-full rounded-lg border px-3 py-2 text-sm shadow-xs outline-none transition-colors focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40 disabled:opacity-50',
		className
	)}
	{...rest}
></textarea>
