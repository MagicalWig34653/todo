<script lang="ts">
	import { api, type Project, type Task, type TaskStatus } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';
	import TaskDetail from './TaskDetail.svelte';
	import TaskChips from './TaskChips.svelte';
	import { Textarea } from '#lib/components/ui/textarea/index.js';

	let { project }: { project: Project } = $props();

	const STATUSES: TaskStatus[] = ['open', 'in_progress', 'in_review', 'done'];

	let tasks = $state<Task[]>([]);
	let loaded = $state(false);
	let quick = $state('');
	let editingID = $state<string | null>(null);
	let draftTitle = $state('');
	let draftDescription = $state('');
	let deletingID = $state<string | null>(null);
	let detailID = $state<string | null>(null);

	async function load() {
		tasks = await api.listTasks(project.id);
		loaded = true;
	}

	$effect(() => {
		// Reload whenever another project is selected.
		void project.id;
		loaded = false;
		editingID = null;
		deletingID = null;
		detailID = null;
		attempt(load);
	});

	function replace(updated: Task) {
		tasks = tasks.map((x) => (x.id === updated.id ? updated : x));
	}

	async function add(e: Event) {
		e.preventDefault();
		const title = quick.trim();
		if (!title) return;
		const ok = await attempt(async () => {
			tasks = [...tasks, await api.createTask(project.id, title)];
		});
		if (ok) quick = '';
	}

	function toggle(task: Task) {
		return attempt(async () => replace(await api.updateTask(task, { status: task.status === 'done' ? 'open' : 'done' })), load);
	}

	function setStatus(task: Task, status: TaskStatus) {
		return attempt(async () => replace(await api.updateTask(task, { status })), load);
	}

	function edit(task: Task) {
		editingID = task.id;
		draftTitle = task.title;
		draftDescription = task.description;
	}

	async function save(task: Task) {
		const ok = await attempt(
			async () => replace(await api.updateTask(task, { title: draftTitle, description: draftDescription })),
			load
		);
		if (ok || !tasks.some((x) => x.id === task.id)) editingID = null;
	}

	async function remove(task: Task) {
		await attempt(async () => {
			await api.deleteTask(task.id);
			tasks = tasks.filter((x) => x.id !== task.id);
			deletingID = null;
		}, load);
	}
</script>

<section class="flex flex-col gap-4">
	<h2 class="text-xl font-semibold" data-testid="task-heading">{project.name}</h2>

	<form class="flex gap-2" onsubmit={add}>
		<Input bind:value={quick} placeholder={t('tasks.quickPlaceholder')} aria-label={t('tasks.quickPlaceholder')} />
		<Button type="submit" size="lg">{t('tasks.add')}</Button>
	</form>

	{#if loaded && tasks.length === 0}
		<p class="text-muted-foreground text-sm">{t('tasks.empty')}</p>
	{/if}

	<ul class="flex flex-col gap-1">
		{#each tasks as task (task.id)}
			<li class="min-w-0 rounded-md border p-2" data-testid="task-item">
				<div class="flex flex-wrap items-center gap-2">
					<input
						type="checkbox"
						class="size-5"
						checked={task.status === 'done'}
						aria-label={task.status === 'done' ? t('tasks.reopen') : t('tasks.done')}
						onchange={() => toggle(task)}
					/>
					<span class={['min-w-0 flex-1 basis-40 text-sm break-words', task.status === 'done' && 'text-muted-foreground line-through']}>
						{task.title}
					</span>
					<select
						class="border-input bg-background h-8 rounded-md border px-1 text-xs"
						aria-label={t('tasks.status')}
						value={task.status}
						onchange={(e) => setStatus(task, e.currentTarget.value as TaskStatus)}
					>
						{#each STATUSES as s (s)}
							<option value={s}>{t(`status.${s}` as MessageKey)}</option>
						{/each}
					</select>
					<Button
						size="sm"
						variant="ghost"
						aria-expanded={detailID === task.id}
						onclick={() => (detailID = detailID === task.id ? null : task.id)}>{t('task.details')}</Button
					>
					<Button size="sm" variant="ghost" onclick={() => (editingID === task.id ? (editingID = null) : edit(task))}>
						{t('tasks.edit')}
					</Button>
				</div>

				{#if task.planning && (task.planning.priority > 0 || task.planning.dueAt || task.planning.plannedAt || task.planning.hasRecurrence || task.planning.reminderCount > 0)}
					<div class="mt-1 flex flex-wrap gap-1 pl-7" data-testid="task-chips"><TaskChips pt={task.planning} status={task.status} /></div>
				{/if}

				{#if detailID === task.id}
					<TaskDetail {task} onplanned={load} />
				{/if}

				{#if editingID === task.id}
					<div class="mt-2 flex flex-col gap-2">
						<Label for="title-{task.id}">{t('tasks.titleLabel')}</Label>
						<Input id="title-{task.id}" bind:value={draftTitle} />
						<Label for="desc-{task.id}">{t('tasks.description')}</Label>
						<Textarea id="desc-{task.id}" bind:value={draftDescription} placeholder={t('tasks.descriptionPlaceholder')} />
						<div class="flex flex-wrap gap-1">
							<Button size="sm" onclick={() => save(task)}>{t('common.save')}</Button>
							<Button size="sm" variant="ghost" onclick={() => (editingID = null)}>{t('common.cancel')}</Button>
							{#if deletingID === task.id}
								<span class="self-center text-sm">{t('tasks.deleteConfirm', { title: task.title })}</span>
								<Button size="sm" variant="destructive" onclick={() => remove(task)}>{t('common.delete')}</Button>
							{:else}
								<Button size="sm" variant="destructive" onclick={() => (deletingID = task.id)}>{t('common.delete')}</Button>
							{/if}
						</div>
					</div>
				{:else if task.description}
					<p class="text-muted-foreground mt-1 pl-7 text-sm whitespace-pre-wrap">{task.description}</p>
				{/if}
			</li>
		{/each}
	</ul>
</section>
