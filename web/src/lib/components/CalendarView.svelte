<script lang="ts">
	import { onMount, tick, untrack } from 'svelte';
	import { api, type PlanningTask } from '#lib/api.js';
	import { can, roleOf } from '#lib/access.js';
	import {
		applyPatch, canDrag, civilKey, civilOf, commitSchedule, conflictLabels, dayEntries, dayStart, describeEntry, dropPlan, entryEnd, entryStart,
		formatDayHeading, formatTime, keyPlan, layoutDay, monthTitle, sameDay, scheduleErrorKey, shiftAnchor, unscheduledEntry, visibleRange,
		type CalendarView, type CivilDay, type DropTarget, type ScheduleEntry, type SchedulePatch, type UndoStep, monthGrid, berlinParts
	} from '#lib/calendar.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { formatTimestamp } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import PageHeader from './app/PageHeader.svelte';
	import Timestamp from './Timestamp.svelte';
	import CalendarScheduleDialog from './CalendarScheduleDialog.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';

	const HOUR_H = 48;
	const MIN_H = 20;
	/** Blocks with a conflict or read-only line need a second text line even for short cards. */
	const MIN_H_MARKED = 36;
	const HOURS = Array.from({ length: 24 }, (_, i) => i);
	const MONTH_LIMIT = 3;

	let view = $state<CalendarView>('week');
	let anchor = $state(new Date());
	let entries = $state<ScheduleEntry[]>([]);
	/** Cards without a start; the role comes from the project list, which may arrive after the first load. */
	let openTasks = $state<PlanningTask[]>([]);
	let moved = $state<ScheduleEntry[]>([]);
	const unscheduled = $derived([
		...openTasks
			.filter((pt) => !moved.some((m) => m.taskID === pt.task.id))
			.map((pt) => {
				const project = workspace.projects.find((p) => p.id === pt.task.projectID);
				return unscheduledEntry(pt, project ? can(roleOf(project), 'editTask') : false);
			}),
		...moved
	]);
	let truncated = $state(false);
	let loaded = $state(false);
	let loadFailed = $state(false);
	let status = $state('');
	let error = $state('');
	let undo = $state<UndoStep | null>(null);
	let dialogEntry = $state<ScheduleEntry | null>(null);
	let dropOver = $state<string | null>(null);
	let gridEl = $state<HTMLElement | null>(null);
	let scroller = $state<HTMLElement | null>(null);

	const range = $derived(visibleRange(view, anchor));
	const today = $derived(civilOf(new Date()));
	const weekCols = $derived(
		range.days.map((day) => {
			const r = dayEntries(entries, day);
			return { day, allDay: r.allDay, due: r.due, placed: layoutDay(r.timed, day) };
		})
	);
	const monthWeeks = $derived(monthGrid(anchor).map((week) => week.map((day) => ({ day, ...dayEntries(entries, day) }))));
	const title = $derived(
		view === 'month' ? monthTitle(anchor) : `${formatDayHeading(range.days[0])} bis ${formatDayHeading(range.days[6])}`
	);

	let seq = 0;
	let dragging = false;
	async function load() {
		const mine = ++seq;
		const r = range;
		try {
			const [sched, open] = await Promise.all([api.schedule(r.from.toISOString(), r.to.toISOString()), api.unscheduled()]);
			if (mine !== seq) return;
			entries = sched.items;
			truncated = sched.truncated;
			openTasks = open;
			moved = [];
			loadFailed = false;
		} catch {
			if (mine === seq) loadFailed = true;
		} finally {
			if (mine === seq) loaded = true;
		}
	}
	const refresh = () => (dragging || pending > 0 ? undefined : load());

	$effect(() => {
		void range.from.getTime();
		void view;
		untrack(() => {
			error = '';
			void load();
		});
	});
	onMount(() => startLiveRefresh(refresh, { guardEditing: true }));
	$effect(() => {
		if (scroller && view === 'week' && loaded && !scroller.dataset.scrolled) {
			scroller.dataset.scrolled = '1';
			scroller.scrollTop = HOUR_H * 7;
		}
	});

	// Writes run one after the other: every keypress uses the version the previous one returned.
	let chain: Promise<void> = Promise.resolve();
	let pending = 0;
	const versions = new Map<string, number>();
	const find = (id: string) => entries.find((e) => e.taskID === id) ?? unscheduled.find((e) => e.taskID === id);
	function place(e: ScheduleEntry) {
		entries = entries.filter((x) => x.taskID !== e.taskID);
		moved = moved.filter((x) => x.taskID !== e.taskID);
		openTasks = openTasks.filter((x) => x.task.id !== e.taskID);
		if (e.plannedAt) entries = [...entries, e];
		else moved = [...moved, e];
	}
	function apply(entry: ScheduleEntry, patch: SchedulePatch) {
		const before = find(entry.taskID) ?? entry;
		const next = applyPatch(before, patch);
		place(next);
		error = '';
		pending++;
		chain = chain.then(async () => {
			const r = await commitSchedule((id, body) => api.scheduleTask(id, body), { ...before, version: versions.get(before.taskID) ?? before.version }, patch);
			if (r.ok) {
				versions.set(before.taskID, r.undo.version);
				undo = r.undo;
				status = patch.plannedAt === null ? t('calendar.removed', { title: before.title }) : t('calendar.moved', { text: describeEntry(next) });
			} else {
				place(before);
				undo = null;
				error = t(r.key ?? 'calendar.error.generic');
			}
			pending--;
			if (pending === 0) {
				versions.clear();
				await load();
			}
			void refocus(before.taskID);
		});
	}
	async function refocus(id: string) {
		await tick();
		gridEl?.querySelector<HTMLElement>(`[data-card="${id}"]`)?.focus();
	}
	async function doUndo() {
		const u = undo;
		if (!u) return;
		undo = null;
		error = '';
		try {
			await api.scheduleTask(u.taskID, { version: u.version, ...u.patch });
			status = t('calendar.undone');
		} catch (e) {
			error = t(scheduleErrorKey(e) ?? 'calendar.error.generic');
		}
		await load();
	}

	// ---- drag and drop
	let drag: { entry: ScheduleEntry; grab: number } | null = null;
	function dragStart(ev: DragEvent, entry: ScheduleEntry) {
		if (!canDrag(entry) || !ev.dataTransfer) return ev.preventDefault();
		ev.dataTransfer.setData('text/plain', entry.taskID);
		ev.dataTransfer.effectAllowed = 'move';
		const el = ev.currentTarget as HTMLElement;
		const rect = el.getBoundingClientRect();
		drag = { entry, grab: el.dataset.block ? Math.max(0, ((ev.clientY - rect.top) / HOUR_H) * 60) : 0 };
		dragging = true;
	}
	function dragEnd() {
		drag = null;
		dragging = false;
		dropOver = null;
	}
	function over(ev: DragEvent, id: string) {
		if (!drag) return;
		ev.preventDefault();
		if (ev.dataTransfer) ev.dataTransfer.dropEffect = 'move';
		dropOver = id;
	}
	function drop(ev: DragEvent, target: DropTarget) {
		ev.preventDefault();
		const d = drag;
		dragEnd();
		if (!d) return;
		const plan = dropPlan(target, d.entry);
		if (plan) apply(d.entry, plan);
	}
	function dropSlot(ev: DragEvent, day: CivilDay) {
		const rect = (ev.currentTarget as HTMLElement).getBoundingClientRect();
		const minutes = ((ev.clientY - rect.top) / HOUR_H) * 60 - (drag?.grab ?? 0);
		drop(ev, { kind: 'slot', day, minutes });
	}

	function onKey(ev: KeyboardEvent, entry: ScheduleEntry) {
		if (ev.key === 'Enter') {
			ev.preventDefault();
			if (canDrag(entry)) dialogEntry = entry;
			else openCard(entry);
			return;
		}
		const patch = keyPlan(entry, ev.key, ev.shiftKey);
		if (!patch) return;
		ev.preventDefault();
		apply(entry, patch);
	}
	const openCard = (e: ScheduleEntry) => cardDetail.open({ type: 'task', id: e.taskID });
	const colorOf = (e: ScheduleEntry) => workspace.colorOf(e.projectID);

	const btn = 'focus-visible:ring-ring rounded-md focus-visible:ring-2 focus-visible:outline-none';
	const heading = (day: CivilDay) => formatDayHeading(day);
	const dayLabel = (day: CivilDay) => t('calendar.dropDay', { day: heading(day) });
	const todayAttr = (day: CivilDay) => (sameDay(day, today) ? 'date' : undefined);
	const timeRange = (e: ScheduleEntry) => `${formatTime(entryStart(e)!)} bis ${formatTime(entryEnd(e))}`;
</script>

{#snippet card(e: ScheduleEntry, cls: string, style = '')}
	<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
	<div
		role="button"
		tabindex="0"
		draggable={canDrag(e)}
		data-card={e.taskID}
		data-testid="calendar-card"
		data-draggable={canDrag(e)}
		data-block={style ? '1' : undefined}
		aria-label={describeEntry(e)}
		aria-keyshortcuts="Enter ArrowUp ArrowDown ArrowLeft ArrowRight"
		title={e.dueAt ? `${describeEntry(e)}. ${t('planning.due')}: ${formatTimestamp(e.dueAt)}` : describeEntry(e)}
		class={[cls, btn, 'bg-ui-accent-soft text-ui-accent-ink border-l-4 text-left text-xs', e.status === 'done' && 'opacity-60', canDrag(e) ? 'cursor-grab' : 'cursor-default']}
		style="border-left-color: {colorOf(e)}; {style}"
		ondragstart={(ev) => dragStart(ev, e)}
		ondragend={dragEnd}
		onkeydown={(ev) => onKey(ev, e)}
		onclick={() => openCard(e)}
	>
		<span class={['block truncate font-medium', e.status === 'done' && 'line-through']}>{e.title}</span>
		{@render marks(e)}
	</div>
{/snippet}

{#snippet marks(e: ScheduleEntry)}
	{#if e.conflicts.length}
		<span class="text-warning flex items-center gap-1 font-medium" data-testid="calendar-conflict"><TriangleAlert class="size-3 shrink-0" aria-hidden="true" /><span class="truncate">{conflictLabels(e).join(', ')}</span></span>
	{/if}
	{#if e.blocked}<span class="text-muted-foreground block truncate">{t('calendar.blocked')}</span>{/if}
	{#if !e.canEdit}<span class="text-muted-foreground block truncate">{t('calendar.readOnly')}</span>{/if}
{/snippet}

<section class="flex flex-col gap-3" data-testid="calendar-view">
	<PageHeader title={t('nav.calendar')} description={t('calendar.hint')} testid="view-heading" />

	<div class="flex flex-wrap items-center gap-2" role="toolbar" aria-label={t('calendar.nav')}>
		<Button variant="outline" size="icon-sm" aria-label={t('calendar.prev')} data-testid="calendar-prev" onclick={() => (anchor = shiftAnchor(view, anchor, -1))}><ChevronLeft aria-hidden="true" /></Button>
		<Button variant="outline" size="sm" data-testid="calendar-today" onclick={() => (anchor = new Date())}>{t('calendar.today')}</Button>
		<Button variant="outline" size="icon-sm" aria-label={t('calendar.next')} data-testid="calendar-next" onclick={() => (anchor = shiftAnchor(view, anchor, 1))}><ChevronRight aria-hidden="true" /></Button>
		<h3 class="order-last min-w-0 basis-full text-base font-semibold sm:order-none sm:flex-1 sm:basis-auto" data-testid="calendar-title" aria-live="polite">{title}</h3>
		<div class="flex gap-1" role="group" aria-label={t('calendar.views')}>
			{#each ['week', 'month'] as const as v (v)}
				<Button variant={view === v ? 'secondary' : 'outline'} size="sm" aria-pressed={view === v} data-testid="calendar-view-{v}" onclick={() => (view = v)}>{t(`calendar.view.${v}`)}</Button>
			{/each}
		</div>
	</div>

	<div class="min-h-6 text-sm" data-testid="calendar-status">
		<p class="sr-only" role="status" aria-live="polite" data-testid="calendar-live">{status}</p>
		{#if error}<p class="text-destructive" role="alert" data-testid="calendar-error">{error}</p>{/if}
		{#if undo}
			<p class="flex flex-wrap items-center gap-2" data-testid="calendar-undo-bar">
				<span class="text-muted-foreground">{status}</span>
				<Button size="xs" variant="outline" data-testid="calendar-undo" onclick={doUndo}>{t('calendar.undo')}</Button>
			</p>
		{/if}
		{#if truncated}<p class="text-warning" role="status">{t('calendar.truncated')}</p>{/if}
		{#if loadFailed}<p class="text-destructive" role="alert">{t('calendar.loadFailed')}</p>{/if}
	</div>
	<p class="text-muted-foreground text-xs">{t('calendar.keys')}</p>

	<div class="flex flex-col gap-4 lg:flex-row lg:items-start">
		<div class="min-w-0 flex-1" bind:this={gridEl} aria-busy={!loaded}>
			{#if view === 'week'}
				<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
				<div class="bg-card max-h-[70vh] overflow-auto rounded-xl border" bind:this={scroller} role="region" aria-label={t('calendar.gridLabel', { from: heading(range.days[0]), to: heading(range.days[6]) })} tabindex="0" data-testid="calendar-week">
					<div class="bg-card sticky top-0 z-10 border-b" style="min-width: 36rem">
						<div class="grid" style="grid-template-columns: 3.5rem repeat(7, minmax(4.5rem, 1fr))">
							<div></div>
							{#each weekCols as col (civilKey(col.day))}
								<div class="border-l px-1.5 py-1 text-center text-xs font-semibold" aria-current={todayAttr(col.day)} data-testid="calendar-day-head">{heading(col.day)}</div>
							{/each}
							<div class="text-muted-foreground px-1 py-1 text-[11px]">{t('calendar.allDay')}</div>
							{#each weekCols as col (civilKey(col.day))}
								<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
								<div
									role="group"
									aria-label={t('calendar.dropAllDay', { day: heading(col.day) })}
									class={['bg-muted/30 flex min-h-8 flex-col gap-0.5 border-l p-0.5', dropOver === `a${civilKey(col.day)}` && 'bg-ui-accent-soft']}
									data-testid="calendar-allday"
									data-day={civilKey(col.day)}
									ondragover={(ev) => over(ev, `a${civilKey(col.day)}`)}
									ondragleave={() => (dropOver = null)}
									ondrop={(ev) => drop(ev, { kind: 'allDay', day: col.day })}
								>
									{#each col.allDay as e (e.taskID)}{@render card(e, 'rounded px-1 py-0.5')}{/each}
								</div>
							{/each}
						</div>
					</div>
					<div class="grid" style="grid-template-columns: 3.5rem repeat(7, minmax(4.5rem, 1fr)); min-width: 36rem">
						<div aria-hidden="true">
							{#each HOURS as h (h)}<div class="text-muted-foreground pr-1 text-right text-[11px]" style="height: {HOUR_H}px">{String(h).padStart(2, '0')}:00</div>{/each}
						</div>
						{#each weekCols as col (civilKey(col.day))}
							<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
							<div
								role="group"
								aria-label={dayLabel(col.day)}
								class={['relative border-l', dropOver === `s${civilKey(col.day)}` && 'bg-ui-accent-soft/50']}
								style="height: {HOUR_H * 24}px; background-image: repeating-linear-gradient(to bottom, transparent 0, transparent {HOUR_H - 1}px, var(--color-border, #e5e5e5) {HOUR_H - 1}px, var(--color-border, #e5e5e5) {HOUR_H}px)"
								data-testid="calendar-day"
								data-day={civilKey(col.day)}
								ondragover={(ev) => over(ev, `s${civilKey(col.day)}`)}
								ondragleave={() => (dropOver = null)}
								ondrop={(ev) => dropSlot(ev, col.day)}
							>
								{#each col.due as e (e.taskID)}
									{@const m = berlinParts(new Date(e.dueAt!))}
									<div class="border-destructive text-destructive pointer-events-none absolute inset-x-0 z-[1] border-t border-dashed text-[10px] leading-none" style="top: {((m.h * 60 + m.min) / 60) * HOUR_H}px" data-testid="calendar-due" title={formatTimestamp(e.dueAt)}>{t('calendar.dueMark', { title: e.title })}</div>
								{/each}
								{#each col.placed as p (p.entry.taskID)}
									{@render card(p.entry, 'absolute overflow-hidden rounded px-1 py-0.5 shadow-sm z-[2]', `top: ${(p.startMin / 60) * HOUR_H}px; height: ${Math.max(p.entry.conflicts.length || !p.entry.canEdit ? MIN_H_MARKED : MIN_H, ((p.endMin - p.startMin) / 60) * HOUR_H - 1)}px; left: ${(p.col / p.cols) * 100}%; width: calc(${100 / p.cols}% - 2px)`)}
								{/each}
							</div>
						{/each}
					</div>
				</div>
			{:else}
				<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
				<div class="bg-card overflow-x-auto rounded-xl border" data-testid="calendar-month" role="region" aria-label={title} tabindex="0">
					<div class="grid grid-cols-7" style="min-width: 40rem">
						{#each range.days.slice(0, 7) as day (civilKey(day))}
							<div class="border-b px-1.5 py-1 text-center text-xs font-semibold">{new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', weekday: 'short' }).format(dayStart(day))}</div>
						{/each}
						{#each monthWeeks as week (civilKey(week[0].day))}
							{#each week as cell (civilKey(cell.day))}
								{@const other = berlinParts(dayStart(cell.day)).m !== berlinParts(anchor).m}
								<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
								<div
									role="group"
									aria-label={t('calendar.dropAllDay', { day: heading(cell.day) })}
									class={['flex min-h-24 flex-col gap-0.5 border-t border-l p-1', other && 'bg-muted/40', dropOver === `m${civilKey(cell.day)}` && 'bg-ui-accent-soft']}
									data-testid="calendar-month-cell"
									data-day={civilKey(cell.day)}
									ondragover={(ev) => over(ev, `m${civilKey(cell.day)}`)}
									ondragleave={() => (dropOver = null)}
									ondrop={(ev) => drop(ev, { kind: 'allDay', day: cell.day })}
								>
									<span class={['text-xs', sameDay(cell.day, today) ? 'text-ui-accent-ink font-bold' : 'text-muted-foreground']} aria-current={todayAttr(cell.day)}>{cell.day.d}</span>
									{#each [...cell.allDay, ...cell.timed].slice(0, MONTH_LIMIT) as e (e.taskID)}
										{@render card(e, 'rounded px-1 py-0.5')}
									{/each}
									{#if cell.allDay.length + cell.timed.length > MONTH_LIMIT}
										<span class="text-muted-foreground text-[11px]">{t('calendar.more', { count: cell.allDay.length + cell.timed.length - MONTH_LIMIT })}</span>
									{/if}
									{#each cell.due as e (e.taskID)}
										<span class="text-destructive truncate text-[11px]" data-testid="calendar-due" title={formatTimestamp(e.dueAt)}>{t('calendar.dueMark', { title: e.title })}</span>
									{/each}
								</div>
							{/each}
						{/each}
					</div>
				</div>
			{/if}
		</div>

		<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
		<aside
			class={['bg-card w-full shrink-0 rounded-xl border p-3 lg:w-72', dropOver === 'side' && 'ring-ui-accent ring-2']}
			aria-labelledby="calendar-side-title"
			data-testid="calendar-sidebar"
			ondragover={(ev) => over(ev, 'side')}
			ondragleave={() => (dropOver = null)}
			ondrop={(ev) => drop(ev, { kind: 'unscheduled' })}
		>
			<h3 id="calendar-side-title" class="text-sm font-semibold">{t('calendar.sidebar.title')} <span class="text-muted-foreground font-normal" data-tabular>({unscheduled.length})</span></h3>
			<p class="text-muted-foreground mt-1 mb-2 text-xs">{t('calendar.sidebar.hint')}</p>
			{#if loaded && unscheduled.length === 0}<p class="text-muted-foreground text-sm">{t('calendar.sidebar.empty')}</p>{/if}
			<ul class="flex max-h-[60vh] flex-col gap-1.5 overflow-y-auto">
				{#each unscheduled as e (e.taskID)}
					<li>
						{@render card(e, 'rounded-lg px-2 py-1.5')}
						{#if e.dueAt}<span class="text-muted-foreground block px-2 text-[11px]"><Timestamp value={e.dueAt} label="planning.due" /></span>{/if}
					</li>
				{/each}
			</ul>
		</aside>
	</div>
</section>

{#if dialogEntry}
	<CalendarScheduleDialog
		entry={dialogEntry}
		onsave={(patch) => dialogEntry && apply(dialogEntry, patch)}
		onopencard={() => dialogEntry && openCard(dialogEntry)}
		onclose={() => (dialogEntry = null)}
	/>
{/if}
