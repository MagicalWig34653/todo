<script lang="ts">
	import { api, type BoardResponse, type ProjectColumn, type Project, type Task, type TaskStatus } from '#lib/api.js';
	import { applyMove, PROJECT_COLORS, reorderKeys, snippet, toLanes, type Lane } from '#lib/boardLogic.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen, isOverdue, STATUSES } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Dialog from './app/Dialog.svelte';
	import MenuItem from './app/MenuItem.svelte';
	import Popover from './app/Popover.svelte';
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import Check from '@lucide/svelte/icons/check';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import GripVertical from '@lucide/svelte/icons/grip-vertical';
	import Plus from '@lucide/svelte/icons/plus';
	import Repeat from '@lucide/svelte/icons/repeat';
	import Tag from '@lucide/svelte/icons/tag';

	interface Props {
		project: Project;
		board: BoardResponse;
		/** Tasks of the project with planning summary (the board endpoint does not carry it). */
		tasks: Task[];
		labelsByTask: Record<string, string[]>;
		showDone: boolean;
		reload: () => Promise<void>;
		onopen: (task: Task) => void;
	}
	let { project, board, tasks, labelsByTask, showDone, reload, onopen }: Props = $props();

	let lanes = $state<Lane[]>([]);
	$effect(() => {
		lanes = toLanes(board);
	});

	const real = $derived(board.mode === 'columns');
	const realLanes = $derived(lanes.filter((l) => l.id));
	const planningOf = (task: Task) => tasks.find((x) => x.id === task.id)?.planning ?? task.planning;
	const visible = (lane: Lane) => (showDone ? lane.tasks : lane.tasks.filter((x) => x.status !== 'done'));
	const laneTitle = (lane: Lane) => (lane.laneKey === 'none' ? t('board.noColumn') : lane.name);
	const laneAdd = (lane: Lane) => real || lane.key === 'open';

	// ---- serialised server calls (keeps task versions in order) ------------------------------------------------
	let queue: Promise<unknown> = Promise.resolve();
	const enqueue = <T,>(fn: () => Promise<T>): Promise<T> => {
		const next = queue.then(fn, fn);
		queue = next.catch(() => undefined);
		return next;
	};

	// ---- moving tasks -----------------------------------------------------------------------------------------
	/** `index` counts the visible cards of the target lane without the moved card; it is mapped to the full lane here. */
	async function moveTask(taskID: string, toKey: string, visibleIndex: number) {
		const to = lanes.find((l) => l.laneKey === toKey);
		const from = lanes.find((l) => l.tasks.some((x) => x.id === taskID));
		if (!to || !from || !real) return;
		const others = visible(to).filter((x) => x.id !== taskID);
		const fullOthers = to.tasks.filter((x) => x.id !== taskID);
		const index = visibleIndex < others.length ? fullOthers.indexOf(others[visibleIndex]) : fullOthers.length;
		const before = lanes;
		const task = from.tasks.find((x) => x.id === taskID)!;
		const next = applyMove(lanes, taskID, toKey, index);
		if (next === before) return;
		lanes = next;
		const ok = await attempt(
			() =>
				enqueue(async () => {
					const current = lanes.find((l) => l.tasks.some((x) => x.id === taskID))?.tasks.find((x) => x.id === taskID) ?? task;
					const saved = await api.moveTaskToColumn({ ...current, version: current.version }, to.id, index);
					lanes = lanes.map((l) => ({ ...l, tasks: l.tasks.map((x) => (x.id === saved.id ? { ...x, version: saved.version, status: saved.status, columnID: saved.columnID } : x)) }));
				}),
			reload
		);
		if (ok) attempt(() => workspace.reloadTasks());
		else {
			await reload();
		}
	}

	async function moveToNoColumn(task: Task) {
		await attempt(() => enqueue(() => api.moveTaskToColumn(task, null)), reload);
		await reload();
		attempt(() => workspace.reloadTasks());
	}

	function moveByMenu(task: Task, lane: Lane, delta: number) {
		const list = visible(lane);
		const i = list.findIndex((x) => x.id === task.id);
		const target = i + delta;
		if (i < 0 || target < 0 || target >= list.length) return;
		// "others" excludes the moved card, so the final visible position equals `target`.
		moveTask(task.id, lane.laneKey, target);
	}

	// ---- column operations ------------------------------------------------------------------------------------
	const colOf = (lane: Lane): ProjectColumn => ({ id: lane.id!, projectID: project.id, name: lane.name, color: lane.color, isDone: lane.isDone, position: lane.position, version: lane.version ?? 0 });
	const refreshAfter = async (action: () => Promise<unknown>) => {
		const ok = await attempt(() => enqueue(action), reload);
		await reload();
		return ok;
	};

	let renamingID = $state<string | null>(null);
	let renameText = $state('');
	function startRename(lane: Lane) {
		renamingID = lane.id;
		renameText = lane.name;
	}
	async function finishRename(lane: Lane, save: boolean) {
		const name = renameText.trim();
		renamingID = null;
		if (save && name && name !== lane.name) await refreshAfter(() => api.updateColumn(colOf(lane), { name }));
	}
	const setColor = (lane: Lane, color: string) => refreshAfter(() => api.updateColumn(colOf(lane), { color }));
	const toggleDone = (lane: Lane) => refreshAfter(() => api.updateColumn(colOf(lane), { isDone: !lane.isDone }));
	async function shiftColumn(lane: Lane, delta: number) {
		const keys = realLanes.map((l) => l.id!);
		const to = keys.indexOf(lane.id!) + delta;
		if (to < 0 || to >= keys.length) return;
		await moveColumn(lane.id!, to);
	}
	async function moveColumn(id: string, index: number) {
		const keys = realLanes.map((l) => l.id!);
		const nextKeys = reorderKeys(keys, id, index);
		if (nextKeys === keys) return;
		const byID = new Map(lanes.map((l) => [l.id, l]));
		lanes = [...lanes.filter((l) => !l.id), ...nextKeys.map((k) => byID.get(k)!)];
		const lane = byID.get(id)!;
		await refreshAfter(() => api.updateColumn(colOf(lane), { index }));
	}

	let deleting = $state<Lane | null>(null);
	let deleteOpen = $state(false);
	let moveTo = $state('none');
	function askDelete(lane: Lane) {
		deleting = lane;
		moveTo = realLanes.find((l) => l.id !== lane.id)?.id ?? 'none';
		deleteOpen = true;
	}
	async function confirmDelete() {
		const lane = deleting;
		if (!lane) return;
		deleteOpen = false;
		await refreshAfter(() => api.deleteColumn(colOf(lane), moveTo));
		attempt(() => workspace.reloadTasks());
	}

	let addingColumn = $state(false);
	let columnName = $state('');
	async function addColumn(e: Event) {
		e.preventDefault();
		const name = columnName.trim();
		if (!name) return;
		if (await refreshAfter(() => api.createColumn(project.id, { name }))) {
			columnName = '';
			addingColumn = false;
		}
	}
	let copySource = $state('');
	const statusTemplate = () => refreshAfter(() => api.applyColumnTemplate(project.id, 'status'));
	const copyColumns = () => copySource && refreshAfter(() => api.applyColumnTemplate(project.id, copySource));
	const otherProjects = $derived(workspace.projects.filter((p) => p.id !== project.id));

	// ---- tasks in lanes ---------------------------------------------------------------------------------------
	let addTitles = $state<Record<string, string>>({});
	async function addTask(e: Event, lane: Lane) {
		e.preventDefault();
		const title = (addTitles[lane.laneKey] ?? '').trim();
		if (!title) return;
		const ok = await attempt(() => api.createTask(project.id, title, lane.id ? { columnID: lane.id } : {}));
		if (ok) {
			addTitles[lane.laneKey] = '';
			await reload();
			attempt(() => workspace.reloadTasks());
		}
	}
	const toggleTask = async (task: Task) => {
		await attempt(() => api.updateTask(task, { status: task.status === 'done' ? 'open' : 'done' }), reload);
		await reload();
		attempt(() => workspace.reloadTasks());
	};
	const setStatus = async (task: Task, status: TaskStatus) => {
		await attempt(() => api.updateTask(task, { status }), reload);
		await reload();
		attempt(() => workspace.reloadTasks());
	};

	// ---- HTML5 drag and drop ----------------------------------------------------------------------------------
	let drag = $state<{ kind: 'task' | 'column'; id: string } | null>(null);
	let taskDrop = $state<{ laneKey: string; index: number } | null>(null);
	let columnDrop = $state<number | null>(null);
	let boardEl = $state<HTMLDivElement | null>(null);

	function startDrag(e: DragEvent, kind: 'task' | 'column', id: string) {
		e.stopPropagation();
		drag = { kind, id };
		if (e.dataTransfer) {
			e.dataTransfer.effectAllowed = 'move';
			e.dataTransfer.setData('text/plain', `${kind}:${id}`);
		}
	}
	const endDrag = () => {
		drag = null;
		taskDrop = null;
		columnDrop = null;
	};
	function overLane(e: DragEvent, lane: Lane, listEl: HTMLElement) {
		if (drag?.kind !== 'task' || !real) return;
		e.preventDefault();
		e.stopPropagation();
		const cards = Array.from(listEl.querySelectorAll<HTMLElement>('[data-card]')).filter((c) => c.dataset.id !== drag!.id);
		let index = 0;
		for (const c of cards) {
			const r = c.getBoundingClientRect();
			if (e.clientY > r.top + r.height / 2) index++;
		}
		if (taskDrop?.laneKey !== lane.laneKey || taskDrop.index !== index) taskDrop = { laneKey: lane.laneKey, index };
	}
	function dropOnLane(e: DragEvent, lane: Lane) {
		if (drag?.kind !== 'task') return;
		e.preventDefault();
		e.stopPropagation();
		const index = taskDrop?.laneKey === lane.laneKey ? taskDrop.index : visible(lane).length;
		const id = drag.id;
		endDrag();
		moveTask(id, lane.laneKey, index);
	}
	/** Scrolls the board sideways while a card or column is dragged near its left or right edge. */
	function edgeScroll(e: DragEvent) {
		if (!boardEl || !drag) return;
		const r = boardEl.getBoundingClientRect();
		const zone = 64;
		if (e.clientX > r.right - zone) boardEl.scrollLeft += 24;
		else if (e.clientX < r.left + zone) boardEl.scrollLeft -= 24;
	}
	function overBoard(e: DragEvent) {
		edgeScroll(e);
		if (drag?.kind !== 'column' || !boardEl) return;
		e.preventDefault();
		const heads = Array.from(boardEl.querySelectorAll<HTMLElement>('[data-lane-real]')).filter((h) => h.dataset.id !== drag!.id);
		let index = 0;
		for (const h of heads) {
			const r = h.getBoundingClientRect();
			if (e.clientX > r.left + r.width / 2) index++;
		}
		columnDrop = index;
	}
	function dropOnBoard(e: DragEvent) {
		if (drag?.kind !== 'column') return;
		e.preventDefault();
		const index = columnDrop ?? 0;
		const id = drag.id;
		endDrag();
		moveColumn(id, index);
	}
	const columnIndicatorBefore = (lane: Lane) => {
		if (drag?.kind !== 'column' || columnDrop === null || !lane.id) return false;
		const others = realLanes.filter((l) => l.id !== drag!.id);
		return others[columnDrop]?.id === lane.id;
	};
	const columnIndicatorEnd = () => drag?.kind === 'column' && columnDrop !== null && columnDrop >= realLanes.filter((l) => l.id !== drag!.id).length;
	const cardIndicatorBefore = (lane: Lane, task: Task) => {
		if (drag?.kind !== 'task' || taskDrop?.laneKey !== lane.laneKey) return false;
		const others = visible(lane).filter((x) => x.id !== drag!.id);
		return others[taskDrop.index]?.id === task.id;
	};
	const cardIndicatorEnd = (lane: Lane) =>
		drag?.kind === 'task' && taskDrop?.laneKey === lane.laneKey && taskDrop.index >= visible(lane).filter((x) => x.id !== drag!.id).length;

	const priorityRing = (p: number) => (p >= 3 ? 'border-destructive' : p === 2 ? 'border-warning' : p === 1 ? 'border-ui-accent' : 'border-muted-foreground/50');
	const dueTone = (iso: string, done: boolean) => {
		if (isOverdue(iso, done)) return 'text-destructive';
		const d = new Date(iso);
		const now = new Date();
		return d.toDateString() === now.toDateString() ? 'text-success' : 'text-muted-foreground';
	};
</script>

{#snippet card(lane: Lane, task: Task)}
	{@const pl = planningOf(task)}
	{@const labels = labelsByTask[task.id] ?? []}
	{#if cardIndicatorBefore(lane, task)}<div class="bg-ui-accent -mt-1 mb-1 h-0.5 rounded-full" aria-hidden="true"></div>{/if}
	<article
		class={['bg-card hover:border-foreground/25 group/card relative rounded-xl border p-2.5 pr-8 text-sm shadow-card transition-colors', drag?.id === task.id && 'opacity-40']}
		data-card
		data-id={task.id}
		data-testid="board-card"
		draggable={real}
		ondragstart={(e) => startDrag(e, 'task', task.id)}
		ondragend={endDrag}
	>
		<div class="flex items-start gap-2">
			<button
				type="button"
				class={['mt-0.5 inline-flex size-[18px] shrink-0 items-center justify-center rounded-full border-2 transition-colors', priorityRing(pl?.priority ?? 0), task.status === 'done' && 'bg-ui-accent border-ui-accent text-ui-accent-foreground']}
				aria-label={task.status === 'done' ? t('tasks.reopen') : t('tasks.done')}
				aria-pressed={task.status === 'done'}
				data-testid="board-card-check"
				onclick={() => toggleTask(task)}
			>
				{#if task.status === 'done'}<Check class="size-3" aria-hidden="true" />{/if}
			</button>
			<div class="min-w-0 flex-1">
				<button type="button" class={['block w-full text-left break-words', task.status === 'done' && 'text-muted-foreground line-through']} onclick={() => onopen(task)}>{task.title}</button>
				{#if task.description.trim()}
					<p class="text-muted-foreground mt-0.5 line-clamp-2 text-[13px] break-words">{snippet(task.description, 120)}</p>
				{/if}
				{#if pl?.dueAt || labels.length > 0 || pl?.hasRecurrence}
					<div class="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
						{#if pl?.dueAt}
							<span class={['inline-flex items-center gap-1', dueTone(pl.dueAt, task.status === 'done')]} data-testid="card-due"><CalendarDays class="size-3.5" aria-hidden="true" />{formatWhen(pl.dueAt)}</span>
						{/if}
						{#if pl?.hasRecurrence}<Repeat class="text-muted-foreground size-3.5" aria-label={t('planning.chip.recurrence')} />{/if}
						{#each labels as l (l)}
							<span class="bg-muted text-muted-foreground inline-flex items-center gap-1 rounded-full px-2 py-0.5" data-testid="card-label"><Tag class="size-3" aria-hidden="true" />{l}</span>
						{/each}
					</div>
				{/if}
			</div>
		</div>
		<Popover
			label={t('board.cardMenu', { title: task.title })}
			align="end"
			class="text-muted-foreground hover:bg-muted absolute top-1.5 right-1.5 inline-flex size-6 items-center justify-center rounded-md opacity-0 group-hover/card:opacity-100 focus-visible:opacity-100 aria-expanded:opacity-100 [@media(hover:none)]:opacity-100"
		>
			{#snippet trigger()}<Ellipsis class="size-4" aria-hidden="true" />{/snippet}
			{#snippet children(close)}
				<MenuItem onclick={() => { close(); onopen(task); }}>{t('board.openTask')}</MenuItem>
				{#if real}
					<MenuItem onclick={() => { close(); moveByMenu(task, lane, -1); }}>{t('board.moveUp')}</MenuItem>
					<MenuItem onclick={() => { close(); moveByMenu(task, lane, 1); }}>{t('board.moveDown')}</MenuItem>
					<p class="text-muted-foreground px-2.5 pt-2 pb-1 text-xs font-semibold" id="move-{task.id}">{t('board.moveTo')}</p>
					<div role="group" aria-labelledby="move-{task.id}">
						{#each lanes.filter((l) => l.laneKey !== lane.laneKey) as target (target.laneKey)}
							<MenuItem onclick={() => { close(); moveTask(task.id, target.laneKey, visible(target).filter((x) => x.id !== task.id).length); }}>{laneTitle(target)}</MenuItem>
						{/each}
						{#if lane.id && !lanes.some((l) => l.laneKey === 'none')}
							<MenuItem onclick={() => { close(); moveToNoColumn(task); }}>{t('board.noColumn')}</MenuItem>
						{/if}
					</div>
				{:else}
					<p class="text-muted-foreground px-2.5 pt-2 pb-1 text-xs font-semibold" id="status-{task.id}">{t('board.setStatus')}</p>
					<div role="group" aria-labelledby="status-{task.id}">
						{#each STATUSES as s (s)}
							<MenuItem active={task.status === s} onclick={() => { close(); setStatus(task, s); }}>{t(`status.${s}` as MessageKey)}</MenuItem>
						{/each}
					</div>
				{/if}
			{/snippet}
		</Popover>
	</article>
{/snippet}

{#if !real}
	<div class="bg-muted/60 mb-4 flex max-w-3xl flex-col gap-2 rounded-xl border p-3 text-sm" data-testid="board-status-hint">
		<p class="font-medium">{t('board.statusMode.title')}</p>
		<p class="text-muted-foreground">{t('board.statusMode.hint')}</p>
		<div class="flex flex-wrap items-center gap-2">
			<Button size="sm" onclick={statusTemplate} data-testid="template-status">{t('board.template.status')}</Button>
			{#if otherProjects.length > 0}
				<Select bind:value={copySource} aria-label={t('board.template.copyFrom')} class="max-w-56 [&_select]:h-8 [&_select]:text-xs">
					<option value="">{t('board.template.copyFrom')}</option>
					{#each otherProjects as p (p.id)}<option value={p.id}>{p.name}</option>{/each}
				</Select>
				<Button size="sm" variant="outline" disabled={!copySource} onclick={copyColumns}>{t('board.template.copy')}</Button>
			{/if}
		</div>
	</div>
{/if}

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	bind:this={boardEl}
	class="-mx-4 flex snap-x snap-mandatory items-start gap-3 overflow-x-auto px-4 pb-6 menu:-mx-8 menu:snap-none menu:gap-4 menu:px-8"
	data-testid="board"
	data-mode={board.mode}
	ondragover={overBoard}
	ondrop={dropOnBoard}
>
	{#each lanes as lane (lane.laneKey)}
		{#if columnIndicatorBefore(lane)}<div class="bg-ui-accent h-40 w-0.5 shrink-0 self-stretch rounded-full" aria-hidden="true"></div>{/if}
		<section
			class="flex w-[82vw] max-w-72 shrink-0 snap-start flex-col gap-2 menu:w-72"
			aria-label={laneTitle(lane)}
			data-testid="board-lane"
			data-name={laneTitle(lane)}
			data-lane-real={lane.id ? '' : undefined}
			data-id={lane.id ?? lane.laneKey}
			ondragover={(e) => overLane(e, lane, e.currentTarget.querySelector('[data-cards]') as HTMLElement)}
			ondrop={(e) => dropOnLane(e, lane)}
		>
			<header
				class={['group/head relative flex items-center gap-1.5 px-1', lane.id && real && 'cursor-grab']}
				draggable={!!lane.id && real && renamingID !== lane.id}
				ondragstart={(e) => lane.id && startDrag(e, 'column', lane.id)}
				ondragend={endDrag}
			>
				{#if lane.id && real}<GripVertical class="text-muted-foreground absolute -left-3.5 size-3.5 opacity-0 group-hover/head:opacity-100 [@media(hover:none)]:hidden" aria-hidden="true" />{/if}
				{#if lane.color}<span class="size-2.5 shrink-0 rounded-full" style:background={lane.color} aria-hidden="true"></span>{/if}
				{#if renamingID === lane.id && lane.id}
					<!-- svelte-ignore a11y_autofocus -->
					<input
						class="border-input bg-background h-8 min-w-0 flex-1 rounded-md border px-2 text-sm font-semibold"
						aria-label={t('board.renameColumn')}
						bind:value={renameText}
						autofocus
						onkeydown={(e) => {
							if (e.key === 'Enter') finishRename(lane, true);
							else if (e.key === 'Escape') finishRename(lane, false);
						}}
						onblur={() => finishRename(lane, true)}
					/>
				{:else}
					<h3 class="min-w-0 flex-1 truncate text-[15px] font-semibold" data-testid="lane-title">{laneTitle(lane)}</h3>
				{/if}
				<span class="text-muted-foreground text-sm" data-tabular data-testid="lane-count">{visible(lane).length}</span>
				{#if lane.id && real}
					<Popover
						label={t('board.columnMenu', { name: lane.name })}
						align="end"
						class="text-muted-foreground hover:bg-muted inline-flex size-7 shrink-0 items-center justify-center rounded-md"
					>
						{#snippet trigger()}<Ellipsis class="size-4" aria-hidden="true" />{/snippet}
						{#snippet children(close)}
							<MenuItem onclick={() => { close(); startRename(lane); }}>{t('common.rename')}</MenuItem>
							<MenuItem onclick={() => { close(); toggleDone(lane); }}>
								{lane.isDone ? t('board.unsetDone') : t('board.setDone')}
							</MenuItem>
							<MenuItem onclick={() => { close(); shiftColumn(lane, -1); }} disabled={realLanes[0]?.id === lane.id}>{t('board.moveLeft')}</MenuItem>
							<MenuItem onclick={() => { close(); shiftColumn(lane, 1); }} disabled={realLanes[realLanes.length - 1]?.id === lane.id}>{t('board.moveRight')}</MenuItem>
							<p class="text-muted-foreground px-2.5 pt-2 pb-1 text-xs font-semibold">{t('board.color')}</p>
							<div class="flex flex-wrap gap-1.5 px-2.5 pb-2" role="group" aria-label={t('board.color')}>
								{#each PROJECT_COLORS as c (c)}
									<button
										type="button"
										class={['size-6 rounded-full border-2', lane.color === c ? 'border-foreground' : 'border-transparent']}
										style:background={c}
										aria-label={t('board.colorOption', { hex: c })}
										aria-pressed={lane.color === c}
										onclick={() => { close(); setColor(lane, c); }}
									></button>
								{/each}
								<button type="button" class="text-muted-foreground hover:bg-muted rounded-md px-1.5 text-xs" onclick={() => { close(); setColor(lane, ''); }}>{t('board.colorNone')}</button>
							</div>
							<MenuItem danger onclick={() => { close(); askDelete(lane); }}>{t('board.deleteColumn')}</MenuItem>
						{/snippet}
					</Popover>
				{/if}
			</header>

			<div class="flex min-h-12 flex-col gap-2" data-cards>
				{#each visible(lane) as task (task.id)}
					{@render card(lane, task)}
				{/each}
				{#if cardIndicatorEnd(lane)}<div class="bg-ui-accent h-0.5 rounded-full" aria-hidden="true"></div>{/if}
				{#if visible(lane).length === 0 && !drag}<p class="text-muted-foreground px-1 text-xs">{t('board.empty')}</p>{/if}
			</div>

			{#if laneAdd(lane)}
				<form class="flex items-center gap-1.5" onsubmit={(e) => addTask(e, lane)}>
					<Plus class="text-muted-foreground ml-1 size-4 shrink-0" aria-hidden="true" />
					<input
						class="placeholder:text-muted-foreground h-8 min-w-0 flex-1 rounded-md bg-transparent px-1 text-sm outline-none focus-visible:ring-2"
						placeholder={t('board.addTask')}
						aria-label={t('board.addTaskIn', { name: laneTitle(lane) })}
						value={addTitles[lane.laneKey] ?? ''}
						oninput={(e) => (addTitles[lane.laneKey] = e.currentTarget.value)}
					/>
				</form>
			{/if}
		</section>
	{/each}
	{#if columnIndicatorEnd()}<div class="bg-ui-accent h-40 w-0.5 shrink-0 self-stretch rounded-full" aria-hidden="true"></div>{/if}

	<div class="flex w-[82vw] max-w-72 shrink-0 snap-start flex-col gap-2 menu:w-72">
		{#if addingColumn}
			<form class="flex flex-col gap-2" onsubmit={addColumn}>
				<Input data-autofocus bind:value={columnName} placeholder={t('board.columnName')} aria-label={t('board.columnName')} />
				<div class="flex gap-1.5">
					<Button type="submit" size="sm" disabled={!columnName.trim()}>{t('board.addColumnSubmit')}</Button>
					<Button type="button" size="sm" variant="ghost" onclick={() => { addingColumn = false; columnName = ''; }}>{t('common.cancel')}</Button>
				</div>
			</form>
		{:else}
			<button
				type="button"
				class="text-muted-foreground hover:bg-muted flex h-9 items-center gap-2 rounded-lg px-2.5 text-sm"
				data-testid="add-column"
				onclick={() => (addingColumn = true)}
			>
				<Plus class="size-4" aria-hidden="true" />{t('board.addColumn')}
			</button>
		{/if}
	</div>
</div>

<Dialog bind:open={deleteOpen} title={t('board.deleteColumn')} testid="delete-column-dialog">
	{#if deleting}
		<div class="flex flex-col gap-3 text-sm">
			<p>{t('board.deleteConfirm', { name: deleting.name, count: deleting.tasks.length })}</p>
			<label class="flex flex-col gap-1 text-xs font-medium">
				{t('board.deleteMoveTo')}
				<Select bind:value={moveTo}>
					{#each realLanes.filter((l) => l.id !== deleting?.id) as l (l.id)}<option value={l.id}>{l.name}</option>{/each}
					<option value="none">{t('board.noColumn')}</option>
				</Select>
			</label>
			<div class="flex justify-end gap-2">
				<Button variant="ghost" onclick={() => (deleteOpen = false)}>{t('common.cancel')}</Button>
				<Button variant="destructive" onclick={confirmDelete}>{t('common.delete')}</Button>
			</div>
		</div>
	{/if}
</Dialog>
