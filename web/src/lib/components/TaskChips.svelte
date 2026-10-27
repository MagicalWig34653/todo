<script lang="ts">
	import type { TaskStatus } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { formatWhen, isOverdue } from '#lib/planning.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import Flag from '@lucide/svelte/icons/flag';
	import Clock from '@lucide/svelte/icons/clock';
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import Repeat from '@lucide/svelte/icons/repeat';
	import Bell from '@lucide/svelte/icons/bell';

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
	<Badge variant={pt.priority === 3 ? 'destructive' : pt.priority === 2 ? 'warning' : 'default'} data-testid="chip-priority">
		<Flag aria-hidden="true" />{t(`planning.priority.${pt.priority}` as MessageKey)}
	</Badge>
{/if}
{#if pt.dueAt}
	<Badge
		variant={isOverdue(pt.dueAt, done) ? 'destructive' : 'default'}
		data-testid="chip-due"
		title={isOverdue(pt.dueAt, done) ? t('planning.overdue') : t('planning.due')}
	>
		<Clock aria-hidden="true" />{t('planning.due')} {formatWhen(pt.dueAt)}
	</Badge>
{/if}
{#if pt.plannedAt}
	<Badge variant="accent" data-testid="chip-planned"><CalendarDays aria-hidden="true" />{t('planning.planned')} {formatWhen(pt.plannedAt)}</Badge>
{/if}
{#if pt.hasRecurrence}
	<Badge data-testid="chip-recurrence"><Repeat aria-hidden="true" />{t('planning.chip.recurrence')}</Badge>
{/if}
{#if pt.reminderCount}
	<Badge data-testid="chip-reminders"><Bell aria-hidden="true" />{t('planning.chip.reminders', { count: pt.reminderCount })}</Badge>
{/if}
