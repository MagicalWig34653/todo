<script lang="ts">
	import type { Task } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import TaskActivity from './TaskActivity.svelte';
	import TaskAttachments from './TaskAttachments.svelte';
	import TaskComments from './TaskComments.svelte';
	import TaskDependencies from './TaskDependencies.svelte';
	import TaskCriteria from './TaskCriteria.svelte';
	import TaskLabels from './TaskLabels.svelte';
	import TaskPlanning from './TaskPlanning.svelte';
	import { workspace } from '#lib/workspace.svelte.js';

	let { task, onplanned }: { task: Task; onplanned?: () => unknown } = $props();
	let activityKey = $state(0);
	const bump = () => void activityKey++;
	/** Classic projects show a plain todo item: no dependencies, acceptance criteria or activity log. */
	const management = $derived(workspace.modeOf(task.projectID) === 'management');
</script>

<div class="bg-muted/40 mt-3 flex flex-col gap-5 rounded-lg border p-3 sm:p-4" data-testid="task-detail">
	<section class="flex flex-col gap-2">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('planning.title')}</h3>
		<TaskPlanning taskID={task.id} onsaved={async () => { await onplanned?.(); bump(); }} />
	</section>
	{#if management}
	<section class="flex flex-col gap-2">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('task.section.dependencies')}</h3>
		<TaskDependencies {task} onchanged={bump} />
	</section>
	{/if}
	<section class="flex flex-col gap-2">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('task.section.labels')}</h3>
		<TaskLabels taskID={task.id} />
	</section>
	{#if management}
	<section class="flex flex-col gap-2">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('task.section.criteria')}</h3>
		<TaskCriteria taskID={task.id} />
	</section>
	{/if}
	<section class="flex flex-col gap-2">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('task.section.attachments')}</h3>
		<TaskAttachments taskID={task.id} onchanged={bump} />
	</section>
	<section class="flex flex-col gap-2">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('task.section.comments')}</h3>
		<TaskComments taskID={task.id} onchanged={bump} />
	</section>
	{#if management}
	<section class="flex flex-col gap-2">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('task.section.activity')}</h3>
		<TaskActivity taskID={task.id} refreshKey={activityKey} />
	</section>
	{/if}
</div>
