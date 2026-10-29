<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type Project } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { buildTree } from '#lib/projectTree.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { theme } from '#lib/theme.svelte.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import type { Component } from 'svelte';
	import CalendarCheck from '@lucide/svelte/icons/calendar-check';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import ListChecks from '@lucide/svelte/icons/list-checks';
	import Search from '@lucide/svelte/icons/search';
	import Users from '@lucide/svelte/icons/users';
	import UserRound from '@lucide/svelte/icons/user-round';
	import FolderTree from '@lucide/svelte/icons/folder-tree';
	import FolderOpen from '@lucide/svelte/icons/folder-open';
	import LogOut from '@lucide/svelte/icons/log-out';
	import Sun from '@lucide/svelte/icons/sun';
	import Moon from '@lucide/svelte/icons/moon';
	import Monitor from '@lucide/svelte/icons/monitor';
	import CircleCheckBig from '@lucide/svelte/icons/circle-check-big';
	import X from '@lucide/svelte/icons/x';
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
	type Icon = Component<{ class?: string; 'aria-hidden'?: 'true' | boolean }>;
	const PLAN_VIEWS: { v: View; icon: Icon }[] = [
		{ v: 'today', icon: CalendarCheck },
		{ v: 'upcoming', icon: CalendarClock },
		{ v: 'upNext', icon: ListChecks }
	];
	const TOOL_VIEWS: { v: View; icon: Icon }[] = [
		{ v: 'search', icon: Search },
		{ v: 'teams', icon: Users }
	];
	const themeIcon = $derived(theme.mode === 'dark' ? Moon : theme.mode === 'light' ? Sun : Monitor);
	/** Names of the selected project's ancestors, outermost first, for the page header. */
	const trail = $derived.by(() => {
		const out: string[] = [];
		let p = selected;
		while (p?.parentID) {
			p = projects.find((x) => x.id === p!.parentID) ?? null;
			if (p) out.unshift(p.name);
		}
		return out;
	});
	const navItem =
		'flex min-h-9 w-full items-center gap-2.5 rounded-lg px-2.5 text-left text-sm font-medium text-muted-foreground transition-colors hover:bg-muted hover:text-foreground aria-[current=page]:bg-ui-accent-soft aria-[current=page]:text-ui-accent-ink aria-[current=page]:glow-accent';
	function go(v: View) {
		view = v;
		navOpen = false;
	}
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

{#snippet viewButton(v: View, Icon: Icon)}
	<li>
		<button class={navItem} aria-current={view === v ? 'page' : undefined} onclick={() => go(v)}>
			<Icon class="size-4 shrink-0" aria-hidden="true" />
			<span class="truncate">{t(`nav.${v}` as MessageKey)}</span>
		</button>
	</li>
{/snippet}

<div class="min-h-dvh">
	{#if navOpen}
		<button
			type="button"
			class="fixed inset-0 z-40 bg-black/50 backdrop-blur-[2px] menu:hidden"
			aria-label={t('nav.closeNav')}
			tabindex="-1"
			onclick={() => (navOpen = false)}
		></button>
	{/if}

	<nav
		id="main-nav"
		class={[
			'bg-sidebar text-sidebar-foreground flex-col border-r',
			'menu:fixed menu:inset-y-0 menu:left-0 menu:z-30 menu:flex menu:w-72',
			navOpen ? 'fixed inset-y-0 left-0 z-50 flex w-72 max-w-[85vw] shadow-pop' : 'hidden'
		]}
		aria-label={t('projects.title')}
	>
		<div class="flex items-center gap-2.5 px-4 pt-4 pb-3">
			<span class="bg-ui-accent text-ui-accent-foreground inline-flex size-8 items-center justify-center rounded-lg">
				<CircleCheckBig class="size-[18px]" aria-hidden="true" />
			</span>
			<span class="text-[17px] font-semibold tracking-tight">{t('app.name')}</span>
			<Button variant="ghost" size="icon-sm" class="ml-auto menu:hidden" aria-label={t('nav.closeNav')} onclick={() => (navOpen = false)}>
				<X aria-hidden="true" />
			</Button>
		</div>

		<div class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-3 pb-3">
			<div>
				<p class="text-muted-foreground px-2.5 pb-1 text-[11px] font-semibold tracking-wider uppercase">{t('nav.sectionPlanning')}</p>
				<ul class="flex flex-col gap-0.5" aria-label={t('nav.views')}>
					{#each PLAN_VIEWS as item (item.v)}{@render viewButton(item.v, item.icon)}{/each}
				</ul>
			</div>
			<div>
				<p class="text-muted-foreground px-2.5 pb-1 text-[11px] font-semibold tracking-wider uppercase">{t('nav.sectionTools')}</p>
				<ul class="flex flex-col gap-0.5">
					{#each TOOL_VIEWS as item (item.v)}{@render viewButton(item.v, item.icon)}{/each}
				</ul>
			</div>
			<div class="flex flex-col gap-2">
				<h2 class="text-muted-foreground px-2.5 text-[11px] font-semibold tracking-wider uppercase">{t('projects.title')}</h2>
				<form class="flex gap-1.5" onsubmit={addRoot}>
					<Input bind:value={newName} placeholder={t('projects.newPlaceholder')} aria-label={t('projects.newPlaceholder')} />
					<Button type="submit" size="lg">{t('projects.add')}</Button>
				</form>
				{#if tree.length === 0}
					<p class="text-muted-foreground px-2.5 text-sm">{t('projects.empty')}</p>
				{/if}
				<ul>
					{#each tree as node (node.project.id)}
						<ProjectItem
							{node}
							all={projects}
							selectedID={view === 'project' ? selectedID : null}
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
			</div>
		</div>

		<div class="flex flex-col gap-0.5 border-t p-3">
			<button class={navItem} aria-current={view === 'account' ? 'page' : undefined} onclick={() => go('account')}>
				<UserRound class="size-4 shrink-0" aria-hidden="true" />
				<span class="truncate">{t('nav.account')}</span>
			</button>
			<button class={navItem} onclick={() => auth.logout()}>
				<LogOut class="size-4 shrink-0" aria-hidden="true" />
				<span class="truncate">{t('nav.logout')}</span>
			</button>
		</div>
	</nav>

	<div class="flex min-h-dvh min-w-0 flex-col menu:pl-72">
		<header class="bg-background/85 sticky top-0 z-20 flex h-14 items-center gap-3 border-b px-4 backdrop-blur menu:px-6">
			<span class="flex items-center gap-2 font-semibold menu:hidden">
				<span class="bg-ui-accent text-ui-accent-foreground inline-flex size-7 items-center justify-center rounded-md">
					<CircleCheckBig class="size-4" aria-hidden="true" />
				</span>
				{t('app.name')}
			</span>
			<span class="text-muted-foreground hidden min-w-0 flex-1 truncate text-sm menu:block" data-testid="signed-in-as">
				{t('nav.signedInAs', { name: auth.user?.displayName ?? '' })}
			</span>
			<span class="flex-1 menu:hidden"></span>
			<Button variant="ghost" size="icon" aria-label={t(`nav.theme.${theme.mode}` as MessageKey)} title={t(`nav.theme.${theme.mode}` as MessageKey)} onclick={() => theme.cycle()}>
				{@const ThemeIcon = themeIcon}
				<ThemeIcon aria-hidden="true" />
			</Button>
		</header>

		{#if notice.text}
			<div
				role={notice.conflict ? 'status' : 'alert'}
				class="border-warning/30 bg-warning-soft text-foreground mx-4 mt-4 flex items-start justify-between gap-2 rounded-lg border px-3 py-2 text-sm menu:mx-6"
				data-testid="notice"
			>
				<span>
					{#if notice.conflict}<strong>{t('conflict.title')}.</strong>{/if}
					{notice.text}
				</span>
				<Button variant="ghost" size="xs" onclick={() => notice.clear()}>{t('common.cancel')}</Button>
			</div>
		{/if}

		<main class="mx-auto w-full max-w-4xl min-w-0 flex-1 px-4 pt-5 pb-28 menu:px-6 menu:pt-8 menu:pb-12">
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
				<PageHeader title={selected.name} testid="task-heading">
					{#snippet actions()}
						{#if trail.length > 0}
							<span class="text-muted-foreground flex items-center gap-1.5 text-sm"><FolderTree class="size-4" aria-hidden="true" />{trail.join(' / ')}</span>
						{/if}
					{/snippet}
				</PageHeader>
				<div class="mb-5 flex gap-1 overflow-x-auto border-b" role="tablist" aria-label={t('nav.projectTabs')}>
					{#each ['list', 'board', 'milestones', 'sharing'] as const as tb (tb)}
						<button
							type="button"
							role="tab"
							aria-selected={tab === tb}
							class={[
								'-mb-px shrink-0 border-b-2 px-3 py-2 text-sm font-medium whitespace-nowrap transition-colors',
								tab === tb ? 'border-ui-accent text-foreground' : 'text-muted-foreground hover:text-foreground border-transparent'
							]}
							onclick={() => (tab = tb)}
						>
							{t(`view.${tb}` as MessageKey)}
						</button>
					{/each}
				</div>
				{#if tab === 'board'}
					<BoardView project={selected} />
				{:else if tab === 'milestones'}
					<MilestonesPanel project={selected} />
				{:else if tab === 'sharing'}
					<SharingPanel project={selected} onchanged={load} />
				{:else}
					<TaskPanel project={selected} />
				{/if}
			{:else}
				<EmptyState title={t('nav.noProjectTitle')} icon={FolderOpen}>
					<p>{t('nav.noProjectHint')}</p>
				</EmptyState>
			{/if}
		</main>
	</div>

	<nav
		class="bg-background/95 fixed inset-x-0 bottom-0 z-30 grid grid-cols-5 border-t pb-[env(safe-area-inset-bottom)] backdrop-blur menu:hidden"
		aria-label={t('nav.main')}
	>
		{#each [{ v: 'today', icon: CalendarCheck }, { v: 'search', icon: Search }] as item (item.v)}
			{@render tabButton(t(`nav.${item.v}` as MessageKey), item.icon, view === item.v, () => go(item.v as View))}
		{/each}
		{@render tabButton(t('nav.openMenu'), FolderTree, navOpen, () => (navOpen = !navOpen), navOpen, 'main-nav')}
		{#each [{ v: 'teams', icon: Users }, { v: 'account', icon: UserRound }] as item (item.v)}
			{@render tabButton(t(`nav.${item.v}` as MessageKey), item.icon, view === item.v, () => go(item.v as View))}
		{/each}
	</nav>
</div>

{#snippet tabButton(label: string, Icon: Icon, active: boolean, onclick: () => void, expanded?: boolean, controls?: string)}
	<button
		type="button"
		class={[
			'flex min-h-14 flex-col items-center justify-center gap-0.5 px-1 text-[11px] font-medium transition-colors',
			active ? 'text-ui-accent-ink' : 'text-muted-foreground'
		]}
		aria-current={active && expanded === undefined ? 'page' : undefined}
		aria-expanded={expanded}
		aria-controls={controls}
		{onclick}
	>
		<Icon class="size-5" aria-hidden="true" />
		<span>{label}</span>
	</button>
{/snippet}
