<script lang="ts">
	import { relativeWhen } from '#lib/cardRef.js';
	import { formatTimestamp } from '#lib/planning.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';

	/** Shared audit timestamp. Invalid or absent API fields produce no misleading label or time element. */
	let { value, label, testid }: { value?: string | null; label?: MessageKey; testid?: string } = $props();
	const title = $derived(formatTimestamp(value));
	const datetime = $derived(title && value ? new Date(value).toISOString() : '');
</script>

{#if datetime}
	{#if label}{t(label)}{' '}{/if}<time {datetime} {title} data-testid={testid}>{relativeWhen(value)}</time>
{/if}
