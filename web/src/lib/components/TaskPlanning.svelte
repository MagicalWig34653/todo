<script lang="ts">
	import { Select } from '#lib/components/ui/select/index.js';
	import { api, type PlanningTask } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import {
		PRIORITIES,
		addReminder,
		buildRecurrence,
		formatWhen,
		fromLocalInput,
		recurrenceNeedsDate,
		removeReminder,
		toLocalInput,
		type Frequency
	} from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';

	let { taskID, onsaved }: { taskID: string; onsaved: () => unknown } = $props();

	let current = $state<PlanningTask | null>(null);
	let due = $state('');
	let planned = $state('');
	let priority = $state(0);
	let frequency = $state<Frequency>('none');
	let interval = $state(1);
	let until = $state('');
	let reminders = $state<string[]>([]);
	let newReminder = $state('');
	let invalid = $state(false);

	const FREQUENCIES: Frequency[] = ['none', 'daily', 'weekly', 'monthly'];

	function adopt(pt: PlanningTask) {
		current = pt;
		due = toLocalInput(pt.dueAt);
		planned = toLocalInput(pt.plannedAt);
		priority = pt.priority;
		frequency = pt.recurrence?.frequency ?? 'none';
		interval = pt.recurrence?.interval ?? 1;
		until = toLocalInput(pt.recurrence?.until);
		reminders = [...pt.reminders];
		invalid = false;
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
		// Keep the stored time zone of an existing rule; new rules use the browser's.
		const recurrence = buildRecurrence(frequency, interval, until, current.recurrence?.timeZone);
		invalid = recurrenceNeedsDate(recurrence, due, planned);
		if (invalid) return;
		const ok = await attempt(async () => {
			adopt(
				await api.putPlanning(taskID, {
					dueAt: fromLocalInput(due),
					plannedAt: fromLocalInput(planned),
					priority,
					recurrence,
					reminders
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
		<Select
			id="prio-{taskID}"
			disabled={!current}
			bind:value={priority}
		>
			{#each PRIORITIES as p (p)}
				<option value={p}>{t(`planning.priority.${p}` as MessageKey)}</option>
			{/each}
		</Select>
	</div>
</div>
<fieldset class="mt-2 flex flex-wrap items-end gap-2" data-testid="recurrence-form">
	<legend class="text-sm font-medium">{t('planning.recurrence')}</legend>
	<Select
		
		aria-label={t('planning.recurrence.frequency')}
		disabled={!current}
		bind:value={frequency}
	>
		{#each FREQUENCIES as f (f)}
			<option value={f}>{t(`planning.recurrence.${f}` as MessageKey)}</option>
		{/each}
	</Select>
	{#if frequency !== 'none'}
		<div class="flex flex-col gap-1">
			<Label for="interval-{taskID}">{t('planning.recurrence.interval', { unit: t(`planning.recurrence.unit.${frequency}` as MessageKey) })}</Label>
			<Input id="interval-{taskID}" class="w-24" type="number" min="1" max="1000" bind:value={interval} />
		</div>
		<div class="flex flex-col gap-1">
			<Label for="until-{taskID}">{t('planning.recurrence.until')}</Label>
			<Input id="until-{taskID}" type="datetime-local" bind:value={until} />
		</div>
	{/if}
</fieldset>
{#if invalid}
	<p class="text-destructive mt-1 text-xs" role="alert" data-testid="recurrence-error">{t('planning.recurrence.needsDate')}</p>
{/if}

<div class="mt-2 flex flex-col gap-1" data-testid="reminders">
	<h4 class="text-sm font-medium">{t('planning.reminders')}</h4>
	{#if reminders.length === 0}<p class="text-muted-foreground text-xs">{t('planning.reminders.empty')}</p>{/if}
	<ul class="flex flex-wrap gap-1">
		{#each reminders as r (r)}
			<li class="bg-secondary flex items-center gap-1 rounded-full px-2 py-0.5 text-xs" data-testid="reminder">
				{formatWhen(r)}
				<button
					type="button"
					class="text-muted-foreground"
					aria-label={t('planning.reminders.remove', { when: formatWhen(r) })}
					onclick={() => (reminders = removeReminder(reminders, r))}>×</button
				>
			</li>
		{/each}
	</ul>
	<div class="flex gap-2">
		<Input
			type="datetime-local"
			class="max-w-60"
			aria-label={t('planning.reminders.new')}
			disabled={!current}
			bind:value={newReminder}
		/>
		<Button
			size="sm"
			variant="outline"
			disabled={!current || !fromLocalInput(newReminder)}
			onclick={() => {
				reminders = addReminder(reminders, newReminder);
				newReminder = '';
			}}>{t('planning.reminders.add')}</Button
		>
	</div>
	<p class="text-muted-foreground text-xs">{t('planning.reminders.hint')}</p>
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
			frequency = 'none';
			interval = 1;
			until = '';
			reminders = [];
		}}>{t('planning.clear')}</Button
	>
</div>
