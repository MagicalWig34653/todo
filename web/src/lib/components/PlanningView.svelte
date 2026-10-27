<script lang="ts">
	import { api, type PlanningTask } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { browserTimeZone } from '#lib/planning.js';
	import TaskChips from './TaskChips.svelte';
	import TaskDetail from './TaskDetail.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';

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
	<PageHeader title={t(`nav.${mode}` as MessageKey)} description={t(`planning.${mode}.hint` as MessageKey)} testid="view-heading" />
	{#if loaded && items.length === 0}<EmptyState title={t(`planning.${mode}.empty` as MessageKey)} icon={CircleCheck} />{/if}
	<ul class="flex flex-col gap-2">
		{#each items as pt (pt.task.id)}
			<li class="bg-card rounded-xl border p-3 shadow-card" data-testid="planning-item">
				<div class="flex flex-wrap items-center gap-2">
					<span class="min-w-0 flex-1 basis-40 text-sm font-medium break-words">{pt.task.title}</span>
					<TaskChips {pt} status={pt.task.status} />
					<Button size="sm" variant="ghost" onclick={() => (openID = openID === pt.task.id ? null : pt.task.id)}>{t('task.details')}<ChevronDown class={['transition-transform', openID === pt.task.id && 'rotate-180']} aria-hidden="true" /></Button>
				</div>
				{#if openID === pt.task.id}<TaskDetail task={pt.task} onplanned={load} />{/if}
			</li>
		{/each}
	</ul>
</section>
