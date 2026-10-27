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

	let { task, onplanned }: { task: Task; onplanned?: () => unknown } = $props();
	let activityKey = $state(0);
	const bump = () => void activityKey++;
</script>

<div class="bg-muted/30 mt-2 flex flex-col gap-4 rounded-md p-3" data-testid="task-detail">
	<section class="flex flex-col gap-1">
		<h3 class="text-sm font-medium">{t('planning.title')}</h3>
		<TaskPlanning taskID={task.id} onsaved={async () => { await onplanned?.(); bump(); }} />
	</section>
	<section class="flex flex-col gap-1">
		<h3 class="text-sm font-medium">{t('task.section.dependencies')}</h3>
		<TaskDependencies {task} onchanged={bump} />
	</section>
	<section class="flex flex-col gap-1">
		<h3 class="text-sm font-medium">{t('task.section.labels')}</h3>
		<TaskLabels taskID={task.id} />
	</section>
	<section class="flex flex-col gap-1">
		<h3 class="text-sm font-medium">{t('task.section.criteria')}</h3>
		<TaskCriteria taskID={task.id} />
	</section>
	<section class="flex flex-col gap-1">
		<h3 class="text-sm font-medium">{t('task.section.attachments')}</h3>
		<TaskAttachments taskID={task.id} onchanged={bump} />
	</section>
	<section class="flex flex-col gap-1">
		<h3 class="text-sm font-medium">{t('task.section.comments')}</h3>
		<TaskComments taskID={task.id} onchanged={bump} />
	</section>
	<section class="flex flex-col gap-1">
		<h3 class="text-sm font-medium">{t('task.section.activity')}</h3>
		<TaskActivity taskID={task.id} refreshKey={activityKey} />
	</section>
</div>
