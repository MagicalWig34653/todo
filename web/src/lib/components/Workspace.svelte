<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type Project } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { buildTree } from '#lib/projectTree.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import ProjectItem from './ProjectItem.svelte';
	import TaskPanel from './TaskPanel.svelte';
	import BoardView from './BoardView.svelte';
	import PlanningView from './PlanningView.svelte';
	import SearchView from './SearchView.svelte';
	import TeamsView from './TeamsView.svelte';
	import SharingPanel from './SharingPanel.svelte';
	import MilestonesPanel from './MilestonesPanel.svelte';
	import AccountView from './AccountView.svelte';

	type View = 'project' | 'today' | 'upcoming' | 'upNext' | 'search' | 'teams' | 'account';
	type Tab = 'list' | 'board' | 'milestones' | 'sharing';
	const VIEWS: View[] = ['today', 'upcoming', 'upNext', 'search', 'teams', 'account'];
	let view = $state<View>('project');
	let tab = $state<Tab>('list');

	let projects = $state<Project[]>([]);
	let selectedID = $state<string | null>(null);
	let newName = $state('');
	let navOpen = $state(false);

	const tree = $derived(buildTree(projects));
	const selected = $derived(projects.find((p) => p.id === selectedID) ?? null);

	async function load() {
		projects = await api.listProjects();
		if (selectedID && !projects.some((p) => p.id === selectedID)) selectedID = null;
	}

	onMount(() => {
		attempt(load);
	});

	async function addRoot(e: Event) {
		e.preventDefault();
		const name = newName.trim();
		if (!name) return;
		if (await attempt(async () => (projects = [...projects, await api.createProject(name)]))) newName = '';
	}

	const patch = (updated: Project) => (projects = projects.map((p) => (p.id === updated.id ? updated : p)));

	const rename = (p: Project, name: string) => attempt(async () => patch(await api.renameProject(p, name)), load);
	const move = (p: Project, parentID: string | null) =>
		attempt(async () => patch(await api.moveProject(p, parentID)), load);
	const add = (parentID: string, name: string) =>
		attempt(async () => (projects = [...projects, await api.createProject(name, parentID)]));
	const remove = (p: Project) =>
		attempt(async () => {
			await api.deleteProject(p.id);
			await load();
		}, load);
</script>

<div class="mx-auto flex min-h-dvh max-w-5xl flex-col overflow-x-clip">
	<header class="flex items-center justify-between gap-2 border-b px-4 py-2">
		<div class="flex items-center gap-2">
			<Button
				variant="outline"
				size="sm"
				class="md:hidden"
				aria-expanded={navOpen}
				aria-controls="main-nav"
				onclick={() => (navOpen = !navOpen)}
			>
				{t('nav.openMenu')}
			</Button>
			<span class="font-semibold">{t('app.name')}</span>
		</div>
		<div class="flex items-center gap-2">
			<span class="text-muted-foreground hidden text-sm sm:inline">
				{t('nav.signedInAs', { name: auth.user?.displayName ?? '' })}
			</span>
			<Button variant="outline" size="sm" onclick={() => auth.logout()}>{t('nav.logout')}</Button>
		</div>
	</header>

	{#if notice.text}
		<div
			role={notice.conflict ? 'status' : 'alert'}
			class="bg-muted flex items-start justify-between gap-2 border-b px-4 py-2 text-sm"
			data-testid="notice"
		>
			<span>
				{#if notice.conflict}<strong>{t('conflict.title')}.</strong>{/if}
				{notice.text}
			</span>
			<Button variant="ghost" size="xs" onclick={() => notice.clear()}>{t('common.cancel')}</Button>
		</div>
	{/if}

	<div class="flex flex-1 flex-col md:flex-row">
		{#if navOpen}
			<button
				type="button"
				class="fixed inset-0 z-30 bg-black/40 md:hidden"
				aria-label={t('common.cancel')}
				tabindex="-1"
				onclick={() => (navOpen = false)}
			></button>
		{/if}
		<nav
			id="main-nav"
			class="bg-background flex-col gap-3 p-3 md:static md:flex md:w-72 md:shrink-0 md:border-r {navOpen
				? 'fixed inset-y-0 left-0 z-40 flex w-72 max-w-[85vw] overflow-y-auto border-r shadow-lg'
				: 'hidden'}"
			aria-label={t('projects.title')}
		>
			<ul class="flex flex-col" aria-label={t('nav.views')}>
				{#each VIEWS as v (v)}
					<li>
						<button
							class={['min-h-9 w-full rounded-md px-2 text-left text-sm', view === v ? 'bg-muted font-medium' : 'hover:bg-muted/60']}
							aria-current={view === v ? 'page' : undefined}
							onclick={() => ((view = v), (navOpen = false))}>{t(`nav.${v}` as MessageKey)}</button
						>
					</li>
				{/each}
			</ul>
			<h2 class="text-muted-foreground text-xs font-medium tracking-wide uppercase">{t('projects.title')}</h2>
			<form class="flex gap-1" onsubmit={addRoot}>
				<Input bind:value={newName} placeholder={t('projects.newPlaceholder')} aria-label={t('projects.newPlaceholder')} />
				<Button type="submit" size="lg">{t('projects.add')}</Button>
			</form>
			{#if tree.length === 0}
				<p class="text-muted-foreground text-sm">{t('projects.empty')}</p>
			{/if}
			<ul>
				{#each tree as node (node.project.id)}
					<ProjectItem
						{node}
						all={projects}
						{selectedID}
						onselect={(id) => {
							selectedID = id;
							view = 'project';
							navOpen = false;
						}}
						onrename={rename}
						onadd={add}
						onmove={move}
						ondelete={remove}
					/>
				{/each}
			</ul>
		</nav>

		<main class="min-w-0 flex-1 p-4">
			{#if view === 'today' || view === 'upcoming' || view === 'upNext'}
				<PlanningView mode={view} />
			{:else if view === 'search'}
				<SearchView
					{projects}
					onopen={(id) => {
						selectedID = id;
						view = 'project';
						tab = 'list';
					}}
				/>
			{:else if view === 'teams'}
				<TeamsView />
			{:else if view === 'account'}
				<AccountView />
			{:else if selected}
				<div class="mb-3 flex gap-1" role="tablist">
					{#each ['list', 'board', 'milestones', 'sharing'] as const as tb (tb)}
						<Button size="sm" role="tab" aria-selected={tab === tb} variant={tab === tb ? 'default' : 'outline'} onclick={() => (tab = tb)}>
							{t(`view.${tb}` as MessageKey)}
						</Button>
					{/each}
				</div>
				{#if tab === 'board'}
					<h2 class="mb-3 text-xl font-semibold" data-testid="task-heading">{selected.name}</h2>
					<BoardView project={selected} />
				{:else if tab === 'milestones'}
					<MilestonesPanel project={selected} />
				{:else if tab === 'sharing'}
					<h2 class="mb-3 text-xl font-semibold" data-testid="task-heading">{selected.name}</h2>
					<SharingPanel project={selected} onchanged={load} />
				{:else}
					<TaskPanel project={selected} />
				{/if}
			{:else}
				<p class="text-muted-foreground text-sm">{t('tasks.selectProject')}</p>
			{/if}
		</main>
	</div>
</div>
