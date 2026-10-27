<script lang="ts">
	import { api, type MilestoneWithTasks, type Project, type Task } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { candidateTasks, formatWhen, fromLocalInput, isOverdue, milestoneProgress } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	let { project }: { project: Project } = $props();

	let items = $state<MilestoneWithTasks[]>([]);
	let projectTasks = $state<Task[]>([]);
	let loaded = $state(false);
	let title = $state('');
	let due = $state('');
	let picks = $state<Record<string, string>>({});
	let deletingID = $state<string | null>(null);

	async function load() {
		[items, projectTasks] = await Promise.all([api.milestones(project.id), api.listTasks(project.id)]);
		loaded = true;
	}
	$effect(() => {
		void project.id;
		loaded = false;
		deletingID = null;
		picks = {};
		attempt(load);
	});

	async function create(e: Event) {
		e.preventDefault();
		const name = title.trim();
		if (!name) return;
		if (await attempt(async () => { await api.createMilestone(project.id, name, fromLocalInput(due)); await load(); }, load)) {
			title = '';
			due = '';
		}
	}
	const assign = (m: MilestoneWithTasks) =>
		attempt(async () => {
			const id = picks[m.milestone.id];
			if (!id) return;
			await api.assignMilestoneTask(m.milestone.id, id);
			picks[m.milestone.id] = '';
			await load();
		}, load);
	const unassign = (m: MilestoneWithTasks, task: Task) =>
		attempt(async () => { await api.unassignMilestoneTask(m.milestone.id, task.id); await load(); }, load);
	const remove = (m: MilestoneWithTasks) =>
		attempt(async () => { await api.deleteMilestone(m.milestone.id); deletingID = null; await load(); }, load);
</script>

<section class="flex flex-col gap-4" data-testid="milestones">
	<h2 class="text-xl font-semibold" data-testid="task-heading">{project.name}</h2>
	<form class="flex flex-wrap items-end gap-2" onsubmit={create}>
		<Input class="min-w-40 flex-1" bind:value={title} placeholder={t('milestones.new')} aria-label={t('milestones.new')} />
		<Input class="w-auto" type="datetime-local" bind:value={due} aria-label={t('milestones.due')} />
		<Button type="submit" size="lg">{t('milestones.create')}</Button>
	</form>

	{#if loaded && items.length === 0}<p class="text-muted-foreground text-sm">{t('milestones.empty')}</p>{/if}
	<ul class="flex flex-col gap-3">
		{#each items as m (m.milestone.id)}
			{@const progress = milestoneProgress(m.tasks)}
			{@const options = candidateTasks(projectTasks, null, m.tasks)}
			<li class="flex flex-col gap-2 rounded-md border p-3" data-testid="milestone">
				<div class="flex flex-wrap items-center gap-2">
					<h3 class="flex-1 font-medium break-words">{m.milestone.title}</h3>
					{#if m.milestone.dueAt}
						<span class={['rounded px-1.5 py-0.5 text-xs', isOverdue(m.milestone.dueAt, progress.total > 0 && progress.done === progress.total) ? 'bg-destructive/10 text-destructive' : 'bg-muted text-muted-foreground']}>
							{t('planning.due')} {formatWhen(m.milestone.dueAt)}
						</span>
					{/if}
					<span class="text-muted-foreground text-xs" data-testid="milestone-progress">
						{t('milestones.progress', { done: progress.done, total: progress.total })}
					</span>
					{#if deletingID === m.milestone.id}
						<span class="text-sm">{t('milestones.deleteConfirm', { title: m.milestone.title })}</span>
						<Button size="xs" variant="destructive" onclick={() => remove(m)}>{t('common.delete')}</Button>
						<Button size="xs" variant="ghost" onclick={() => (deletingID = null)}>{t('common.cancel')}</Button>
					{:else}
						<Button size="xs" variant="ghost" onclick={() => (deletingID = m.milestone.id)}>{t('common.delete')}</Button>
					{/if}
				</div>
				<ul class="flex flex-col gap-1">
					{#each m.tasks as task (task.id)}
						<li class="flex items-center gap-2 text-sm" data-testid="milestone-task">
							<span class="bg-muted text-muted-foreground rounded px-1.5 py-0.5 text-xs">{t(`status.${task.status}` as MessageKey)}</span>
							<span class={['flex-1 break-words', task.status === 'done' && 'text-muted-foreground line-through']}>{task.title}</span>
							<Button size="xs" variant="ghost" aria-label={t('milestones.unassign', { title: task.title })} onclick={() => unassign(m, task)}>
								{t('milestones.unassignShort')}
							</Button>
						</li>
					{/each}
				</ul>
				<div class="flex flex-wrap gap-2">
					<select
						class="border-input bg-background h-9 min-w-0 flex-1 rounded-md border px-2 text-sm"
						aria-label={t('milestones.pickTask')}
						bind:value={picks[m.milestone.id]}
					>
						<option value="">{t('milestones.pickTask')}</option>
						{#each options as o (o.id)}<option value={o.id}>{o.title}</option>{/each}
					</select>
					<Button size="sm" variant="outline" disabled={!picks[m.milestone.id]} onclick={() => assign(m)}>{t('milestones.assign')}</Button>
				</div>
			</li>
		{/each}
	</ul>
	<p class="text-muted-foreground text-xs">{t('milestones.hint')}</p>
</section>
