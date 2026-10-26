<script lang="ts">
	import { api, type PlanningTask } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { browserTimeZone } from '#lib/planning.js';
	import TaskChips from './TaskChips.svelte';
	import TaskDetail from './TaskDetail.svelte';
	import { Button } from '#lib/components/ui/button/index.js';

	let { mode }: { mode: 'today' | 'upcoming' | 'upNext' } = $props();

	let items = $state<PlanningTask[]>([]);
	let loaded = $state(false);
	let openID = $state<string | null>(null);

	async function load() {
		const tz = browserTimeZone();
		items = await (mode === 'today' ? api.today(tz) : mode === 'upcoming' ? api.upcoming(tz) : api.upNext(tz));
		loaded = true;
	}
	$effect(() => {
		void mode;
		loaded = false;
		openID = null;
		attempt(load);
	});
</script>

<section class="flex flex-col gap-3">
	<h2 class="text-xl font-semibold" data-testid="view-heading">{t(`nav.${mode}` as MessageKey)}</h2>
	<p class="text-muted-foreground text-sm">{t(`planning.${mode}.hint` as MessageKey)}</p>
	{#if loaded && items.length === 0}<p class="text-muted-foreground text-sm">{t(`planning.${mode}.empty` as MessageKey)}</p>{/if}
	<ul class="flex flex-col gap-1">
		{#each items as pt (pt.task.id)}
			<li class="rounded-md border p-2" data-testid="planning-item">
				<div class="flex flex-wrap items-center gap-2">
					<span class="flex-1 text-sm">{pt.task.title}</span>
					<TaskChips {pt} />
					<Button size="sm" variant="ghost" onclick={() => (openID = openID === pt.task.id ? null : pt.task.id)}>{t('task.details')}</Button>
				</div>
				{#if openID === pt.task.id}<TaskDetail task={pt.task} onplanned={load} />{/if}
			</li>
		{/each}
	</ul>
</section>
