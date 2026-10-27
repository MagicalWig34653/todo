<script lang="ts">
	import type { TaskStatus } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { formatWhen, isOverdue } from '#lib/planning.js';

	/** Structural: works for `PlanningTask` entries and for task-list entries with a planning summary. */
	interface Chips {
		priority: number;
		dueAt?: string | null;
		plannedAt?: string | null;
		hasRecurrence?: boolean;
		reminderCount?: number;
	}
	let { pt, status }: { pt: Chips; status: TaskStatus } = $props();
	const done = $derived(status === 'done');
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
{#if pt.hasRecurrence}
	<span class="bg-muted text-muted-foreground rounded px-1.5 py-0.5 text-xs" data-testid="chip-recurrence">{t('planning.chip.recurrence')}</span>
{/if}
{#if pt.reminderCount}
	<span class="bg-muted text-muted-foreground rounded px-1.5 py-0.5 text-xs" data-testid="chip-reminders">
		{t('planning.chip.reminders', { count: pt.reminderCount })}
	</span>
{/if}
