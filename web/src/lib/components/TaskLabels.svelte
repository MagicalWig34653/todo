<script lang="ts">
	import { untrack } from 'svelte';
	import { Select } from '#lib/components/ui/select/index.js';
	import { api, type Label } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { collectAll } from '#lib/planning.js';
	import { onMount } from 'svelte';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';

	/** `compact` (card sidebar): no placeholder text; the picker shows only while `showPicker`. */
	let { taskID, compact = false, showPicker = true }: { taskID: string; compact?: boolean; showPicker?: boolean } = $props();

	let assigned = $state<Label[]>([]);
	let all = $state<Label[]>([]);
	let pick = $state('');

	const free = $derived(all.filter((l) => !assigned.some((a) => a.id === l.id)));

	async function load() {
		[assigned, all] = await Promise.all([
			api.taskLabels(taskID).then((p) => p.items),
			collectAll((c) => api.listLabels(c))
		]);
	}
	$effect(() => {
		void taskID;
		untrack(() => attempt(load));
	});
	onMount(() =>
		startLiveRefresh(async () => {
			const before = assigned;
			const next = await api.taskLabels(taskID).then((p) => p.items);
			if (assigned === before && !sameList(assigned, next)) assigned = next;
		}, { guardEditing: true })
	);

	async function add() {
		if (!pick) return;
		const id = pick;
		if (await attempt(() => api.addTaskLabel(taskID, id), load)) {
			pick = '';
			await attempt(load);
		}
	}
	const remove = async (l: Label) => {
		if (await attempt(() => api.removeTaskLabel(taskID, l.id), load)) await attempt(load);
	};
</script>

<div class="flex flex-wrap items-center gap-1">
	{#each assigned as l (l.id)}
		<span class="bg-secondary inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs" data-testid="task-label">
			{l.name}
			<button aria-label={t('labels.remove', { name: l.name })} class="text-muted-foreground" onclick={() => remove(l)}>×</button>
		</span>
	{/each}
	{#if assigned.length === 0 && !compact}<span class="text-muted-foreground text-xs">{t('labels.none')}</span>{/if}
	{#if showPicker && free.length > 0}
		<Select
			
			aria-label={t('labels.add')}
			bind:value={pick}
			onchange={add}
		>
			<option value="">{t('labels.pick')}</option>
			{#each free as l (l.id)}<option value={l.id}>{l.name}</option>{/each}
		</Select>
	{/if}
</div>
