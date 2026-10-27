<script lang="ts">
	import type { HTMLSelectAttributes } from 'svelte/elements';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import { cn } from '#lib/utils.js';

	let { value = $bindable(), class: className, children, ...rest }: HTMLSelectAttributes = $props();
</script>

<span class={cn('relative inline-flex min-w-0', className)}>
	<select
		data-slot="select"
		bind:value
		class="border-input bg-background h-9 w-full min-w-0 appearance-none rounded-lg border py-1 pr-8 pl-3 text-sm shadow-xs outline-none transition-colors focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40 disabled:opacity-50"
		{...rest}
	>
		{@render children?.()}
	</select>
	<ChevronDown class="text-muted-foreground pointer-events-none absolute top-1/2 right-2.5 size-4 -translate-y-1/2" aria-hidden="true" />
</span>
