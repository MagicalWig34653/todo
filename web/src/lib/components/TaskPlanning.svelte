<script lang="ts">
	import { api, type PlanningTask } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { PRIORITIES, fromLocalInput, toLocalInput } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';

	let { taskID, onsaved }: { taskID: string; onsaved: () => unknown } = $props();

	let current = $state<PlanningTask | null>(null);
	let due = $state('');
	let planned = $state('');
	let priority = $state(0);

	function adopt(pt: PlanningTask) {
		current = pt;
		due = toLocalInput(pt.dueAt);
		planned = toLocalInput(pt.plannedAt);
		priority = pt.priority;
	}

	async function load() {
		adopt(await api.getPlanning(taskID));
	}
	$effect(() => {
		void taskID;
		current = null;
		attempt(load);
	});

	async function save() {
		if (!current) return;
		const base = current;
		// PUT replaces all planning data, so untouched recurrence and reminders are sent back unchanged.
		const ok = await attempt(async () => {
			adopt(
				await api.putPlanning(taskID, {
					dueAt: fromLocalInput(due),
					plannedAt: fromLocalInput(planned),
					priority,
					recurrence: base.recurrence ?? null,
					reminders: base.reminders
				})
			);
		}, load);
		if (ok) await onsaved();
	}
</script>

<div class="grid gap-2 sm:grid-cols-3" data-testid="planning-form">
	<div class="flex flex-col gap-1">
		<Label for="due-{taskID}">{t('planning.due')}</Label>
		<Input id="due-{taskID}" type="datetime-local" disabled={!current} bind:value={due} />
	</div>
	<div class="flex flex-col gap-1">
		<Label for="planned-{taskID}">{t('planning.planned')}</Label>
		<Input id="planned-{taskID}" type="datetime-local" disabled={!current} bind:value={planned} />
	</div>
	<div class="flex flex-col gap-1">
		<Label for="prio-{taskID}">{t('planning.priority')}</Label>
		<select
			id="prio-{taskID}"
			class="border-input bg-background h-9 rounded-md border px-2 text-sm"
			disabled={!current}
			bind:value={priority}
		>
			{#each PRIORITIES as p (p)}
				<option value={p}>{t(`planning.priority.${p}` as MessageKey)}</option>
			{/each}
		</select>
	</div>
</div>
<div class="mt-2 flex flex-wrap items-center gap-2">
	<Button size="sm" disabled={!current} onclick={save}>{t('planning.save')}</Button>
	<Button
		size="sm"
		variant="ghost"
		onclick={() => {
			due = '';
			planned = '';
			priority = 0;
		}}>{t('planning.clear')}</Button
	>
	{#if current?.recurrence || (current?.reminders.length ?? 0) > 0}
		<span class="text-muted-foreground text-xs">{t('planning.recurrenceNote')}</span>
	{/if}
</div>
