<script lang="ts">
	import { Button } from '#lib/components/ui/button/index.js';

	/**
	 * Answer choices of a question. Shared by every surface that shows options (question card, For you, task detail), so
	 * long texts wrap inside the card instead of overflowing: each choice may shrink (min-w-0), breaks anywhere in long
	 * words, grows in height and keeps at least the touch height of its size.
	 */
	interface Props {
		items: { key: string; label: string }[];
		onpick: (key: string) => void;
		disabled?: boolean;
		size?: 'sm' | 'default';
		label?: string;
		testid?: string;
		class?: string;
	}
	let { items, onpick, disabled = false, size = 'default', label, testid, class: className = '' }: Props = $props();
	const fit = $derived(
		size === 'sm' ? 'h-auto min-h-8 max-w-full min-w-0 py-1 text-left [overflow-wrap:anywhere] whitespace-normal' : 'h-auto min-h-9 max-w-full min-w-0 py-1.5 text-left [overflow-wrap:anywhere] whitespace-normal'
	);
</script>

<div class={['flex min-w-0 flex-wrap gap-1.5', className]} role="group" aria-label={label}>
	{#each items as item (item.key)}
		<Button {size} variant="outline" class={fit} {disabled} data-testid={testid} onclick={() => onpick(item.key)}>{item.label}</Button>
	{/each}
</div>
