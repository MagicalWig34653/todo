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
	import { onMount, type Snippet } from 'svelte';
	import Flag from '@lucide/svelte/icons/flag';
	import X from '@lucide/svelte/icons/x';
	import SideSection from './card/SideSection.svelte';
	import { priorityTag, priorityTone } from '#lib/planning.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { mergePlanning, planningForm, type PlanningField, type PlanningForm } from '#lib/planning-merge.js';

	const FIELD_LABELS: Record<PlanningField, MessageKey> = {
		due: 'planning.due',
		planned: 'planning.planned',
		priority: 'planning.priority',
		frequency: 'planning.recurrence',
		interval: 'planning.recurrence',
		until: 'planning.recurrence',
		reminders: 'planning.reminders'
	};

	/**
	 * `side`: the card detail sidebar layout (blocks with "+", every change saves at once); `between` is rendered
	 * between priority and reminders there (the labels block). Default: the form with one save button.
	 */
	let { taskID, onsaved, side = false, between }: { taskID: string; onsaved: () => unknown; side?: boolean; between?: Snippet } = $props();
	let editDate = $state(false);
	let editRecur = $state(false);
	let editRem = $state(false);

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
	let conflictText = $state('');

	const FREQUENCIES: Frequency[] = ['none', 'daily', 'weekly', 'monthly'];

	/** What the form was last synchronised with; the base for the three-way merge with newer server state. */
	let base: PlanningForm | null = null;

	const formNow = (): PlanningForm => ({ due, planned, priority, frequency, interval, until, reminders: [...reminders] });
	function apply(f: PlanningForm) {
		due = f.due;
		planned = f.planned;
		priority = f.priority;
		frequency = f.frequency as Frequency;
		interval = f.interval;
		until = f.until;
		reminders = [...f.reminders];
	}
	/** Replaces the whole form with the stored planning (first load, after a save). */
	function adopt(pt: PlanningTask) {
		current = pt;
		base = planningForm(pt);
		apply(base);
		invalid = false;
		conflictText = '';
	}
	/** Takes newer server state into untouched fields and keeps local edits; returns the fields changed on both sides. */
	function sync(pt: PlanningTask): PlanningField[] {
		if (!base) {
			adopt(pt);
			return [];
		}
		const merged = mergePlanning(base, formNow(), planningForm(pt));
		current = pt;
		base = merged.base;
		apply(merged.form);
		return merged.conflicts;
	}
	function announceConflicts(fields: PlanningField[]) {
		const names = [...new Set(fields.map((f) => t(FIELD_LABELS[f])))].join(', ');
		// Inline instead of the global notice: other loads on the page clear that one before it can be read.
		conflictText = t('planning.conflict', { fields: names });
	}

	/** Primitive on purpose: a list refresh hands in a new task object with the same id; only another id may reload the form. */
	const taskKey = $derived(taskID);
	let loadSeq = 0;
	async function load() {
		const my = ++loadSeq;
		// Reads the derived key, not the prop: load() runs inside the effect and must not subscribe it to the task object.
		const pt = await api.getPlanning(taskKey);
		// A newer load or a save superseded this answer: adopting it would overwrite what the user has entered since.
		if (my === loadSeq) adopt(pt);
	}
	$effect(() => {
		void taskKey;
		current = null;
		base = null;
		attempt(load);
	});

	/** Live refresh: merge what others saved into untouched fields (no guardEditing, the merge protects local edits). */
	async function refreshQuiet() {
		if (!current) return;
		const my = ++loadSeq;
		try {
			const pt = await api.getPlanning(taskKey);
			if (my !== loadSeq) return;
			const conflicts = sync(pt);
			if (conflicts.length > 0) announceConflicts(conflicts);
		} catch {
			/* silent refresh: keep what the form shows */
		}
	}
	onMount(() => startLiveRefresh(refreshQuiet));

	async function save() {
		if (!current) return;
		invalid = recurrenceNeedsDate(buildRecurrence(frequency, interval, until, current.recurrence?.timeZone), due, planned);
		if (invalid) return;
		const my = ++loadSeq;
		let held = false;
		let heldFields: PlanningField[] = [];
		const ok = await attempt(async () => {
			// Re-read first: fields untouched here follow what others saved meanwhile, and a field edited on both sides
			// is reported instead of silently overwritten (the planning route has no revision to check against).
			const conflicts = sync(await api.getPlanning(taskID));
			if (conflicts.length > 0) {
				held = true;
				heldFields = conflicts;
				return;
			}
			// Keep the stored time zone of an existing rule; new rules use the browser's.
			const recurrence = buildRecurrence(frequency, interval, until, current?.recurrence?.timeZone);
			invalid = recurrenceNeedsDate(recurrence, due, planned);
			if (invalid) {
				held = true;
				return;
			}
			const saved = await api.putPlanning(taskID, {
				dueAt: fromLocalInput(due),
				plannedAt: fromLocalInput(planned),
				priority,
				recurrence,
				reminders
			});
			if (my === loadSeq) adopt(saved);
		}, load);
		if (held) {
			if (heldFields.length > 0) announceConflicts(heldFields);
			return;
		}
		if (ok) await onsaved();
	}
</script>

{#if !side}
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
{#if conflictText}
	<p class="text-warning mt-1 text-xs" role="status" data-testid="planning-conflict">{conflictText}</p>
{/if}
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
{:else}
	<div class="flex flex-col" data-testid="planning-side">
		<SideSection title={t('card.side.date')} addLabel={t('card.side.dateEdit')} onadd={() => (editDate = !editDate)} active={editDate} testid="side-date">
			{#if due || planned}
				<ul class="flex flex-col gap-1">
					{#if due}<li class="flex items-center justify-between gap-2" data-testid="side-due"><span>{t('planning.due')}: {formatWhen(fromLocalInput(due))}</span><button type="button" class="text-muted-foreground hover:text-foreground hit-area relative inline-flex size-6 items-center justify-center" aria-label={t('card.side.clear', { name: t('planning.due') })} onclick={() => { due = ''; void save(); }}><X class="size-3.5" aria-hidden="true" /></button></li>{/if}
					{#if planned}<li class="flex items-center justify-between gap-2" data-testid="side-planned"><span>{t('planning.planned')}: {formatWhen(fromLocalInput(planned))}</span><button type="button" class="text-muted-foreground hover:text-foreground hit-area relative inline-flex size-6 items-center justify-center" aria-label={t('card.side.clear', { name: t('planning.planned') })} onclick={() => { planned = ''; void save(); }}><X class="size-3.5" aria-hidden="true" /></button></li>{/if}
				</ul>
			{/if}
			{#if editDate}
				<div class="flex flex-col gap-1">
					<Label for="due-{taskID}">{t('planning.due')}</Label>
					<Input id="due-{taskID}" type="datetime-local" disabled={!current} bind:value={due} onchange={() => void save()} />
				</div>
				<div class="flex flex-col gap-1">
					<Label for="planned-{taskID}">{t('planning.planned')}</Label>
					<Input id="planned-{taskID}" type="datetime-local" disabled={!current} bind:value={planned} onchange={() => void save()} />
				</div>
			{/if}
		</SideSection>

		<SideSection title={t('planning.priority')} testid="side-priority">
			<label class="flex min-h-8 items-center gap-2">
				<Flag class={['size-4 shrink-0', priorityTone(priority)]} aria-hidden="true" />
				<Select
					class="min-w-0 flex-1 [&_select]:border-transparent [&_select]:bg-transparent [&_select]:px-1 [&_select]:shadow-none"
					aria-label={t('planning.priority')}
					disabled={!current}
					value={priority}
					onchange={(e) => { priority = Number(e.currentTarget.value); void save(); }}
					data-testid="side-priority-select"
				>
					{#each PRIORITIES as p (p)}
						<option value={p}>{priorityTag(p)} · {t(`planning.priority.${p}` as MessageKey)}</option>
					{/each}
				</Select>
			</label>
		</SideSection>

		{@render between?.()}

		<SideSection title={t('planning.reminders')} addLabel={t('card.side.reminderAdd')} onadd={() => (editRem = !editRem)} active={editRem} testid="side-reminders">
			{#if reminders.length > 0}
				<ul class="flex flex-wrap gap-1">
					{#each reminders as r (r)}
						<li class="bg-secondary flex items-center gap-1 rounded-full py-0.5 pr-1 pl-2.5 text-xs" data-testid="reminder">
							{formatWhen(r)}
							<button type="button" class="text-muted-foreground hover:text-foreground hit-area relative inline-flex size-5 items-center justify-center" aria-label={t('planning.reminders.remove', { when: formatWhen(r) })} onclick={() => { reminders = removeReminder(reminders, r); void save(); }}><X class="size-3" aria-hidden="true" /></button>
						</li>
					{/each}
				</ul>
			{/if}
			{#if editRem}
				<div class="flex flex-wrap items-center gap-2">
					<Input type="datetime-local" class="min-w-0 flex-1" aria-label={t('planning.reminders.new')} disabled={!current} bind:value={newReminder} />
					<Button size="sm" variant="outline" disabled={!current || !fromLocalInput(newReminder)} onclick={() => { reminders = addReminder(reminders, newReminder); newReminder = ''; void save(); }}>{t('planning.reminders.add')}</Button>
				</div>
				<p class="text-muted-foreground text-xs">{t('planning.reminders.hint')}</p>
			{/if}
		</SideSection>

		<SideSection title={t('planning.recurrence')} addLabel={t('card.side.recurrenceEdit')} onadd={() => (editRecur = !editRecur)} active={editRecur} testid="side-recurrence">
			{#if frequency !== 'none'}
				<p data-testid="side-recurrence-value">{t(`planning.recurrence.${frequency}` as MessageKey)}{interval > 1 ? ` · ${t('planning.recurrence.interval', { unit: t(`planning.recurrence.unit.${frequency}` as MessageKey) })} ${interval}` : ''}</p>
			{/if}
			{#if editRecur}
				<div class="flex flex-col gap-2" data-testid="recurrence-form">
					<Select aria-label={t('planning.recurrence.frequency')} disabled={!current} value={frequency} onchange={(e) => { frequency = e.currentTarget.value as Frequency; void save(); }}>
						{#each FREQUENCIES as f (f)}
							<option value={f}>{t(`planning.recurrence.${f}` as MessageKey)}</option>
						{/each}
					</Select>
					{#if frequency !== 'none'}
						<div class="flex flex-col gap-1">
							<Label for="interval-{taskID}">{t('planning.recurrence.interval', { unit: t(`planning.recurrence.unit.${frequency}` as MessageKey) })}</Label>
							<Input id="interval-{taskID}" class="w-24" type="number" min="1" max="1000" bind:value={interval} onchange={() => void save()} />
						</div>
						<div class="flex flex-col gap-1">
							<Label for="until-{taskID}">{t('planning.recurrence.until')}</Label>
							<Input id="until-{taskID}" type="datetime-local" bind:value={until} onchange={() => void save()} />
						</div>
					{/if}
				</div>
			{/if}
		</SideSection>
		{#if conflictText}
			<p class="text-warning pt-2 text-xs" role="status" data-testid="planning-conflict">{conflictText}</p>
		{/if}
		{#if invalid}
			<p class="text-destructive pt-2 text-xs" role="alert" data-testid="recurrence-error">{t('planning.recurrence.needsDate')}</p>
		{/if}
	</div>
{/if}
