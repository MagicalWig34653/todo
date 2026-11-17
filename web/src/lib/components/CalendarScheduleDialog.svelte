<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { berlinParts, entryMinutes, formPatch, toBerlinInput, type ScheduleEntry, type SchedulePatch } from '#lib/calendar.js';
	import type { PlanningTask } from '#lib/api.js';
	import Dialog from './app/Dialog.svelte';
	import AutoStartToggle from './AutoStartToggle.svelte';
	import { Button } from '#lib/components/ui/button/index.js';

	/** "Start und Dauer": keyboard and screen reader alternative to dragging (ADR 0033). Times are Berlin wall clock. */
	let {
		entry,
		onsave,
		onopencard,
		onclose,
		onautostart
	}: {
		entry: ScheduleEntry;
		onsave: (patch: SchedulePatch) => void;
		onopencard: () => void;
		onclose: () => void;
		onautostart?: (pt: PlanningTask) => unknown;
	} = $props();

	function defaultStart(): string {
		const p = berlinParts(new Date());
		const h = Math.min(23, p.h + 1);
		return `${p.y}-${String(p.m).padStart(2, '0')}-${String(p.d).padStart(2, '0')}T${String(h).padStart(2, '0')}:00`;
	}
	// The dialog edits a snapshot of the card it was opened for.
	/* svelte-ignore state_referenced_locally */
	let open = $state(true);
	/* svelte-ignore state_referenced_locally */
	let start = $state(toBerlinInput(entry.plannedAt) || defaultStart());
	/* svelte-ignore state_referenced_locally */
	let minutes = $state(entry.plannedAt ? String(entryMinutes(entry)) : '30');
	/* svelte-ignore state_referenced_locally */
	let allDay = $state(entry.plannedAllDay);
	let invalid = $state(false);

	// Closing in any way (Escape, backdrop, buttons) tells the parent once.
	$effect(() => {
		if (!open) onclose();
	});

	function save(e: Event) {
		e.preventDefault();
		const patch = formPatch(entry, { start, minutes: String(minutes ?? ''), allDay });
		invalid = patch === null;
		if (patch) {
			onsave(patch);
			open = false;
		}
	}
	const field = 'border-input bg-background focus-visible:ring-ring mt-1 block min-h-9 w-full rounded-lg border px-2.5 text-sm focus-visible:ring-2 focus-visible:outline-none';
</script>

<Dialog bind:open title={t('calendar.dialog.title')} class="max-w-md" testid="calendar-dialog">
	<form class="flex flex-col gap-3" onsubmit={save}>
		<p class="text-sm font-medium break-words">{entry.title}</p>
		<label class="text-sm" for="cal-start">{t('calendar.dialog.start')}
			<input id="cal-start" type="datetime-local" class={field} bind:value={start} required />
		</label>
		<label class="flex items-center gap-2 text-sm" for="cal-allday">
			<input id="cal-allday" type="checkbox" class="size-4" bind:checked={allDay} />{t('calendar.dialog.allDay')}
		</label>
		{#if !allDay}
			<label class="text-sm" for="cal-minutes">{t('calendar.dialog.minutes')}
				<input id="cal-minutes" type="number" min="5" max="1440" step="5" class={field} bind:value={minutes} />
			</label>
		{/if}
		<AutoStartToggle
			taskID={entry.taskID}
			projectID={entry.projectID}
			version={entry.version}
			status={entry.status}
			plannedAt={entry.plannedAt}
			plannedAllDay={entry.plannedAllDay}
			autoStart={entry.autoStart}
			onchanged={onautostart}
		/>
		{#if invalid}<p class="text-destructive text-sm" role="alert">{t('calendar.dialog.invalid')}</p>{/if}
		<div class="flex flex-wrap items-center gap-2">
			<Button type="submit" data-testid="calendar-dialog-save">{t('calendar.dialog.save')}</Button>
			{#if entry.plannedAt}
				<Button type="button" variant="outline" data-testid="calendar-dialog-remove" onclick={() => { onsave({ plannedAt: null }); open = false; }}>{t('calendar.dialog.remove')}</Button>
			{/if}
			<Button type="button" variant="ghost" onclick={() => { open = false; onopencard(); }}>{t('calendar.open')}</Button>
			<Button type="button" variant="ghost" onclick={() => (open = false)}>{t('calendar.dialog.cancel')}</Button>
		</div>
	</form>
</Dialog>
