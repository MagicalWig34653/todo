<script lang="ts">
	import { splitLead } from '#lib/explainer.js';
	import { t } from '#lib/i18n/index.js';

	/** Explanation of a page or section: the first sentence, the rest behind "Mehr erfahren" (UX concept §1). */
	let { text, class: className = '' }: { text: string; class?: string } = $props();
	const parts = $derived(splitLead(text));
	let open = $state(false);
</script>

<p class={['text-muted-foreground text-sm', className]} data-testid="explainer">
	{parts.lead}{#if parts.rest}{#if open}{' '}{parts.rest}{/if}{' '}<button
			type="button"
			class="text-ui-accent-ink rounded-sm font-medium whitespace-nowrap underline-offset-2 hover:underline focus-visible:ring-2 focus-visible:ring-ring/60 focus-visible:outline-none"
			aria-expanded={open}
			onclick={() => (open = !open)}>{open ? t('explainer.less') : t('explainer.more')}</button
		>{/if}
</p>
