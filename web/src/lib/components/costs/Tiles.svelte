<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { metricTile, type Metric, type Rating, type Thresholds } from '#lib/usage.js';
	import { Badge, type BadgeVariant } from '#lib/components/ui/badge/index.js';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import OctagonX from '@lucide/svelte/icons/octagon-x';
	import Info from '@lucide/svelte/icons/info';
	import CircleDashed from '@lucide/svelte/icons/circle-dashed';

	let { metrics, thresholds }: { metrics: Metric[]; thresholds: Thresholds } = $props();

	const LOOK: Record<Rating, { variant: BadgeVariant; icon: typeof Info }> = {
		good: { variant: 'success', icon: CircleCheck },
		medium: { variant: 'warning', icon: TriangleAlert },
		bad: { variant: 'destructive', icon: OctagonX },
		info: { variant: 'outline', icon: Info },
		unknown: { variant: 'default', icon: CircleDashed }
	};
</script>

<section aria-labelledby="costs-metrics-title">
	<h3 id="costs-metrics-title" class="mb-2 text-base font-semibold">{t('usage.metrics.title')}</h3>
	<ul class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
		{#each metrics as metric (metric.id)}
			{@const tile = metricTile(metric, thresholds)}
			{@const Icon = LOOK[tile.rating].icon}
			<li class="bg-card flex min-w-0 flex-col gap-1.5 rounded-xl border p-3.5" data-testid="costs-tile" data-metric={tile.id} data-rating={tile.rating}>
				<h4 class="text-muted-foreground text-[13px] font-medium">{tile.label}</h4>
				<div class="flex flex-wrap items-center justify-between gap-2">
					<span class="text-2xl leading-tight font-semibold">{tile.value}</span>
					<Badge variant={LOOK[tile.rating].variant} data-testid="costs-rating"><Icon aria-hidden="true" />{tile.ratingLabel}</Badge>
				</div>
				<p class="text-muted-foreground text-[13px] leading-snug">{tile.why}</p>
			</li>
		{/each}
	</ul>
</section>
