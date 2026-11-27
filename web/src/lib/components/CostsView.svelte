<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { localDate, pageState, partialHint, type UsageDays, type UsageSettings, type UsageSummary } from '#lib/usage.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import Verdict from './costs/Verdict.svelte';
	import Tiles from './costs/Tiles.svelte';
	import DayChart from './costs/DayChart.svelte';
	import Breakdown from './costs/Breakdown.svelte';
	import Settings from './costs/Settings.svelte';
	import ChartColumn from '@lucide/svelte/icons/chart-column';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';

	const RANGES: UsageDays[] = [1, 7, 30];

	let days = $state<UsageDays>(7);
	let data = $state<UsageSummary | null>(null);
	let loading = $state(true);
	let settings = $state<UsageSettings | null>(null);
	let settingsFailed = $state(false);
	let settingsPanel = $state<ReturnType<typeof Settings>>();
	/** Only the answer to the latest request counts (quick range switches). */
	let sequence = 0;

	const status = $derived(data ? pageState(data) : null);
	const partial = $derived(data ? partialHint(data) : null);

	async function load() {
		const mine = ++sequence;
		loading = true;
		try {
			const next = await api.usageSummary(days, localDate(new Date()));
			if (mine === sequence) data = next;
		} catch {
			// Never show the numbers of another range under the selected button.
			if (mine === sequence) data = null;
		} finally {
			if (mine === sequence) loading = false;
		}
	}
	async function loadSettings() {
		settingsFailed = false;
		try {
			settings = await api.usageSettings();
		} catch {
			settingsFailed = true;
		}
	}
	function select(range: UsageDays) {
		if (range === days) return;
		days = range;
		void load();
	}
	function saved(next: UsageSettings) {
		settings = next;
		void load();
	}
	async function addPrice(model: string) {
		await tick();
		settingsPanel?.addModel(model);
	}

	onMount(() => {
		void load();
		void loadSettings();
	});
</script>

<div class="min-w-0" data-testid="costs-view">
	<PageHeader title={t('usage.title')} description={t('usage.hint')} testid="view-heading">
		{#snippet actions()}
			<div class="bg-muted inline-flex rounded-lg p-0.5" role="group" aria-label={t('usage.range')} data-testid="costs-range">
				{#each RANGES as range (range)}
					<button
						type="button"
						class="text-muted-foreground aria-pressed:bg-background aria-pressed:text-foreground aria-pressed:shadow-xs max-menu:min-h-10 min-h-8 min-w-14 rounded-md px-3 text-sm font-medium"
						aria-pressed={days === range}
						onclick={() => select(range)}>{t(`usage.range.${range}`)}</button
					>
				{/each}
			</div>
		{/snippet}
	</PageHeader>

	<div class="flex flex-col gap-6">
		{#if !data}
			{#if loading}
				<p class="text-muted-foreground text-sm" role="status" data-testid="costs-loading">{t('usage.loading')}</p>
			{:else}
				<div role="alert" class="flex flex-col items-start gap-2" data-testid="costs-error">
					<p class="text-sm">{t('usage.error')}</p>
					<Button variant="outline" class="max-menu:h-10" onclick={() => load()}>{t('usage.retry')}</Button>
				</div>
			{/if}
		{:else}
			<div class={['flex flex-col gap-6 transition-opacity', loading && 'opacity-60']} aria-busy={loading}>
				{#if status === 'setup'}
					<div data-testid="costs-setup">
						<EmptyState title={t('usage.setup.title')} icon={ChartColumn}><p class="max-w-md">{t('usage.setup.hint')}</p></EmptyState>
					</div>
				{:else if status === 'quiet'}
					<div data-testid="costs-quiet">
						<EmptyState title={t('usage.quiet.title')} icon={ChartColumn}><p class="max-w-md">{t('usage.quiet.hint')}</p></EmptyState>
					</div>
				{:else}
					<div class="flex flex-col gap-3">
						{#if partial}<p class="text-muted-foreground text-[13px]" data-testid="costs-partial">{partial}</p>{/if}
						<Verdict summary={data} />
						{#if data.unpricedModels.length > 0}
							<div class="border-warning/40 bg-warning-soft flex flex-col gap-2 rounded-xl border px-4 py-3 text-sm" data-testid="costs-unpriced">
								<p class="flex items-start gap-2 font-medium">
									<TriangleAlert class="text-warning mt-0.5 size-4 shrink-0" aria-hidden="true" />{t('usage.unpriced.title')}
								</p>
								<ul class="flex flex-wrap gap-2">
									{#each data.unpricedModels as model (model)}
										<li class="max-w-full">
											<Button variant="outline" class="max-menu:h-10 h-auto min-h-8 max-w-full py-1 text-left whitespace-normal [overflow-wrap:anywhere]" onclick={() => addPrice(model)}>
												{t('usage.unpriced.add', { model })}
											</Button>
										</li>
									{/each}
								</ul>
							</div>
						{/if}
					</div>
					<Tiles metrics={data.metrics} thresholds={settings?.thresholds ?? {}} />
					<DayChart summary={data} />
					<Breakdown summary={data} />
				{/if}
			</div>
		{/if}
		<!-- Outside the summary branch: a failed load must not discard an unsaved draft. -->
		<Settings bind:this={settingsPanel} {settings} failed={settingsFailed} onretry={loadSettings} onsaved={saved} />
	</div>
</div>
