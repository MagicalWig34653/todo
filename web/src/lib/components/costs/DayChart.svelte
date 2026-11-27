<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { PART_KEYS, formatDay, formatUSD, labelIndices, stackedBars, type PartKey, type UsageSummary } from '#lib/usage.js';

	let { summary }: { summary: UsageSummary } = $props();
	const chart = $derived(stackedBars(summary.series));
	const labels = $derived(new Set(labelIndices(chart.bars.length)));
	/** Day under the pointer (or tapped); without one the newest day is read out. */
	let picked = $state<string | null>(null);
	const shown = $derived(summary.series.find((d) => d.day === picked) ?? summary.series.at(-1));

	const FILL: Record<PartKey, string> = {
		input: 'bg-(--cost-input)',
		cacheWrite: 'bg-(--cost-cache-write)',
		cacheRead: 'bg-(--cost-cache-read)',
		output: 'bg-(--cost-output)'
	};
</script>

<section class="bg-card min-w-0 rounded-xl border p-4" aria-labelledby="costs-days-title" data-testid="costs-day-chart">
	<h3 id="costs-days-title" class="text-base font-semibold">{t('usage.days.title')}</h3>
	<ul class="text-muted-foreground mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[13px]" data-testid="costs-legend">
		{#each PART_KEYS as key (key)}
			<li class="flex items-center gap-1.5"><span class={['size-2.5 rounded-sm', FILL[key]]} aria-hidden="true"></span>{t(`usage.part.${key}`)}</li>
		{/each}
	</ul>
	<p class="sr-only">
		{t('usage.days.summary', { from: formatDay(summary.from), until: formatDay(summary.until), total: formatUSD(summary.totalCostUSD) })}
	</p>

	<div class="mt-3" aria-hidden="true">
		<p class="text-muted-foreground text-xs" data-tabular>{formatUSD(chart.max)}</p>
		<div class={['border-border flex h-44 items-stretch border-y', chart.bars.length > 10 ? 'gap-0.5' : 'gap-2']}>
			{#each chart.bars as bar (bar.day)}
				<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions (pointer extra; the table below is the accessible form) -->
				<div
					class={['flex min-w-0 flex-1 flex-col items-center justify-end rounded-sm', shown?.day === bar.day && 'bg-muted']}
					data-testid="costs-day-bar"
					onpointerenter={() => (picked = bar.day)}
					onclick={() => (picked = bar.day)}
				>
					<div class="flex w-full max-w-12 flex-col-reverse gap-0.5 overflow-hidden rounded-t" style:height="{bar.height}%">
						{#each bar.parts as part (part.key)}
							<div class={['min-h-0', FILL[part.key]]} style:flex="{part.share} 1 0%"></div>
						{/each}
					</div>
				</div>
			{/each}
		</div>
		<div class={['text-muted-foreground mt-1 flex h-4 text-xs', chart.bars.length > 10 ? 'gap-0.5' : 'gap-2']} data-tabular>
			{#each chart.bars as bar, i (bar.day)}
				<span class="relative min-w-0 flex-1">
					{#if labels.has(i)}
						<span
							class={['absolute whitespace-nowrap', chart.bars.length <= 7 ? 'left-1/2 -translate-x-1/2 max-sm:text-[11px]' : i === 0 ? 'left-0' : i === chart.bars.length - 1 ? 'right-0' : 'left-1/2 -translate-x-1/2']}
							>{bar.label}</span
						>
					{/if}
				</span>
			{/each}
		</div>
	</div>

	{#if shown}
		<p class="mt-3 flex flex-wrap gap-x-3 gap-y-0.5 text-[13px]" data-testid="costs-day-readout" data-tabular>
			<strong>{formatDay(shown.day)}: {formatUSD(shown.costUSD)}</strong>
			{#each PART_KEYS as key (key)}
				<span class="text-muted-foreground">{t(`usage.part.${key}`)} {formatUSD(shown.parts[key])}</span>
			{/each}
		</p>
	{/if}

	<details class="mt-3" data-testid="costs-day-table">
		<summary class="text-ui-accent-ink cursor-pointer py-1 text-sm font-medium">{t('usage.days.table')}</summary>
		<!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard users must be able to scroll a wide table) -->
		<div class="mt-1 overflow-x-auto" tabindex="0" role="region" aria-label={t('usage.days.title')}>
			<table class="w-full text-right text-[13px] whitespace-nowrap" data-tabular>
				<thead class="text-muted-foreground">
					<tr class="border-b">
						<th scope="col" class="py-1 pr-3 text-left font-medium">{t('usage.days.day')}</th>
						{#each PART_KEYS as key (key)}<th scope="col" class="px-2 py-1 font-medium">{t(`usage.part.${key}`)}</th>{/each}
						<th scope="col" class="py-1 pl-2 font-medium">{t('usage.days.sum')}</th>
					</tr>
				</thead>
				<tbody>
					{#each summary.series as day (day.day)}
						<tr class="border-b last:border-0">
							<th scope="row" class="py-1 pr-3 text-left font-normal">{formatDay(day.day)}</th>
							{#each PART_KEYS as key (key)}<td class="px-2 py-1">{formatUSD(day.parts[key])}</td>{/each}
							<td class="py-1 pl-2 font-medium">{formatUSD(day.costUSD)}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	</details>
</section>
