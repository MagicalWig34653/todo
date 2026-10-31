<script lang="ts">
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { api, type Criterion } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { onMount } from 'svelte';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	let { taskID }: { taskID: string } = $props();

	let items = $state<Criterion[]>([]);
	let text = $state('');
	const doneCount = $derived(items.filter((c) => c.completed).length);

	async function load() {
		items = await api.listCriteria(taskID);
	}
	$effect(() => {
		void taskID;
		attempt(load);
	});
	onMount(() =>
		startLiveRefresh(async () => {
			const before = items;
			const next = await api.listCriteria(taskID);
			// A local change during the fetch makes the answer stale; the next hint reloads.
			if (items === before && !sameList(items, next)) items = next;
		}, { guardEditing: true })
	);

	async function add(e: Event) {
		e.preventDefault();
		const v = text.trim();
		if (!v) return;
		if (await attempt(async () => (items = [...items, await api.createCriterion(taskID, v)]))) text = '';
	}
	const toggle = (c: Criterion) =>
		attempt(
			async () => {
				const u = await api.updateCriterion(c, { completed: !c.completed });
				items = items.map((x) => (x.id === u.id ? u : x));
			},
			load
		);
	const remove = (c: Criterion) =>
		attempt(async () => {
			await api.deleteCriterion(c);
			items = items.filter((x) => x.id !== c.id);
		}, load);
</script>

<div class="flex flex-col gap-1">
	{#if items.length > 0}
		<p class="text-muted-foreground text-xs" data-testid="criteria-progress">
			{t('criteria.progress', { done: doneCount, total: items.length })}
		</p>
	{:else}
		<p class="text-muted-foreground text-xs">{t('criteria.empty')}</p>
	{/if}
	<ul class="flex flex-col gap-1">
		{#each items as c (c.id)}
			<li class="flex items-center gap-2 text-sm" data-testid="criterion">
				<Checkbox  class="size-4" checked={c.completed} aria-label={c.text} onchange={() => toggle(c)} />
				<span class={['flex-1', c.completed && 'text-muted-foreground line-through']}>{c.text}</span>
				<Button size="xs" variant="ghost" aria-label={t('criteria.remove', { text: c.text })} onclick={() => remove(c)}>×</Button>
			</li>
		{/each}
	</ul>
	<form class="flex gap-1" onsubmit={add}>
		<Input bind:value={text} placeholder={t('criteria.new')} aria-label={t('criteria.new')} />
		<Button type="submit" size="lg" variant="outline">{t('criteria.add')}</Button>
	</form>
</div>
