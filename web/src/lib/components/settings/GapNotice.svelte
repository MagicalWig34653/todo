<script lang="ts">
	import type { Snippet } from 'svelte';
	import { t } from '#lib/i18n/index.js';

	/** Friendly placeholder for functions that are not available yet. */
	let { children, testid = 'backend-gap' }: { children?: Snippet; testid?: string } = $props();
</script>

<div class="bg-muted/60 flex flex-col gap-1 rounded-xl border border-dashed px-4 py-3 text-sm" data-testid={testid}>
	<strong class="font-semibold">{t('settings.gap.title')}</strong>
	<p class="text-muted-foreground">{@render children?.()}</p>
	<p class="text-muted-foreground text-xs">{t('settings.gap.text')}</p>
</div>
