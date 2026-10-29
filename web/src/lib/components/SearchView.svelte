<script lang="ts">
	import { api, type Criteria, type Label, type Project, type SavedFilter, type SearchHit, type TaskStatus } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { STATUSES, collectAll } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import Panel from './app/Panel.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import SearchIcon from '@lucide/svelte/icons/search';
	import X from '@lucide/svelte/icons/x';

	let {
		projects,
		onopen,
		initial = {}
	}: { projects: Project[]; onopen: (projectID: string) => void; initial?: { labelID?: string; filterID?: string } } = $props();

	let q = $state('');
	let projectID = $state('');
	let labelID = $state('');
	let status = $state('');
	let hits = $state<SearchHit[]>([]);
	let next = $state<string | null>(null);
	let searched = $state(false);
	let labels = $state<Label[]>([]);
	let filters = $state<SavedFilter[]>([]);
	let activeFilter = $state<SavedFilter | null>(null);
	let filterName = $state('');
	let labelName = $state('');
	let deletingLabelID = $state<string | null>(null);
	let renamingID = $state<string | null>(null);
	let renameDraft = $state('');

	const criteria = $derived<Criteria>({
		...(q.trim() ? { q: q.trim() } : {}),
		...(projectID ? { projectID } : {}),
		...(labelID ? { labelID } : {}),
		...(status ? { status: status as TaskStatus } : {})
	});
	const hasCriteria = $derived(Object.keys(criteria).length > 0);

	async function loadMeta() {
		[labels, filters] = await Promise.all([collectAll((c) => api.listLabels(c)), collectAll((c) => api.listFilters(c))]);
	}
	$effect(() => {
		attempt(async () => {
			await loadMeta();
			// Opened from "Filter und Etiketten": run the chosen filter or label right away.
			const f = initial.filterID ? filters.find((x) => x.id === initial.filterID) : undefined;
			if (f) await applyFilter(f);
			else if (initial.labelID) {
				labelID = initial.labelID;
				await run();
			}
		});
	});

	async function run(more = false) {
		const page = activeFilter
			? await api.filterResults(activeFilter.id, more ? next : null)
			: await api.search(criteria, more ? next : null);
		hits = more ? [...hits, ...page.items] : page.items;
		next = page.nextCursor ?? null;
		searched = true;
	}
	async function submit(e: Event) {
		e.preventDefault();
		activeFilter = null;
		await attempt(() => run());
	}
	async function applyFilter(f: SavedFilter) {
		activeFilter = f;
		q = f.criteria.q ?? '';
		projectID = f.criteria.projectID ?? '';
		labelID = f.criteria.labelID ?? '';
		status = f.criteria.status ?? '';
		await attempt(() => run());
	}
	async function saveFilter(e: Event) {
		e.preventDefault();
		const name = filterName.trim();
		if (!name || !hasCriteria) return;
		if (await attempt(async () => (filters = [...filters, await api.createFilter(name, criteria)]))) filterName = '';
	}
	const deleteFilter = (f: SavedFilter) =>
		attempt(async () => {
			await api.deleteFilter(f.id);
			filters = filters.filter((x) => x.id !== f.id);
			if (activeFilter?.id === f.id) activeFilter = null;
		});
	const replaceFilter = (u: SavedFilter) => {
		filters = filters.map((x) => (x.id === u.id ? u : x));
		if (activeFilter?.id === u.id) activeFilter = u;
	};
	async function renameFilter(f: SavedFilter) {
		const name = renameDraft.trim();
		if (!name) return;
		if (await attempt(async () => replaceFilter(await api.updateFilter(f, { name })), loadMeta)) renamingID = null;
	}
	/** Overwrites the stored criteria with the ones currently in the form. */
	const overwriteFilter = (f: SavedFilter) =>
		attempt(async () => replaceFilter(await api.updateFilter(f, { criteria })), loadMeta);
	async function addLabel(e: Event) {
		e.preventDefault();
		const name = labelName.trim();
		if (!name) return;
		if (await attempt(async () => (labels = [...labels, await api.createLabel(name)]))) labelName = '';
	}
	const deleteLabel = (l: Label) =>
		attempt(async () => {
			await api.deleteLabel(l.id);
			labels = labels.filter((x) => x.id !== l.id);
			deletingLabelID = null;
		}, loadMeta);
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('search.title')} testid="view-heading" />

	<form class="flex flex-col gap-3" onsubmit={submit}>
		<div class="flex gap-2">
			<Input class="h-10" bind:value={q} placeholder={t('search.placeholder')} aria-label={t('search.placeholder')} />
			<Button type="submit" class="h-10"><SearchIcon aria-hidden="true" />{t('search.submit')}</Button>
		</div>
		<div class="flex flex-col gap-2 text-sm sm:flex-row sm:flex-wrap">
			<Select class="w-full sm:w-auto sm:min-w-44" aria-label={t('search.project')} bind:value={projectID}>
				<option value="">{t('search.anyProject')}</option>
				{#each projects as p (p.id)}<option value={p.id}>{p.name}</option>{/each}
			</Select>
			<Select class="w-full sm:w-auto sm:min-w-44" aria-label={t('search.label')} bind:value={labelID}>
				<option value="">{t('search.anyLabel')}</option>
				{#each labels as l (l.id)}<option value={l.id}>{l.name}</option>{/each}
			</Select>
			<Select class="w-full sm:w-auto sm:min-w-44" aria-label={t('search.status')} bind:value={status}>
				<option value="">{t('search.anyStatus')}</option>
				{#each STATUSES as s (s)}<option value={s}>{t(`status.${s}` as MessageKey)}</option>{/each}
			</Select>
		</div>
	</form>

	{#if activeFilter}<p class="text-muted-foreground text-sm">{t('search.activeFilter', { name: activeFilter.name })}</p>{/if}
	{#if searched && hits.length === 0}<EmptyState title={t('search.noResults')} icon={SearchIcon} />{/if}
	<ul class="flex flex-col gap-2">
		{#each hits as h (h.kind + h.id)}
			<li class="bg-card flex flex-wrap items-center gap-2 rounded-xl border p-3 text-sm shadow-card" data-testid="search-hit">
				<Badge variant={h.kind === 'task' ? 'accent' : 'default'}>{t(`search.hit.${h.kind}` as MessageKey)}</Badge>
				<button class="min-w-0 flex-1 text-left font-medium hover:underline" onclick={() => onopen(h.project.id)}>
					{h.kind === 'task' ? h.task?.title : h.project.name}
				</button>
				{#if h.kind === 'task'}<span class="text-muted-foreground text-xs">{h.project.name}</span>{/if}
			</li>
		{/each}
	</ul>
	{#if next}<div><Button variant="outline" size="sm" onclick={() => attempt(() => run(true))}>{t('search.more')}</Button></div>{/if}

	{#if hasCriteria && !activeFilter}
		<form class="flex gap-2" onsubmit={saveFilter}>
			<Input bind:value={filterName} placeholder={t('search.filterName')} aria-label={t('search.filterName')} />
			<Button type="submit" variant="outline">{t('search.saveFilter')}</Button>
		</form>
	{/if}

	<Panel title={t('search.filters')}>
		{#if filters.length === 0}<p class="text-muted-foreground text-sm">{t('search.filters.empty')}</p>{/if}
		<ul class="flex flex-wrap gap-1.5">
			{#each filters as f (f.id)}
				<li class="bg-secondary flex flex-wrap items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs" data-testid="saved-filter">
					{#if renamingID === f.id}
						<Input class="h-7 w-40 text-xs" bind:value={renameDraft} aria-label={t('search.renameFilter', { name: f.name })} />
						<button onclick={() => renameFilter(f)}>{t('common.save')}</button>
						<button onclick={() => (renamingID = null)}>{t('common.cancel')}</button>
					{:else}
						<button aria-label={t('search.runFilter', { name: f.name })} onclick={() => applyFilter(f)}>{f.name}</button>
						<button class="text-muted-foreground" aria-label={t('search.renameFilter', { name: f.name })} onclick={() => ((renamingID = f.id), (renameDraft = f.name))}>{t('common.rename')}</button>
						{#if hasCriteria}
							<button class="text-muted-foreground" aria-label={t('search.overwriteFilter', { name: f.name })} onclick={() => overwriteFilter(f)}>{t('search.overwrite')}</button>
						{/if}
						<button class="text-muted-foreground" aria-label={t('search.deleteFilter', { name: f.name })} onclick={() => deleteFilter(f)}><X class="size-3.5" aria-hidden="true" /></button>
					{/if}
				</li>
			{/each}
		</ul>
	</Panel>

	<Panel title={t('labels.manage')}>
		{#if labels.length === 0}<p class="text-muted-foreground text-sm">{t('labels.empty')}</p>{/if}
		<ul class="flex flex-wrap gap-1.5">
			{#each labels as l (l.id)}
				<li class="bg-secondary flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs" data-testid="label-item">
					{l.name}
					{#if deletingLabelID === l.id}
						<span>{t('labels.deleteConfirm', { name: l.name })}</span>
						<button class="text-destructive" onclick={() => deleteLabel(l)}>{t('common.delete')}</button>
						<button onclick={() => (deletingLabelID = null)}>{t('common.cancel')}</button>
					{:else}
						<button class="text-muted-foreground" aria-label={t('labels.remove', { name: l.name })} onclick={() => (deletingLabelID = l.id)}><X class="size-3.5" aria-hidden="true" /></button>
					{/if}
				</li>
			{/each}
		</ul>
		<form class="flex gap-2" onsubmit={addLabel}>
			<Input bind:value={labelName} placeholder={t('labels.new')} aria-label={t('labels.new')} />
			<Button type="submit" variant="outline">{t('labels.create')}</Button>
		</form>
	</Panel>
</section>
