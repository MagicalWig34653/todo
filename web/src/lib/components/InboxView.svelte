<script lang="ts">
	import { api, type Task } from '#lib/api.js';
	import { inboxTasks } from '#lib/counts.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import TaskChips from './TaskChips.svelte';
	import TaskDetail from './TaskDetail.svelte';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import Inbox from '@lucide/svelte/icons/inbox';

	let { onopen }: { onopen: (projectID: string) => void } = $props();
	let openID = $state<string | null>(null);
	const items = $derived(inboxTasks(workspace.tasks));
	const projectName = (id: string) => workspace.projects.find((p) => p.id === id)?.name ?? '';

	$effect(() => {
		attempt(() => workspace.reloadTasks());
	});
	const toggle = (task: Task) => attempt(async () => { await api.updateTask(task, { status: 'done' }); await workspace.reloadTasks(); }, () => workspace.reloadTasks());
</script>

<section class="flex flex-col gap-3">
	<PageHeader title={t('nav.inbox')} description={t('inbox.hint')} testid="view-heading" />
	{#if items.length === 0}<EmptyState title={t('inbox.empty')} icon={Inbox} />{/if}
	<ul class="flex flex-col gap-2">
		{#each items as task (task.id)}
			<li class="bg-card rounded-xl border p-3 shadow-card" data-testid="inbox-item">
				<div class="flex flex-wrap items-center gap-2">
					<Checkbox class="size-5" checked={false} aria-label={t('tasks.done')} onchange={() => toggle(task)} />
					<span class="min-w-0 flex-1 basis-40 text-sm font-medium break-words">{task.title}</span>
					{#if task.planning}<TaskChips pt={task.planning} status={task.status} />{/if}
					<button class="text-muted-foreground hover:text-foreground inline-flex items-center gap-1 text-xs" onclick={() => onopen(task.projectID)}>
						<span style:color={workspace.colorOf(task.projectID)} aria-hidden="true">#</span>{projectName(task.projectID)}
					</button>
					<Button size="sm" variant="ghost" onclick={() => (openID = openID === task.id ? null : task.id)}>{t('task.details')}<ChevronDown class={['transition-transform', openID === task.id && 'rotate-180']} aria-hidden="true" /></Button>
				</div>
				{#if openID === task.id}<TaskDetail {task} onplanned={() => workspace.reloadTasks()} />{/if}
			</li>
		{/each}
	</ul>
</section>
