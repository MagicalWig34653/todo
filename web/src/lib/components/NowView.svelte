<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import { api, type OverviewNow, type OverviewProject } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { liveRefresh, startLiveRefresh } from '#lib/liveRefresh.js';
	import { uniqueKeys } from '#lib/keys.js';
	import { allowRefetch, blockOf, groupProjects, isExpanded, loadExpanded, saveExpanded, serverClock, showEmptyPage, type ExpandedMap } from '#lib/now.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import NowBlock from './now/NowBlock.svelte';
	import NowProject from './now/NowProject.svelte';
	import Radio from '@lucide/svelte/icons/radio';

	let data = $state<OverviewNow | null>(null);
	let failed = $state(false);
	let loading = $state(true);
	let live = $state(false);
	let expanded = $state<ExpandedMap>(loadExpanded());
	/** Re-evaluates relative ages and the quiet boundary without refetching (every 30 s). */
	let now = $state(new Date());
	let lastFetchAt: number | null = null;

	const groups = $derived(data ? groupProjects(data.projects ?? [], now) : { active: [], quiet: [] });
	/** Relative texts follow the server clock (kept running between fetches), not the device clock. */
	const ref = $derived(data && lastFetchAt !== null ? serverClock(data.serverTime, lastFetchAt, now.getTime()) : now);
	/** Block "Jetzt" (field `now`); null for an old server, then only the project sections are shown. */
	const block = $derived(blockOf(data, ref));
	const asOf = $derived(
		data
			? new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(data.serverTime))
			: ''
	);

	async function load() {
		try {
			const next = await api.overviewNow();
			lastFetchAt = Date.now();
			data = next;
			failed = false;
			now = new Date();
			live = liveRefresh.mode === 'live';
		} catch {
			failed = true;
		} finally {
			loading = false;
		}
	}
	/** Hints from the central service; in polling mode (old server) at most one refetch per 30 s. */
	async function refresh() {
		if (!allowRefetch(lastFetchAt, Date.now(), liveRefresh.mode === 'poll' ? 'poll' : 'live')) return;
		await load();
	}

	let ticker: ReturnType<typeof setInterval> | undefined;
	onMount(() => {
		void load();
		const unsubscribe = startLiveRefresh(refresh);
		ticker = setInterval(() => (now = new Date()), 30_000);
		return unsubscribe;
	});
	onDestroy(() => clearInterval(ticker));

	/** Only real user clicks (mouse, Enter, Space) are stored; the native toggle is replaced so defaults are never written by render. */
	function toggle(id: string, quiet: boolean, e: Event) {
		e.preventDefault();
		expanded = { ...expanded, [id]: !isExpanded(expanded, id, quiet, !!block) };
		saveExpanded(expanded);
	}
</script>

{#snippet projectRows(list: OverviewProject[], quiet: boolean)}
	{#each uniqueKeys(list, (p) => p.projectID) as { item: p, key } (key)}
		<NowProject project={p} {quiet} {now} open={isExpanded(expanded, p.projectID, quiet, !!block)} ontoggle={(e) => toggle(p.projectID, quiet, e)} />
	{/each}
{/snippet}

<div class="@container" data-testid="now-view">
	<PageHeader title={t('now.title')} description={t('now.hint')} testid="view-heading">
		{#snippet actions()}
			{#if data}
				<span class="inline-flex items-center gap-1.5" role="status" aria-live="polite">
					<Badge variant="success" data-testid="now-live"><Radio class="size-3" aria-hidden="true" />{live ? t('now.live') : t('now.liveAuto')}</Badge>
					<span class="text-muted-foreground text-[13px]" data-testid="now-asof">{t('now.asOf', { time: asOf })}</span>
				</span>
			{/if}
		{/snippet}
	</PageHeader>

	{#if loading && !data}
		<p class="text-muted-foreground text-sm" role="status" data-testid="now-loading">{t('now.loading')}</p>
	{:else if !data}
		<div role="alert" class="flex flex-col items-start gap-2" data-testid="now-error">
			<p class="text-sm">{t('now.error')}</p>
			<Button variant="outline" class="max-menu:h-10" onclick={() => load()}>{t('now.retry')}</Button>
		</div>
	{:else}
		{#if failed}<p class="text-warning mb-3 text-sm" role="alert" data-testid="now-stale">{t('now.errorStale')}</p>{/if}
		{#if showEmptyPage(data, block)}
			<div data-testid="now-empty">
				<EmptyState title={t('now.empty')} icon={Radio}><p>{t('now.emptyHint')}</p></EmptyState>
			</div>
		{:else}
			{#if block}<NowBlock {block} {ref} {now} />{/if}
			{#if groups.active.length + groups.quiet.length > 0}
				<h3 class={block ? 'mb-2 text-base font-semibold' : 'sr-only'}>{t('now.block.projects')}</h3>
			{/if}
			<div class="flex flex-col gap-2" data-testid="now-active">{@render projectRows(groups.active, false)}</div>
			{#if groups.quiet.length > 0}
				<h3 class="text-muted-foreground mt-6 mb-2 text-[13px]" data-testid="now-quiet-heading">
					{groups.quiet.length === 1 ? t('now.quietOne') : t('now.quiet', { count: groups.quiet.length })}
				</h3>
				<div class="flex flex-col gap-2" data-testid="now-quiet">{@render projectRows(groups.quiet, true)}</div>
			{/if}
		{/if}
	{/if}
</div>
