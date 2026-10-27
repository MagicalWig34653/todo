<script lang="ts">
	import { api, type Task } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { candidateTasks } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';

	let { task, onchanged }: { task: Task; onchanged?: () => unknown } = $props();

	let prerequisites = $state<Task[]>([]);
	let projectTasks = $state<Task[]>([]);
	let pick = $state('');

	const options = $derived(candidateTasks(projectTasks, task.id, prerequisites));

	async function load() {
		[prerequisites, projectTasks] = await Promise.all([api.dependencies(task.id), api.listTasks(task.projectID)]);
	}
	$effect(() => {
		void task.id;
		pick = '';
		attempt(load);
	});

	async function add(e: Event) {
		e.preventDefault();
		if (!pick) return;
		// A cycle is answered with 422; the generic mapping explains it.
		if (await attempt(async () => { await api.addDependency(task.id, pick); await load(); }, load)) {
			pick = '';
			await onchanged?.();
		}
	}
	const remove = (p: Task) =>
		attempt(async () => {
			await api.removeDependency(task.id, p.id);
			await load();
			await onchanged?.();
		}, load);
</script>

<div class="flex flex-col gap-2" data-testid="dependencies">
	{#if prerequisites.length === 0}<p class="text-muted-foreground text-xs">{t('dependencies.empty')}</p>{/if}
	<ul class="flex flex-col gap-1">
		{#each prerequisites as p (p.id)}
			<li class="flex items-center gap-2 text-sm" data-testid="dependency">
				<span class="bg-muted text-muted-foreground rounded px-1.5 py-0.5 text-xs">{t(`status.${p.status}` as MessageKey)}</span>
				<span class={['flex-1 break-words', p.status === 'done' && 'text-muted-foreground line-through']}>{p.title}</span>
				<Button size="xs" variant="ghost" aria-label={t('dependencies.remove', { title: p.title })} onclick={() => remove(p)}>
					{t('dependencies.removeShort')}
				</Button>
			</li>
		{/each}
	</ul>
	<form class="flex flex-wrap gap-2" onsubmit={add}>
		<select class="border-input bg-background h-9 min-w-0 flex-1 rounded-md border px-2 text-sm" aria-label={t('dependencies.pick')} bind:value={pick}>
			<option value="">{t('dependencies.pick')}</option>
			{#each options as o (o.id)}<option value={o.id}>{o.title}</option>{/each}
		</select>
		<Button type="submit" size="sm" variant="outline" disabled={!pick}>{t('dependencies.add')}</Button>
	</form>
	<p class="text-muted-foreground text-xs">{t('dependencies.hint')}</p>
</div>
