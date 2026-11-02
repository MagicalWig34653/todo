<script lang="ts">
	import type { ComponentProps } from 'svelte';
	import { api, type Task } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { openProjectRoute } from '#lib/navigate.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import Maximize2 from '@lucide/svelte/icons/maximize-2';
	import TaskChips from './TaskChips.svelte';
	import TaskDetail from './TaskDetail.svelte';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';

	/** Shared task row of the planning lists (Today, Upcoming, Up next, Inbox): complete/reopen, project link, details. */
	interface Props {
		task: Task;
		/** Planning data to show as chips (defaults to the task's own summary). */
		pt?: ComponentProps<typeof TaskChips>['pt'] | null;
		open: boolean;
		ontoggle: () => void;
		/** Called after a change so the surrounding list reloads. */
		onchanged: () => unknown;
		testid?: string;
	}
	let { task, pt, open, ontoggle, onchanged, testid = 'planning-item' }: Props = $props();

	let busy = $state(false);
	const done = $derived(task.status === 'done');
	const project = $derived(workspace.projects.find((p) => p.id === task.projectID));
	const chips = $derived(pt ?? task.planning);

	async function toggle() {
		if (busy) return;
		busy = true;
		try {
			await attempt(async () => {
				await api.updateTask(task, { status: done ? 'open' : 'done' });
				await onchanged();
				await workspace.reloadTasks();
			}, async () => { await onchanged(); });
		} finally {
			busy = false;
		}
	}
</script>

<li class="bg-card rounded-xl border p-3 shadow-card" data-testid={testid}>
	<div class="flex flex-wrap items-center gap-2">
		<Checkbox class="size-5" checked={done} disabled={busy} aria-label={done ? t('tasks.reopen') : t('tasks.done')} onchange={toggle} />
		<span class={['min-w-0 flex-1 basis-40 text-sm font-medium break-words', done && 'text-muted-foreground line-through']}>{task.title}</span>
		{#if chips}<TaskChips pt={chips} status={task.status} />{/if}
		{#if project}
			<a
				href="/project/{project.id}"
				class="text-muted-foreground hover:text-foreground inline-flex min-h-8 items-center gap-1 text-xs"
				data-testid="task-project-link"
				onclick={(e) => { e.preventDefault(); openProjectRoute(project.id); }}
			><span style:color={workspace.colorOf(project.id)} aria-hidden="true">#</span>{project.name}</a>
		{/if}
		<Button size="sm" variant="ghost" data-testid="task-open-large" aria-label={t('card.openLarge', { title: task.title })} title={t('card.openLarge', { title: task.title })} onclick={() => cardDetail.open({ type: 'task', id: task.id })}><Maximize2 aria-hidden="true" /></Button>
		<Button size="sm" variant="ghost" aria-expanded={open} onclick={ontoggle}>{t('task.details')}<ChevronDown class={['transition-transform', open && 'rotate-180']} aria-hidden="true" /></Button>
	</div>
	{#if open}<TaskDetail {task} standalone onplanned={onchanged} />{/if}
</li>
