<script lang="ts">
	import type { HTMLInputAttributes } from 'svelte/elements';
	import { cn } from '#lib/utils.js';
	let { checked = $bindable(), class: className, ...rest }: Omit<HTMLInputAttributes, 'type'> = $props();
</script>

<input
	type="checkbox"
	data-slot="checkbox"
	bind:checked
	class={cn(
		'border-input bg-background checked:border-ui-accent checked:bg-ui-accent size-[18px] shrink-0 cursor-pointer appearance-none rounded-md border transition-colors focus-visible:ring-2 focus-visible:ring-ring/40 disabled:opacity-50',
		className
	)}
	{...rest}
/>
