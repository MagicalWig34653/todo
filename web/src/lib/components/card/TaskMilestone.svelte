<script lang="ts">
	import { untrack } from 'svelte';
	import { Select } from '#lib/components/ui/select/index.js';
	import { api, type MilestoneWithTasks } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import X from '@lucide/svelte/icons/x';

	/** Milestones of the task's project the task belongs to, with a picker to assign another one (card sidebar). */
	let { taskID, projectID, adding = false, onchanged }: { taskID: string; projectID: string; adding?: boolean; onchanged?: () => unknown } = $props();

	let items = $state<MilestoneWithTasks[]>([]);
	let pick = $state('');
	const mine = $derived(items.filter((m) => m.tasks.some((x) => x.id === taskID)));
	const free = $derived(items.filter((m) => !m.tasks.some((x) => x.id === taskID)));

	async function load() {
		items = await api.milestones(projectID);
	}
	$effect(() => {
		void taskID;
		void projectID;
		untrack(() => attempt(load));
	});

	async function assign(id: string) {
		if (!id) return;
		if (await attempt(async () => { await api.assignMilestoneTask(id, taskID); await load(); }, load)) {
			pick = '';
			await onchanged?.();
		}
	}
	const unassign = (id: string) =>
		attempt(async () => {
			await api.unassignMilestoneTask(id, taskID);
			await load();
			await onchanged?.();
		}, load);
</script>

<div class="flex flex-col gap-2" data-testid="task-milestones">
	{#each mine as m (m.milestone.id)}
		<div class="flex items-center justify-between gap-2" data-testid="task-milestone">
			<span class="min-w-0 [overflow-wrap:anywhere]">{m.milestone.title}{#if m.milestone.dueAt}<span class="text-muted-foreground" data-tabular> · {formatWhen(m.milestone.dueAt)}</span>{/if}</span>
			<button type="button" class="text-muted-foreground hover:text-foreground hit-area relative inline-flex size-6 shrink-0 items-center justify-center" aria-label={t('milestones.unassign', { title: m.milestone.title })} onclick={() => unassign(m.milestone.id)}><X class="size-3.5" aria-hidden="true" /></button>
		</div>
	{/each}
	{#if adding && free.length > 0}
		<Select aria-label={t('card.side.milestonePick')} value={pick} onchange={(e) => void assign(e.currentTarget.value)}>
			<option value="">{t('card.side.milestonePick')}</option>
			{#each free as m (m.milestone.id)}<option value={m.milestone.id}>{m.milestone.title}</option>{/each}
		</Select>
	{:else if adding}
		<p class="text-muted-foreground text-xs">{t('card.side.milestoneNone')}</p>
	{/if}
</div>
