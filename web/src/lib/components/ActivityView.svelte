<script lang="ts">
	import { onDestroy, onMount, tick, untrack } from 'svelte';
	import { api, type FeedItem } from '#lib/api.js';
	import { de } from '#lib/i18n/de.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { personName } from '#lib/people.js';
	import { newerThan, startLiveRefresh } from '#lib/liveRefresh.js';
	import { formatWhen } from '#lib/planning.js';
	import { buildTree, flatten } from '#lib/projectTree.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { auth } from '#lib/auth.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import Activity from '@lucide/svelte/icons/activity';

	let { onopen }: { onopen?: (projectID: string) => void } = $props();

	let items = $state<FeedItem[]>([]);
	let next = $state<string | null>(null);
	let projectID = $state('');
	let loading = $state(false);
	let loadedOnce = $state(false);
	let sentinel = $state<HTMLElement | null>(null);
	/** New entries found while the reader is scrolled down; shown on request so the list does not jump. */
	let pendingNew = $state<FeedItem[]>([]);
	/** Guards against out-of-order responses after a filter change. */
	let generation = 0;

	const projects = $derived(flatten(buildTree(workspace.projects)));

	/** Appends the next page (or replaces the list when `reset`); safe against double triggers. */
	async function load(reset = false) {
		if (loading && !reset) return;
		const my = reset ? ++generation : generation;
		if (!reset && next === null && loadedOnce) return;
		loading = true;
		try {
			const page = await api.feed({ projectID: projectID || undefined, before: reset ? null : next, limit: 30 });
			if (my !== generation) return;
			items = reset ? page.items : [...items, ...page.items];
			next = page.nextCursor ?? null;
			loadedOnce = true;
		} finally {
			if (my === generation) loading = false;
		}
	}

	/** Silent refetch of the newest page (focus, visibility, 30 s). Near the top it merges at once, further down it only counts. */
	async function refresh() {
		if (loading || !loadedOnce) return;
		const my = generation;
		const page = await api.feed({ projectID: projectID || undefined, before: null, limit: 30 });
		if (my !== generation || loading) return;
		const { fresh, gap } = newerThan([...pendingNew, ...items], page.items);
		if (gap) {
			items = page.items;
			next = page.nextCursor ?? null;
			pendingNew = [];
		} else if (fresh.length > 0) {
			const combined = [...fresh, ...pendingNew];
			if (window.scrollY > 120) pendingNew = combined;
			else {
				items = [...combined, ...items];
				pendingNew = [];
			}
		}
	}
	function showPending() {
		items = [...pendingNew, ...items];
		pendingNew = [];
		window.scrollTo({ top: 0 });
	}
	onMount(() => startLiveRefresh(refresh));

	$effect(() => {
		void projectID;
		pendingNew = [];
		items = [];
		next = null;
		loadedOnce = false;
		attempt(() => untrack(() => load(true)));
	});

	// Infinite scroll: load the next page when the end marker comes near the viewport.
	let observer: IntersectionObserver | null = null;
	$effect(() => {
		observer?.disconnect();
		observer = null;
		if (!sentinel || typeof IntersectionObserver === 'undefined') return;
		observer = new IntersectionObserver(
			(entries) => {
				if (entries.some((e) => e.isIntersecting) && next && !loading) attempt(() => load());
			},
			{ rootMargin: '300px' }
		);
		observer.observe(sentinel);
	});
	onDestroy(() => observer?.disconnect());
	// A short first page leaves the end marker in view without a crossing event: keep filling until the viewport is full.
	$effect(() => {
		void items.length;
		void next;
		if (!next || !sentinel) return;
		tick().then(() => {
			if (next && !loading && sentinel && sentinel.getBoundingClientRect().top < window.innerHeight + 300) attempt(() => load());
		});
	});

	function label(a: FeedItem): string {
		const key = a.source === 'project' ? `activity.project.${a.kind}` : `activity.kind.${a.kind}`;
		return key in de ? t(key as MessageKey) : t('activity.unknownKind', { kind: a.kind });
	}
	function actor(a: FeedItem): string {
		if (a.actorType === 'Person') return a.actorID === auth.user?.id ? t('activity.you') : personName(a.actorName, t('activity.actor.Person'));
		return t(`activity.actor.${a.actorType}` as MessageKey);
	}
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('nav.activity')} description={t('activity.hint')} testid="view-heading">
		{#snippet actions()}
			<label class="flex items-center gap-2 text-sm">
				<span class="text-muted-foreground">{t('activity.filter')}</span>
				<Select bind:value={projectID} class="w-56 max-w-[60vw]" data-testid="activity-filter">
					<option value="">{t('activity.allProjects')}</option>
					{#each projects as p (p.project.id)}<option value={p.project.id}>{'  '.repeat(p.depth)}{p.project.name}</option>{/each}
				</Select>
			</label>
		{/snippet}
	</PageHeader>

	{#if loadedOnce && items.length === 0}
		<EmptyState title={t('activity.title')} icon={Activity}><p>{t('activity.empty')}</p></EmptyState>
	{/if}

	{#if pendingNew.length > 0}
		<div class="sticky top-2 z-10 flex justify-center">
			<Button size="sm" data-testid="feed-new" onclick={showPending}>{t('activity.newEntries', { count: pendingNew.length })}</Button>
		</div>
	{/if}

	<ol class="flex flex-col divide-y rounded-xl border" data-testid="activity-feed">
		{#each items as a (a.id)}
			<li class="flex flex-col gap-0.5 px-3 py-2.5 text-sm" data-testid="feed-item" data-kind={a.kind} data-source={a.source}>
				<div class="flex flex-wrap items-baseline gap-x-1.5">
					<span class="font-medium" data-testid="feed-actor">{actor(a)}</span>
					<span data-testid="feed-label">{label(a)}</span>
				</div>
				<div class="text-muted-foreground flex flex-wrap items-center gap-x-2 text-xs">
					{#if a.taskTitle}<span class="text-foreground/80" data-testid="feed-task">{a.taskTitle}</span>{/if}
					<button type="button" class="hover:text-foreground underline-offset-2 hover:underline" data-testid="feed-project" onclick={() => onopen?.(a.projectID)}>
						{t('activity.inProject', { name: a.projectName })}
					</button>
					{#if a.createdAt}<span class="ml-auto" data-tabular>{formatWhen(a.createdAt)}</span>{/if}
				</div>
			</li>
		{/each}
	</ol>

	<div bind:this={sentinel} class="flex min-h-8 items-center justify-center">
		{#if loading}
			<span class="text-muted-foreground text-xs">{t('activity.loading')}</span>
		{:else if next}
			<Button size="sm" variant="ghost" data-testid="feed-more" onclick={() => attempt(() => load())}>{t('activity.more')}</Button>
		{:else if loadedOnce && items.length > 0}
			<span class="text-muted-foreground text-xs" data-testid="feed-end">{t('activity.end')}</span>
		{/if}
	</div>
</section>
