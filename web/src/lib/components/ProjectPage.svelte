<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';
	import { api, type BoardResponse, type Project, type ProjectMode, type Task } from '#lib/api.js';
	import { type Display, type Grouping, type Sort } from '#lib/listLogic.js';
	import { PROJECT_COLORS } from '#lib/boardLogic.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { collectAll } from '#lib/planning.js';
	import type { ProjectSub } from '#lib/routing.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Dialog from './app/Dialog.svelte';
	import MenuItem from './app/MenuItem.svelte';
	import Popover from './app/Popover.svelte';
	import CommandCenter from './CommandCenter.svelte';
	import MilestonesPanel from './MilestonesPanel.svelte';
	import ProjectComments from './ProjectComments.svelte';
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
		/** URL state (see routing.ts): sub path and open task, reported back through `onroute`. */
		sub?: ProjectSub;
		taskID?: string;
		onroute?: (sub: ProjectSub | undefined, taskID: string | undefined) => void;
		project: Project;
		/** Names and ids of the ancestors, outermost first. */
		trail: { id: string; name: string }[];
		onselect: (id: string) => void;
		onshare: (p: Project) => void;
	}
	let { project, trail, onselect, onshare, sub, taskID, onroute }: Props = $props();

	/** `tasks` = list/board of the project, `overview` = command center of the project (ADR 0014). */
	let tab = $state<'tasks' | 'overview'>('tasks');
	/** Classic = plain todo list/board; management = overview, agents, sync, milestones (per project and account). */
	const mode = $derived(workspace.modeOf(project.id));
	const management = $derived(mode === 'management');
	const subprojects = $derived(workspace.subprojectsForMode(project.id));
	/** Primitive on purpose: a live refresh replaces the object, the effects below must only rerun for another id. */
	const projectKey = $derived(project.id);
	$effect(() => {
		void projectKey;
		void workspace.refreshPrefs();
	});
	$effect(() => {
		if (!management) tab = 'tasks';
	});

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

	/** Live refresh: refetch silently and replace only what changed (no label reload, no flicker, scroll position stays). */
	async function refreshQuiet() {
		if (!loaded) return;
		const my = seq;
		const id = project.id;
		const was = tasks;
		const [ts, b] = await Promise.all([api.listTasks(id), api.projectBoard(id)]);
		if (my !== seq || id !== project.id || tasks !== was) return;
		if (!sameList(tasks, ts)) tasks = ts;
		if (JSON.stringify(board) !== JSON.stringify(b)) board = b;
	}
	onMount(() => startLiveRefresh(refreshQuiet, { guardEditing: true }));
	$effect(() => {
		void projectKey;
		void ui.changeTick;
		void viewMode;
		attempt(reload);
	});
	$effect(() => {
		// A different project: start from a clean state (no flash of the previous project's tasks).
		void projectKey;
		loaded = false;
		tasks = [];
		board = null;
		labelsByTask = {};
		detail = null;
		editingTitle = false;
	});

	// ---- display (per project and account, server-side via /v1/me/project-prefs) --------------------------------
	const display = $derived<Display>(workspace.displayOf(project.id));
	/** Primitive on purpose: effects that depend on the view must not rerun when only the revision changes. */
	const viewMode = $derived(display.view);
	function setMode(next: ProjectMode) {
		attempt(() => workspace.setMode(project.id, next));
	}
	function applyModeToSubprojects() {
		attempt(() => workspace.setModeWithSubprojects(project.id, mode));
	}
	function setDisplay(changes: Partial<Display>) {
		attempt(() => workspace.setDisplay(project.id, changes));
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
	let descDraft = $state('');
	let descFocused = $state(false);
	$effect(() => {
		// Follow the server value (other device, reload) unless the user is typing.
		const server = project.description ?? '';
		if (!descFocused) descDraft = server;
	});
	let descEl = $state<HTMLTextAreaElement | null>(null);
	$effect(() => {
		void descDraft;
		if (descEl) {
			descEl.style.height = 'auto';
			descEl.style.height = `${descEl.scrollHeight}px`;
		}
	});
	/** Saves on blur only when the text changed; an empty text clears the description. */
	async function saveDescription() {
		descFocused = false;
		const text = descDraft.trim();
		if (text === (project.description ?? '').trim()) {
			descDraft = project.description ?? '';
			return;
		}
		const ok = await attempt(async () => {
			const updated = await api.updateProject(project, { description: text });
			workspace.projects = workspace.projects.map((x) => (x.id === updated.id ? updated : x));
		}, () => workspace.reloadProjects());
		if (!ok) descDraft = project.description ?? '';
	}
	async function setColor(color: string) {
		await attempt(async () => {
			await api.updateProject(project, { color });
			await workspace.reloadProjects();
		}, () => workspace.reloadProjects());
	}

	// ---- dialogs ----------------------------------------------------------------------------------------------
	let milestonesOpen = $state(false);
	let commentsOpen = $state(false);
	let colorOpen = $state(false);
	let detail = $state<Task | null>(null);
	let detailOpen = $state(false);
	$effect(() => {
		if (!detailOpen) detail = null;
	});
	// ---- URL state: /projekt/<id>/<liste|board|ueberblick|kommentare>?task=<id> -------------------------------------
	let routeApplied = $state(false);
	$effect(() => {
		if (routeApplied || !workspace.prefsLoaded) return;
		routeApplied = true;
		if (sub === 'ueberblick') tab = 'overview';
		else if (sub === 'kommentare') commentsOpen = true;
		else if ((sub === 'board' || sub === 'liste') && (sub === 'board') !== (display.view === 'board')) setDisplay({ view: sub === 'board' ? 'board' : 'list' });
	});
	let taskApplied = $state(false);
	$effect(() => {
		if (taskApplied || !loaded || !taskID) return;
		taskApplied = true;
		const found = tasks.find((x) => x.id === taskID);
		if (found) openDetail(found);
	});
	$effect(() => {
		if (!routeApplied) return;
		const current: ProjectSub = commentsOpen ? 'kommentare' : tab === 'overview' ? 'ueberblick' : display.view === 'board' ? 'board' : 'liste';
		const task = detailOpen ? detail?.id : undefined;
		// Deep link to a task still loading: keep ?task= until it was applied or is known to be missing.
		const keep = taskID && !taskApplied ? taskID : task;
		onroute?.(current, keep);
	});
	const openDetail = (task: Task) => {
		detail = task;
		detailOpen = true;
	};
	const fav = $derived(!!project.isFavorite);

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
					<div role="group" aria-label={t('mode.title')} data-testid="mode-switch">
						<p class="text-muted-foreground mb-1 text-xs font-semibold">{t('mode.title')}</p>
						<div class="grid grid-cols-2 gap-1">
							<Button size="sm" variant={mode === 'classic' ? 'default' : 'outline'} aria-pressed={mode === 'classic'} data-testid="mode-classic" onclick={() => setMode('classic')}>
								{t('mode.classic')}
							</Button>
							<Button size="sm" variant={mode === 'management' ? 'default' : 'outline'} aria-pressed={mode === 'management'} data-testid="mode-management" onclick={() => setMode('management')}>
								{t('mode.management')}
							</Button>
						</div>
						<p class="text-muted-foreground mt-1 text-xs" data-testid="mode-hint">{t(mode === 'classic' ? 'mode.classic.hint' : 'mode.management.hint')}</p>
						{#if subprojects && subprojects.length > 0}
							<button type="button" class="text-ui-accent-ink mt-1 min-h-9 text-left text-xs underline underline-offset-2" data-testid="mode-apply-sub" onclick={applyModeToSubprojects}>
								{t('mode.applySub', { count: subprojects.length })}
							</button>
						{/if}
					</div>
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
		<Button variant="ghost" size="icon-sm" aria-label={t('project.comments')} data-testid="project-comments-open" onclick={() => (commentsOpen = true)}>
			<MessageSquare aria-hidden="true" />
		</Button>
		<Popover label={t('project.more')} align="end" class="hover:bg-muted inline-flex size-8 items-center justify-center rounded-lg" testid="project-more">
			{#snippet trigger()}<Ellipsis class="size-4" aria-hidden="true" />{/snippet}
			{#snippet children(close)}
				<MenuItem onclick={() => { attempt(() => workspace.toggleFavorite(project.id)); close(); }}>
					<Star class="size-4" aria-hidden="true" />{fav ? t('projects.unfavorite') : t('projects.favorite')}
				</MenuItem>
				<MenuItem onclick={() => { close(); startTitle(); }}>{t('common.rename')}</MenuItem>
				<MenuItem testid="project-color-open" onclick={() => { close(); colorOpen = true; }}>{t('project.color')}</MenuItem>
				{#if management}
					<MenuItem testid="milestones-open" onclick={() => { close(); milestonesOpen = true; }}>{t('view.milestones')}</MenuItem>
				{/if}
			{/snippet}
		</Popover>
	</div>
{/snippet}

<div class={display.view === 'board' || tab === 'overview' ? '' : 'mx-auto max-w-3xl'}>
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
			maxlength={10000}
			bind:value={descDraft}
			onfocus={() => (descFocused = true)}
			onblur={saveDescription}
		></textarea>
	</header>

	{#if management}
	<div class="mb-4 flex gap-4 border-b" role="tablist" aria-label={t('cc.projectTabs')} data-testid="project-tabs">
		{#each ['tasks', 'overview'] as const as id (id)}
			<button
				type="button"
				role="tab"
				aria-selected={tab === id}
				data-testid="project-tab-{id}"
				class={[
					'-mb-px min-h-9 border-b-2 px-1 text-sm font-medium transition-colors',
					tab === id ? 'border-ui-accent text-foreground' : 'text-muted-foreground hover:text-foreground border-transparent'
				]}
				onclick={() => (tab = id)}
			>
				{t(id === 'tasks' ? 'cc.tab.tasks' : 'cc.tab.overview')}
			</button>
		{/each}
	</div>
	{/if}

	{#if management && tab === 'overview'}
		<CommandCenter projectID={project.id} />
	{:else if display.view === 'board'}
		{#if board}
			<ProjectBoard {project} {board} {tasks} {labelsByTask} showDone={display.showDone} {reload} onopen={openDetail} />
		{/if}
	{:else}
		<TaskPanel {project} {tasks} {board} {display} {loaded} {reload} />
	{/if}
</div>

<Dialog bind:open={commentsOpen} title={t('project.commentsTitle', { name: project.name })} class="max-w-xl" testid="project-comments-dialog">
	<ProjectComments {project} />
</Dialog>
<Dialog bind:open={colorOpen} title={t('project.colorTitle')} testid="project-color-dialog">
	<div class="flex flex-wrap gap-2" role="group" aria-label={t('project.colorTitle')}>
		{#each PROJECT_COLORS as c, i (c)}
			<button
				type="button"
				class={['size-9 rounded-full border-2', project.color?.toUpperCase() === c ? 'border-foreground' : 'border-transparent']}
				style:background-color={c}
				aria-label={t('project.colorPick', { name: t(`project.color.${i}` as MessageKey) })}
				aria-pressed={project.color?.toUpperCase() === c}
				data-testid="color-swatch"
				onclick={() => { setColor(c); colorOpen = false; }}
			></button>
		{/each}
		<Button variant="outline" data-testid="color-auto" aria-pressed={!project.color} onclick={() => { setColor(''); colorOpen = false; }}>{t('project.colorAuto')}</Button>
	</div>
</Dialog>
{#if management}
	<Dialog bind:open={milestonesOpen} title={t('view.milestones')} class="max-w-2xl">
		<MilestonesPanel {project} />
	</Dialog>
{/if}
<Dialog bind:open={detailOpen} title={detail?.title ?? t('task.details')} class="max-w-2xl" testid="task-dialog">
	{#if detail}<TaskDetail task={detail} onplanned={reload} />{/if}
</Dialog>
