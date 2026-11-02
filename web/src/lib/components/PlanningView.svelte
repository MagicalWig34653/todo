<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { api, type PlanningTask } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { startLiveRefresh, sameList } from '#lib/liveRefresh.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { browserTimeZone } from '#lib/planning.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import TaskRow from './TaskRow.svelte';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import CircleCheck from '@lucide/svelte/icons/circle-check';

	let { mode }: { mode: 'today' | 'upcoming' | 'upNext' } = $props();

	let items = $state<PlanningTask[]>([]);
	let loaded = $state(false);
	let openID = $state<string | null>(null);
	let seq = 0;

	/** Only the newest answer counts; unchanged lists are not re-assigned (open details and drafts stay untouched). */
	async function fetchItems() {
		const mine = ++seq;
		const tz = browserTimeZone();
		const next = await (mode === 'today' ? api.today(tz) : mode === 'upcoming' ? api.upcoming(tz) : api.upNext(tz));
		if (mine !== seq) return;
		if (!sameList(items, next)) items = next;
		loaded = true;
	}
	/** Background refresh: failures keep the shown list. */
	const refresh = () => fetchItems().catch(() => undefined);

	$effect(() => {
		void mode;
		untrack(() => {
			loaded = false;
			openID = null;
			items = [];
			void attempt(fetchItems);
		});
	});
	// The shell refreshes workspace.tasks (sidebar counters) on every live tick and after local changes; reload the list
	// from the same source so counter and list cannot drift apart. Quick add bumps changeTick.
	let seenTasks = workspace.tasks;
	$effect(() => {
		const tasks = workspace.tasks;
		if (tasks === seenTasks) return;
		seenTasks = tasks;
		untrack(() => void refresh());
	});
	let seenTick = ui.changeTick;
	$effect(() => {
		if (ui.changeTick === seenTick) return;
		seenTick = ui.changeTick;
		untrack(() => void refresh());
	});
	onMount(() => startLiveRefresh(refresh, { guardEditing: true }));
</script>

<section class="flex flex-col gap-3">
	<PageHeader title={t(`nav.${mode}` as MessageKey)} description={t(`planning.${mode}.hint` as MessageKey)} testid="view-heading" />
	{#if loaded && items.length === 0}<EmptyState title={t(`planning.${mode}.empty` as MessageKey)} icon={CircleCheck} />{/if}
	<ul class="flex flex-col gap-2">
		{#each items as pt (pt.task.id)}
			<TaskRow task={pt.task} {pt} open={openID === pt.task.id} ontoggle={() => (openID = openID === pt.task.id ? null : pt.task.id)} onchanged={refresh} />
		{/each}
	</ul>
</section>
