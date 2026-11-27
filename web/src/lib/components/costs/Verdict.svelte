<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { costTrend, formatUSD, verdictText, type UsageSummary } from '#lib/usage.js';
	import Check from '@lucide/svelte/icons/check';
	import X from '@lucide/svelte/icons/x';
	import Minus from '@lucide/svelte/icons/minus';

	let { summary }: { summary: UsageSummary } = $props();
	const verdict = $derived(verdictText(summary));
	const range = $derived(summary.days === 1 || summary.days === 30 ? summary.days : 7);

	/** Top to bottom like a real traffic light: position and icon say the same as the colour. */
	const LAMPS = [
		{ rating: 'bad', on: 'bg-destructive', icon: X },
		{ rating: 'medium', on: 'bg-warning', icon: Minus },
		{ rating: 'good', on: 'bg-success', icon: Check }
	] as const;
</script>

<section class="bg-card shadow-card flex items-start gap-4 rounded-xl border p-4 sm:gap-6 sm:p-5" aria-label={t('usage.verdict.section')} data-testid="costs-verdict" data-rating={verdict.rating}>
	<div class="bg-muted flex shrink-0 flex-col gap-1.5 rounded-full p-1.5" aria-hidden="true">
		{#each LAMPS as lamp (lamp.rating)}
			{@const Icon = lamp.icon}
			<span class={['text-background flex size-8 items-center justify-center rounded-full sm:size-10', lamp.rating === verdict.rating ? lamp.on : 'border-foreground/15 border-2']}>
				{#if lamp.rating === verdict.rating}<Icon class="size-5 sm:size-6" />{/if}
			</span>
		{/each}
	</div>
	<div class="min-w-0 flex-1">
		<p class="text-lg leading-snug font-semibold text-balance [overflow-wrap:anywhere] sm:text-xl" data-testid="costs-verdict-sentence">{verdict.sentence}</p>
		<p class="text-muted-foreground mt-3 text-[13px]">{t(`usage.total.${range}`)}</p>
		<p class="text-3xl leading-tight font-semibold tracking-tight" data-testid="costs-total">{formatUSD(summary.totalCostUSD)}</p>
		<p class="text-muted-foreground text-sm" data-testid="costs-trend">{costTrend(summary)}</p>
	</div>
</section>
