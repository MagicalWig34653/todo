<script lang="ts">
	import { onMount } from 'svelte';
	import type { Component } from 'svelte';
	import type { Project } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Dialog from './app/Dialog.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import Sidebar, { type View } from './Sidebar.svelte';
	import QuickAdd from './QuickAdd.svelte';
	import ProjectPage from './ProjectPage.svelte';
	import InboxView from './InboxView.svelte';
	import FiltersLabelsView from './FiltersLabelsView.svelte';
	import AgentsView from './AgentsView.svelte';
	import CommandCenter from './CommandCenter.svelte';
	import ActivityView from './ActivityView.svelte';
	import PlanningView from './PlanningView.svelte';
	import SearchView from './SearchView.svelte';
	import TeamsView from './TeamsView.svelte';
	import SharingPanel from './SharingPanel.svelte';
	import AccountView from './AccountView.svelte';
	import CalendarCheck from '@lucide/svelte/icons/calendar-check';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import FolderOpen from '@lucide/svelte/icons/folder-open';
	import LayoutList from '@lucide/svelte/icons/layout-list';
	import PanelLeft from '@lucide/svelte/icons/panel-left';
	import Plus from '@lucide/svelte/icons/plus';
	import Search from '@lucide/svelte/icons/search';

	type Icon = Component<{ class?: string; 'aria-hidden'?: 'true' | boolean }>;

	let view = $state<View>('today');
	let selectedID = $state<string | null>(null);
	let drawerOpen = $state(false);
	let searchInitial = $state<{ labelID?: string; filterID?: string }>({});
	let searchKey = $state(0);
	let shareProject = $state<Project | null>(null);
	let shareOpen = $state(false);

	const selected = $derived(workspace.projects.find((p) => p.id === selectedID) ?? null);
	/** Ancestors of the selected project, outermost first, for the breadcrumb. */
	const trail = $derived.by(() => {
		const out: { id: string; name: string }[] = [];
		let p = selected;
		while (p?.parentID) {
			p = workspace.projects.find((x) => x.id === p!.parentID) ?? null;
			if (p) out.unshift({ id: p.id, name: p.name });
		}
		return out;
	});

	onMount(() => {
		attempt(() => workspace.reloadAll());
		// Keep the sidebar badge fresh (there is no sync feed for questions and reviews).
		const refresh = () => {
			if (document.visibilityState === 'visible') void workspace.reloadAttention();
		};
		const timer = setInterval(refresh, 60_000);
		document.addEventListener('visibilitychange', refresh);
		return () => {
			clearInterval(timer);
			document.removeEventListener('visibilitychange', refresh);
		};
	});

	function go(v: View) {
		if (v !== 'search') searchInitial = {};
		view = v;
		drawerOpen = false;
	}
	function openProject(id: string) {
		selectedID = id;
		view = 'project';
		drawerOpen = false;
	}
	function openSearch(initial: { labelID?: string; filterID?: string }) {
		searchInitial = initial;
		searchKey++;
		view = 'search';
	}
	function share(p: Project) {
		shareProject = p;
		shareOpen = true;
		drawerOpen = false;
	}

	/** `q` opens quick add unless the user is typing or a dialog is open. */
	function onkeydown(e: KeyboardEvent) {
		if (e.key !== 'q' || e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented) return;
		const el = e.target as HTMLElement | null;
		if (el && (el.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName))) return;
		if (document.querySelector('[aria-modal="true"]')) return;
		e.preventDefault();
		ui.quickAdd = true;
	}
</script>

<svelte:window {onkeydown} />

{#snippet tabButton(label: string, Ic: Icon, active: boolean, onclick: () => void, expanded?: boolean, controls?: string)}
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
		<Ic class="size-5" aria-hidden="true" />
		<span>{label}</span>
	</button>
{/snippet}

<div class="min-h-dvh">
	{#if drawerOpen}
		<button
			type="button"
			class="fixed inset-0 z-40 bg-black/50 backdrop-blur-[2px] menu:hidden"
			aria-label={t('nav.closeNav')}
			tabindex="-1"
			onclick={() => (drawerOpen = false)}
		></button>
	{/if}

	<Sidebar {view} {selectedID} {drawerOpen} onview={go} onproject={openProject} onshare={share} onclose={() => (drawerOpen = false)} />

	<div class={['flex min-h-dvh min-w-0 flex-col', !ui.sidebarCollapsed && 'menu:pl-72']}>
		<header class="bg-background/85 sticky top-0 z-20 flex h-12 items-center gap-1 border-b px-3 backdrop-blur menu:px-5">
			<Button
				variant="ghost"
				size="icon-sm"
				class="menu:hidden"
				aria-label={t('nav.openDrawer')}
				aria-expanded={drawerOpen}
				aria-controls="main-nav"
				onclick={() => (drawerOpen = !drawerOpen)}
			>
				<LayoutList aria-hidden="true" />
			</Button>
			{#if ui.sidebarCollapsed}
				<Button variant="ghost" size="icon-sm" class="hidden menu:inline-flex" aria-label={t('nav.expandSidebar')} onclick={() => ui.toggleSidebar()}>
					<PanelLeft aria-hidden="true" />
				</Button>
			{/if}
			{#if view === 'project' && selected && ui.toolbar}
				{@render ui.toolbar()}
			{:else}
				<span class="flex-1"></span>
			{/if}
		</header>

		{#if notice.text}
			<div
				role={notice.conflict ? 'status' : 'alert'}
				class="border-warning/30 bg-warning-soft text-foreground mx-4 mt-4 flex items-start justify-between gap-2 rounded-lg border px-3 py-2 text-sm menu:mx-8"
				data-testid="notice"
			>
				<span>
					{#if notice.conflict}<strong>{t('conflict.title')}.</strong>{/if}
					{notice.text}
				</span>
				<Button variant="ghost" size="xs" onclick={() => notice.clear()}>{t('common.cancel')}</Button>
			</div>
		{/if}

		<main class="w-full min-w-0 flex-1 px-4 pt-6 pb-36 menu:px-8 menu:pt-8 menu:pb-12">
			{#if view === 'project'}
				{#if selected}
					{#key selected.id}
						<ProjectPage project={selected} {trail} onselect={openProject} onshare={share} />
					{/key}
				{:else}
					<div class="mx-auto max-w-3xl">
						<EmptyState title={t('nav.noProjectTitle')} icon={FolderOpen}>
							<p>{t('nav.noProjectHint')}</p>
						</EmptyState>
					</div>
				{/if}
			{:else}
				<div class={['mx-auto', view === 'overview' ? 'max-w-none' : 'max-w-4xl']}>
					{#if view === 'today' || view === 'upcoming' || view === 'upNext'}
						<PlanningView mode={view} />
					{:else if view === 'overview'}
						<CommandCenter />
					{:else if view === 'inbox'}
						<InboxView onopen={openProject} />
					{:else if view === 'search'}
						{#key searchKey}
							<SearchView projects={workspace.projects} onopen={openProject} initial={searchInitial} />
						{/key}
					{:else if view === 'filters'}
						<FiltersLabelsView onsearch={openSearch} />
					{:else if view === 'teams'}
						<TeamsView />
					{:else if view === 'agents'}
						<AgentsView />
					{:else if view === 'activity'}
						<ActivityView onopen={openProject} />
					{:else if view === 'account'}
						<AccountView />
					{/if}
				</div>
			{/if}
		</main>
	</div>

	<button
		type="button"
		class="glow-accent bg-ui-accent text-ui-accent-foreground fixed right-4 bottom-[4.75rem] z-30 inline-flex size-14 items-center justify-center rounded-full shadow-pop menu:hidden"
		aria-label={t('quickAdd.open')}
		data-testid="fab"
		onclick={() => (ui.quickAdd = true)}
	>
		<Plus class="size-6" aria-hidden="true" />
	</button>

	<nav
		class="bg-background/95 fixed inset-x-0 bottom-0 z-30 grid grid-cols-4 border-t pb-[env(safe-area-inset-bottom)] backdrop-blur menu:hidden"
		aria-label={t('nav.main')}
	>
		{@render tabButton(t('nav.today'), CalendarCheck, view === 'today', () => go('today'))}
		{@render tabButton(t('nav.upcoming'), CalendarClock, view === 'upcoming', () => go('upcoming'))}
		{@render tabButton(t('nav.search'), Search, view === 'search', () => go('search'))}
		{@render tabButton(t('nav.openMenu'), LayoutList, drawerOpen, () => (drawerOpen = !drawerOpen), drawerOpen, 'main-nav')}
	</nav>
</div>

<QuickAdd currentProjectID={view === 'project' ? selectedID : null} />

<Dialog bind:open={shareOpen} title={t('project.shareTitle', { name: shareProject?.name ?? '' })} class="max-w-2xl" testid="share-dialog">
	{#if shareProject}
		{@const p = workspace.projects.find((x) => x.id === shareProject!.id) ?? shareProject}
		<SharingPanel project={p} onchanged={() => workspace.reloadProjects()} />
	{/if}
</Dialog>
