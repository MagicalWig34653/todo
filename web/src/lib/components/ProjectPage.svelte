<script lang="ts">
	import { onDestroy } from 'svelte';
	import { api, type BoardResponse, type Project, type Task } from '#lib/api.js';
	import { DEFAULT_DISPLAY, type Display, type Grouping, type Sort } from '#lib/listLogic.js';
	import { t } from '#lib/i18n/index.js';
	import { KEYS, readJSON, writeJSON } from '#lib/localPrefs.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { collectAll } from '#lib/planning.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Dialog from './app/Dialog.svelte';
	import MenuItem from './app/MenuItem.svelte';
	import Popover from './app/Popover.svelte';
	import MilestonesPanel from './MilestonesPanel.svelte';
	import ProjectBoard from './ProjectBoard.svelte';
	import TaskDetail from './TaskDetail.svelte';
	import TaskPanel from './TaskPanel.svelte';
	import Columns3 from '@lucide/svelte/icons/columns-3';
	import List from '@lucide/svelte/icons/list';
	import MessageSquare from '@lucide/svelte/icons/message-square';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import UserPlus from '@lucide/svelte/icons/user-plus';
	import Star from '@lucide/svelte/icons/star';
	import PanelLeft from '@lucide/svelte/icons/panel-left';

	interface Props {
		project: Project;
		/** Names and ids of the ancestors, outermost first. */
		trail: { id: string; name: string }[];
		onselect: (id: string) => void;
		onshare: (p: Project) => void;
	}
	let { project, trail, onselect, onshare }: Props = $props();

	// ---- data -------------------------------------------------------------------------------------------------
	let tasks = $state<Task[]>([]);
	let board = $state<BoardResponse | null>(null);
	let labelsByTask = $state<Record<string, string[]>>({});
	let loaded = $state(false);
	let seq = 0;

	async function loadLabels(id: string): Promise<Record<string, string[]>> {
		const out: Record<string, string[]> = {};
		await Promise.allSettled(
			workspace.labels.slice(0, 40).map(async (l) => {
				const hits = await collectAll((c) => api.search({ projectID: id, labelID: l.id }, c), 5);
				for (const h of hits) if (h.kind === 'task' && h.task) (out[h.task.id] ??= []).push(l.name);
			})
		);
		return out;
	}
	async function reload() {
		const my = ++seq;
		const id = project.id;
		const [ts, b] = await Promise.all([api.listTasks(id), api.projectBoard(id)]);
		if (my !== seq) return;
		tasks = ts;
		board = b;
		loaded = true;
		if (display.view === 'board' && workspace.labels.length > 0) {
			const l = await loadLabels(id);
			if (my === seq) labelsByTask = l;
		}
	}

	$effect(() => {
		void project.id;
		void ui.changeTick;
		void display.view;
		attempt(reload);
	});
	$effect(() => {
		// A different project: start from a clean state (no flash of the previous project's tasks).
		void project.id;
		loaded = false;
		tasks = [];
		board = null;
		labelsByTask = {};
		detail = null;
		editingTitle = false;
	});

	// ---- display (per project, device-local) ------------------------------------------------------------------
	const stored = () => readJSON<Record<string, Partial<Display>>>(KEYS.display, {});
	let display = $state<Display>({ ...DEFAULT_DISPLAY });
	$effect(() => {
		display = { ...DEFAULT_DISPLAY, ...(stored()[project.id] ?? {}) };
	});
	function setDisplay(changes: Partial<Display>) {
		display = { ...display, ...changes };
		writeJSON(KEYS.display, { ...stored(), [project.id]: display });
	}

	// ---- title and description --------------------------------------------------------------------------------
	let editingTitle = $state(false);
	let titleDraft = $state('');
	function startTitle() {
		titleDraft = project.name;
		editingTitle = true;
	}
	async function saveTitle() {
		const name = titleDraft.trim();
		editingTitle = false;
		if (!name || name === project.name) return;
		await attempt(async () => {
			const updated = await api.renameProject(project, name);
			workspace.projects = workspace.projects.map((p) => (p.id === updated.id ? updated : p));
		}, () => workspace.reloadProjects());
	}
	const description = $derived(workspace.descriptions[project.id] ?? '');
	let descEl = $state<HTMLTextAreaElement | null>(null);
	$effect(() => {
		void description;
		if (descEl) {
			descEl.style.height = 'auto';
			descEl.style.height = `${descEl.scrollHeight}px`;
		}
	});

	// ---- dialogs ----------------------------------------------------------------------------------------------
	let milestonesOpen = $state(false);
	let detail = $state<Task | null>(null);
	let detailOpen = $state(false);
	$effect(() => {
		if (!detailOpen) detail = null;
	});
	const openDetail = (task: Task) => {
		detail = task;
		detailOpen = true;
	};
	const fav = $derived(workspace.isFavorite(project.id));

	// The header toolbar belongs to this page.
	$effect(() => {
		ui.toolbar = toolbar;
	});
	onDestroy(() => (ui.toolbar = null));
</script>

{#snippet toolbar()}
	<nav class="text-muted-foreground flex min-w-0 flex-1 items-center gap-1 overflow-hidden text-sm" aria-label={t('project.breadcrumb')} data-testid="breadcrumb">
		<span class="shrink-0">{t('projects.mine')}</span>
		{#each trail as a (a.id)}
			<span aria-hidden="true">/</span>
			<button class="hover:text-foreground truncate" onclick={() => onselect(a.id)}>{a.name}</button>
		{/each}
		<span aria-hidden="true">/</span>
	</nav>
	<div class="flex shrink-0 items-center gap-0.5">
		<Button variant="ghost" size="sm" data-testid="share-open" aria-label={t('project.share')} onclick={() => onshare(project)}>
			<UserPlus aria-hidden="true" /><span class="hidden sm:inline">{t('project.share')}</span>
		</Button>
		<Popover
			label={t('display.title')}
			align="end"
			testid="display-menu"
			class="hover:bg-muted inline-flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-[0.8rem] font-medium"
			panelClass="w-72"
		>
			{#snippet trigger()}
				{#if display.view === 'board'}<Columns3 class="size-3.5" aria-hidden="true" />{:else}<List class="size-3.5" aria-hidden="true" />{/if}
				<span class="hidden sm:inline">{t('display.title')}</span>
			{/snippet}
			{#snippet children()}
				<div class="flex flex-col gap-3 p-1.5 text-sm">
					<div role="group" aria-label={t('display.view')}>
						<p class="text-muted-foreground mb-1 text-xs font-semibold">{t('display.view')}</p>
						<div class="grid grid-cols-2 gap-1">
							<Button size="sm" variant={display.view === 'list' ? 'default' : 'outline'} aria-pressed={display.view === 'list'} onclick={() => setDisplay({ view: 'list' })}>
								<List aria-hidden="true" />{t('view.list')}
							</Button>
							<Button size="sm" variant={display.view === 'board' ? 'default' : 'outline'} aria-pressed={display.view === 'board'} onclick={() => setDisplay({ view: 'board' })}>
								<Columns3 aria-hidden="true" />{t('view.board')}
							</Button>
						</div>
					</div>
					{#if display.view === 'list'}
						<label class="flex flex-col gap-1 text-xs font-semibold">
							<span class="text-muted-foreground">{t('display.sort')}</span>
							<Select value={display.sort} onchange={(e) => setDisplay({ sort: e.currentTarget.value as Sort })}>
								<option value="manual">{t('display.sort.manual')}</option>
								<option value="title">{t('display.sort.title')}</option>
								<option value="due">{t('display.sort.due')}</option>
								<option value="priority">{t('display.sort.priority')}</option>
							</Select>
						</label>
						<label class="flex flex-col gap-1 text-xs font-semibold">
							<span class="text-muted-foreground">{t('display.group')}</span>
							<Select value={display.grouping} onchange={(e) => setDisplay({ grouping: e.currentTarget.value as Grouping })}>
								<option value="none">{t('display.group.none')}</option>
								<option value="column">{t('display.group.column')}</option>
								<option value="priority">{t('display.group.priority')}</option>
								<option value="due">{t('display.group.due')}</option>
							</Select>
						</label>
					{/if}
					<label class="flex items-center gap-2">
						<Checkbox checked={display.showDone} onchange={(e) => setDisplay({ showDone: e.currentTarget.checked })} data-testid="show-done" />
						{t('display.showDone')}
					</label>
				</div>
			{/snippet}
		</Popover>
		<Popover label={t('project.comments')} align="end" class="hover:bg-muted inline-flex size-8 items-center justify-center rounded-lg" panelClass="w-64">
			{#snippet trigger()}<MessageSquare class="size-4" aria-hidden="true" />{/snippet}
			{#snippet children()}
				<p class="text-muted-foreground p-2 text-sm">{t('project.commentsHint')}</p>
			{/snippet}
		</Popover>
		<Popover label={t('project.more')} align="end" class="hover:bg-muted inline-flex size-8 items-center justify-center rounded-lg" testid="project-more">
			{#snippet trigger()}<Ellipsis class="size-4" aria-hidden="true" />{/snippet}
			{#snippet children(close)}
				<MenuItem onclick={() => { workspace.toggleFavorite(project.id); close(); }}>
					<Star class="size-4" aria-hidden="true" />{fav ? t('projects.unfavorite') : t('projects.favorite')}
				</MenuItem>
				<MenuItem onclick={() => { close(); startTitle(); }}>{t('common.rename')}</MenuItem>
				<MenuItem testid="milestones-open" onclick={() => { close(); milestonesOpen = true; }}>{t('view.milestones')}</MenuItem>
			{/snippet}
		</Popover>
	</div>
{/snippet}

<div class={display.view === 'board' ? '' : 'mx-auto max-w-3xl'}>
	<header class="mb-4 max-w-3xl">
		<h2 class="text-[28px] leading-tight font-bold tracking-tight sm:text-[32px]" data-testid="task-heading">
			{#if editingTitle}
				<!-- svelte-ignore a11y_autofocus -->
				<input
					class="border-input bg-background w-full rounded-lg border px-2 py-0.5 text-[28px] font-bold sm:text-[32px]"
					aria-label={t('project.title')}
					bind:value={titleDraft}
					autofocus
					onkeydown={(e) => {
						if (e.key === 'Enter') saveTitle();
						else if (e.key === 'Escape') editingTitle = false;
					}}
					onblur={saveTitle}
				/>
			{:else}
				<button class="text-left" title={t('project.renameHint')} onclick={startTitle}>{project.name}</button>
			{/if}
		</h2>
		<textarea
			bind:this={descEl}
			rows="1"
			class="placeholder:text-muted-foreground mt-1 block w-full resize-none rounded-md bg-transparent py-0.5 text-[15px] outline-none focus-visible:ring-2"
			placeholder={t('tasks.descriptionPlaceholder')}
			aria-label={t('project.description')}
			data-testid="project-description"
			value={description}
			oninput={(e) => workspace.setDescription(project.id, e.currentTarget.value)}
		></textarea>
	</header>

	{#if display.view === 'board'}
		{#if board}
			<ProjectBoard {project} {board} {tasks} {labelsByTask} showDone={display.showDone} {reload} onopen={openDetail} />
		{/if}
	{:else}
		<TaskPanel {project} {tasks} {board} {display} {loaded} {reload} />
	{/if}
</div>

<Dialog bind:open={milestonesOpen} title={t('view.milestones')} class="max-w-2xl">
	<MilestonesPanel {project} />
</Dialog>
<Dialog bind:open={detailOpen} title={detail?.title ?? t('task.details')} class="max-w-2xl" testid="task-dialog">
	{#if detail}<TaskDetail task={detail} onplanned={reload} />{/if}
</Dialog>
