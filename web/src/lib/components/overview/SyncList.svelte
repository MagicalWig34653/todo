<script lang="ts">
	import type { ProjectSyncEntry } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { filterSync, sortSync, syncCounts, type SyncFilter } from '#lib/syncState.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import SyncChip from './SyncChip.svelte';
	import SyncDetail from './SyncDetail.svelte';

	/** Account overview: which projects are out of sync with their repository, filterable, with details on demand. */
	let { entries, onchanged }: { entries: ProjectSyncEntry[]; onchanged?: () => unknown } = $props();

	const FILTERS: SyncFilter[] = ['attention', 'stale', 'never', 'fresh', 'all'];
	let filter = $state<SyncFilter>('attention');
	let openID = $state<string | null>(null);

	const counts = $derived(syncCounts(entries));
	const rows = $derived(sortSync(filterSync(entries, filter)));
</script>

<section class="flex max-w-3xl flex-col gap-2" data-testid="sync-list" aria-label={t('sync.listTitle')}>
	<div class="flex flex-wrap items-center justify-between gap-2">
		<h3 class="text-sm font-semibold">{t('sync.listTitle')}</h3>
		<label class="flex items-center gap-2 text-xs">
			<span class="text-muted-foreground">{t('sync.filter')}</span>
			<Select bind:value={filter} class="w-52 max-w-[55vw]" data-testid="sync-filter">
				{#each FILTERS as f (f)}
					<option value={f}>{t(`sync.filter.${f}` as MessageKey)}</option>
				{/each}
			</Select>
		</label>
	</div>
	<p class="text-muted-foreground text-xs" data-testid="sync-counts">
		{t('sync.fresh')}: {counts.fresh} · {t('sync.filter.stale')}: {counts.stale} · {t('sync.never')}: {counts.never}
	</p>
	{#if rows.length === 0}
		<p class="text-muted-foreground text-xs">{t('sync.empty')}</p>
	{:else}
		<ul class="flex flex-col divide-y rounded-xl border">
			{#each rows as e (e.projectID)}
				<li class="flex flex-col gap-2 p-2.5" data-testid="sync-row" data-state={e.sync.state}>
					<div class="flex flex-wrap items-center gap-2">
						<span class="min-w-0 flex-1 truncate text-sm font-medium" data-testid="sync-row-name">{e.name}</span>
						<SyncChip sync={e.sync} />
						<button
							type="button"
							class="text-ui-accent-ink min-h-9 text-xs underline underline-offset-2"
							aria-expanded={openID === e.projectID}
							data-testid="sync-row-toggle"
							onclick={() => (openID = openID === e.projectID ? null : e.projectID)}
						>
							{openID === e.projectID ? t('sync.hideDetails') : t('sync.details')}
						</button>
					</div>
					{#if openID === e.projectID}<SyncDetail projectID={e.projectID} {onchanged} />{/if}
				</li>
			{/each}
		</ul>
	{/if}
</section>
