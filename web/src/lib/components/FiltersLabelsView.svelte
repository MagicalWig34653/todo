<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import Panel from './app/Panel.svelte';
	import Funnel from '@lucide/svelte/icons/funnel';
	import Plus from '@lucide/svelte/icons/plus';
	import Tag from '@lucide/svelte/icons/tag';

	let { onsearch }: { onsearch: (initial: { labelID?: string; filterID?: string }) => void } = $props();
	let name = $state('');

	$effect(() => {
		attempt(() => workspace.reloadMeta());
	});
	async function create(e: Event) {
		e.preventDefault();
		const n = name.trim();
		if (!n) return;
		if (await attempt(async () => (workspace.labels = [...workspace.labels, await api.createLabel(n)]))) name = '';
	}
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('nav.filters')} description={t('filters.hint')} testid="view-heading" />
	<Panel title={t('filters.filters')}>
		{#if workspace.filters.length === 0}<p class="text-muted-foreground text-sm">{t('search.filters.empty')}</p>{/if}
		<ul class="flex flex-col gap-1">
			{#each workspace.filters as f (f.id)}
				<li>
					<button class="hover:bg-muted flex min-h-9 w-full items-center gap-2 rounded-lg px-2 text-left text-sm" data-testid="filters-view-filter" onclick={() => onsearch({ filterID: f.id })}>
						<Funnel class="text-muted-foreground size-4" aria-hidden="true" />{f.name}
					</button>
				</li>
			{/each}
		</ul>
	</Panel>
	<Panel title={t('filters.labels')}>
		{#if workspace.labels.length === 0}<p class="text-muted-foreground text-sm">{t('filters.labelsEmpty')}</p>{/if}
		<ul class="flex flex-col gap-1">
			{#each workspace.labels as l (l.id)}
				<li>
					<button class="hover:bg-muted flex min-h-9 w-full items-center gap-2 rounded-lg px-2 text-left text-sm" data-testid="filters-view-label" onclick={() => onsearch({ labelID: l.id })}>
						<Tag class="text-muted-foreground size-4" aria-hidden="true" />{l.name}
					</button>
				</li>
			{/each}
		</ul>
		<form class="flex gap-2" onsubmit={create}>
			<Input bind:value={name} placeholder={t('labels.new')} aria-label={t('filters.newLabel')} />
			<Button type="submit" variant="outline"><Plus aria-hidden="true" />{t('filters.addLabel')}</Button>
		</form>
	</Panel>
</section>
