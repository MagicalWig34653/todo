<script lang="ts">
	import { Select } from '#lib/components/ui/select/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { cn } from '#lib/utils.js';
	import type { Frequency } from '#lib/planning.js';
	import { WEEKDAYS, extrasForFrequency, toggleWeekday, type RecurrenceBasis } from '#lib/recurrence.js';

	/**
	 * The editable fields of a recurrence rule (frequency, interval, weekdays for weekly, day of the month for monthly,
	 * basis, end). Shared by the planning form and the card detail sidebar; `onchange` is the sidebar's "save at once".
	 * Fields that do not fit a newly chosen frequency are discarded.
	 */
	let {
		taskID,
		disabled = false,
		frequency = $bindable('none'),
		interval = $bindable(1),
		until = $bindable(''),
		weekdays = $bindable([]),
		basis = $bindable('due'),
		monthDay = $bindable(null),
		onchange,
		class: className
	}: {
		taskID: string;
		disabled?: boolean;
		frequency: Frequency;
		interval: number;
		until: string;
		weekdays: number[];
		basis: RecurrenceBasis;
		monthDay: number | null;
		onchange?: () => void;
		class?: string;
	} = $props();

	const FREQUENCIES: Frequency[] = ['none', 'daily', 'weekly', 'monthly'];
	const BASES: RecurrenceBasis[] = ['due', 'completion'];

	function setFrequency(next: Frequency) {
		const fit = extrasForFrequency(next, { weekdays, basis, monthDay });
		frequency = next;
		weekdays = fit.weekdays;
		basis = fit.basis;
		monthDay = fit.monthDay;
		onchange?.();
	}
	function toggle(day: number) {
		weekdays = toggleWeekday(weekdays, day);
		onchange?.();
	}
</script>

<div class={className}>
	<Select aria-label={t('planning.recurrence.frequency')} {disabled} value={frequency} onchange={(e) => setFrequency(e.currentTarget.value as Frequency)}>
		{#each FREQUENCIES as f (f)}
			<option value={f}>{t(`planning.recurrence.${f}` as MessageKey)}</option>
		{/each}
	</Select>
	{#if frequency !== 'none'}
		<div class="flex flex-col gap-1">
			<Label for="interval-{taskID}">{t('planning.recurrence.interval', { unit: t(`planning.recurrence.unit.${frequency}` as MessageKey) })}</Label>
			<Input id="interval-{taskID}" class="w-24" type="number" min="1" max="1000" bind:value={interval} onchange={() => onchange?.()} />
		</div>
		{#if frequency === 'weekly'}
			<div class="flex basis-full flex-col gap-1" data-testid="recurrence-weekdays">
				<span class="text-sm font-medium" id="weekdays-label-{taskID}">{t('planning.recurrence.weekdays')}</span>
				<div class="flex flex-wrap gap-1" role="group" aria-labelledby="weekdays-label-{taskID}">
					{#each WEEKDAYS as day (day)}
						{@const on = weekdays.includes(day)}
						<button
							type="button"
							class={cn(
								'hit-area relative inline-flex h-8 min-w-9 items-center justify-center rounded-lg border px-2 text-sm font-medium outline-none transition-colors focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40 disabled:opacity-50',
								on ? 'border-ui-accent bg-ui-accent text-ui-accent-foreground' : 'border-border bg-background hover:bg-muted'
							)}
							aria-pressed={on}
							aria-label={t(`planning.recurrence.weekdayLong.${day}` as MessageKey)}
							data-testid="weekday-{day}"
							{disabled}
							onclick={() => toggle(day)}
						>
							{t(`planning.recurrence.weekdayShort.${day}` as MessageKey)}
						</button>
					{/each}
				</div>
				<p class="text-muted-foreground text-xs">{t('planning.recurrence.weekdaysHint')}</p>
			</div>
		{/if}
		{#if frequency === 'monthly'}
			<div class="flex basis-full flex-col gap-1">
				<Label for="monthday-{taskID}">{t('planning.recurrence.monthDay')}</Label>
				<Input id="monthday-{taskID}" class="w-24" type="number" min="1" max="31" aria-describedby="monthday-hint-{taskID}" bind:value={monthDay} onchange={() => onchange?.()} />
				<p class="text-muted-foreground text-xs" id="monthday-hint-{taskID}">{t('planning.recurrence.monthDayHint')}</p>
			</div>
		{/if}
		<div class="flex flex-col gap-1">
			<Label for="basis-{taskID}">{t('planning.recurrence.basis')}</Label>
			<Select id="basis-{taskID}" {disabled} value={basis} onchange={(e) => { basis = e.currentTarget.value as RecurrenceBasis; onchange?.(); }}>
				{#each BASES as b (b)}
					<option value={b}>{t(`planning.recurrence.basis.${b}` as MessageKey)}</option>
				{/each}
			</Select>
		</div>
		<div class="flex flex-col gap-1">
			<Label for="until-{taskID}">{t('planning.recurrence.until')}</Label>
			<Input id="until-{taskID}" type="datetime-local" bind:value={until} onchange={() => onchange?.()} />
		</div>
	{/if}
</div>
