<script lang="ts">
	import type { PlanningTask } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { formatWhen, isOverdue } from '#lib/planning.js';

	let { pt }: { pt: PlanningTask } = $props();
	const done = $derived(pt.task.status === 'done');
</script>

{#if pt.priority > 0}
	<span
		class={['rounded px-1.5 py-0.5 text-xs', pt.priority === 3 ? 'bg-destructive/10 text-destructive' : 'bg-muted text-muted-foreground']}
		data-testid="chip-priority"
	>
		{t(`planning.priority.${pt.priority}` as MessageKey)}
	</span>
{/if}
{#if pt.dueAt}
	<span
		class={['rounded px-1.5 py-0.5 text-xs', isOverdue(pt.dueAt, done) ? 'bg-destructive/10 text-destructive' : 'bg-muted text-muted-foreground']}
		data-testid="chip-due"
		title={isOverdue(pt.dueAt, done) ? t('planning.overdue') : t('planning.due')}
	>
		{t('planning.due')} {formatWhen(pt.dueAt)}
	</span>
{/if}
{#if pt.plannedAt}
	<span class="bg-muted text-muted-foreground rounded px-1.5 py-0.5 text-xs" data-testid="chip-planned">
		{t('planning.planned')} {formatWhen(pt.plannedAt)}
	</span>
{/if}
