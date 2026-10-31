<script lang="ts" module>
export type View =
	| 'project'
	| 'forYou'
	| 'inbox'
	| 'overview'
	| 'today'
	| 'upcoming'
	| 'upNext'
	| 'search'
	| 'filters'
	| 'teams'
	| 'agents'
	| 'activity'
	| 'account'
	| 'help';
</script>

<script lang="ts">
	import type { Component } from 'svelte';
	import { api, type Project, type TeamMembership } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { buildTree, flatten, type DropPlan } from '#lib/projectTree.js';
	import { isOwner } from '#lib/access.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Dialog from './app/Dialog.svelte';
	import Popover from './app/Popover.svelte';
	import ProjectItem from './ProjectItem.svelte';
	import Bell from '@lucide/svelte/icons/bell';
	import CalendarCheck from '@lucide/svelte/icons/calendar-check';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import CirclePlus from '@lucide/svelte/icons/circle-plus';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import Inbox from '@lucide/svelte/icons/inbox';
	import LayoutGrid from '@lucide/svelte/icons/layout-grid';
	import ListChecks from '@lucide/svelte/icons/list-checks';
	import PanelLeft from '@lucide/svelte/icons/panel-left';
	import Plus from '@lucide/svelte/icons/plus';
	import Search from '@lucide/svelte/icons/search';
	import Users from '@lucide/svelte/icons/users';
	import UserRound from '@lucide/svelte/icons/user-round';
	import Bot from '@lucide/svelte/icons/bot';
	import Gauge from '@lucide/svelte/icons/gauge';
	import Sparkles from '@lucide/svelte/icons/sparkles';
	import Activity from '@lucide/svelte/icons/activity';
	import X from '@lucide/svelte/icons/x';

	type Icon = Component<{ class?: string; 'aria-hidden'?: 'true' | boolean }>;

	interface Props {
		view: View;
		selectedID: string | null;
		/** Mobile drawer instead of the fixed desktop column. */
		drawerOpen: boolean;
		onview: (v: View) => void;
		onproject: (id: string) => void;
		onshare: (p: Project) => void;
		onclose: () => void;
	}
	let { view, selectedID, drawerOpen, onview, onproject, onshare, onclose }: Props = $props();

	const MORE: { v: View; icon: Icon }[] = [
		{ v: 'upNext', icon: ListChecks },
		{ v: 'agents', icon: Bot },
		{ v: 'activity', icon: Activity },
		{ v: 'account', icon: UserRound }
	];
	const moreViews = new Set<View>(MORE.map((m) => m.v));

	let moreOpen = $state(false);
	let favOpen = $state(true);
	let projectsOpen = $state(true);
	let teamsOpen = $state(true);
	let sharedOpen = $state(true);
	let addOpen = $state(false);
	let addName = $state('');
	let addParent = $state('');
	let bellOpen = $state(false);

	// "Mehr" shows its entries while one of them is the current page.
	const moreShown = $derived(moreOpen || moreViews.has(view));
	const fullTree = $derived(buildTree(workspace.projects));
	/** Own roots stay under "Meine Projekte"; roots owned by other people form "Mit mir geteilt". */
	const tree = $derived(fullTree.filter((n) => isOwner(n.project)));
	const sharedTree = $derived(fullTree.filter((n) => !isOwner(n.project)));
	const favorites = $derived(workspace.favorites);
	const parents = $derived(flatten(fullTree));

	const row =
		'flex min-h-9 w-full items-center gap-2.5 rounded-lg px-2.5 text-left text-sm font-medium text-foreground/85 transition-colors hover:bg-muted aria-[current=page]:bg-ui-accent-soft aria-[current=page]:text-ui-accent-ink aria-[current=page]:glow-accent';
	const sectionHead = 'text-muted-foreground flex items-center justify-between px-2.5 pb-1 text-[13px] font-semibold';

	const go = (v: View) => () => onview(v);

	function openAdd(parentID = '') {
		addName = '';
		addParent = parentID;
		addOpen = true;
	}
	async function createProject(e: Event) {
		e.preventDefault();
		const name = addName.trim();
		if (!name) return;
		let created: Project | null = null;
		const ok = await attempt(async () => {
			const project = await api.createProject(name, addParent || null);
			created = project;
			workspace.projects = [...workspace.projects, project];
		});
		if (ok) {
			addOpen = false;
			if (created) onproject((created as Project).id);
		}
	}

	const patch = (updated: Project) => (workspace.projects = workspace.projects.map((p) => (p.id === updated.id ? updated : p)));
	const reload = () => workspace.reloadProjects();
	const rename = (p: Project, name: string) => attempt(async () => patch(await api.renameProject(p, name)), reload);
	const move = (p: Project, parentID: string | null) => attempt(async () => patch(await api.moveProject(p, parentID)), reload);
	const addSub = (parentID: string, name: string) =>
		attempt(async () => (workspace.projects = [...workspace.projects, await api.createProject(name, parentID)]));
	const favorite = (p: Project) => attempt(() => workspace.toggleFavorite(p.id));
	/** Own order only unless the parent changes (then `manage` is needed and the project version is sent). */
	const reorder = (p: Project, plan: DropPlan) =>
		attempt(async () => {
			await api.putProjectPosition(p, plan.index, plan.reparent ? plan.parentID : undefined);
			await workspace.reloadProjects();
		}, reload);
	const remove = (p: Project) =>
		attempt(async () => {
			await api.deleteProject(p.id);
			await Promise.all([workspace.reloadProjects(), workspace.reloadTasks()]);
		}, reload);

	const accept = (m: TeamMembership) =>
		attempt(async () => {
			await api.acceptTeam(m.teamID);
			await workspace.reloadTeams();
		});
</script>

{#snippet navRow(v: View, Ic: Icon, label: string, count = 0, cls = '', badge = false)}
	<li>
		<button class={[row, cls]} aria-current={view === v ? 'page' : undefined} onclick={go(v)}>
			<Ic class="size-[18px] shrink-0 opacity-80" aria-hidden="true" />
			<span class="truncate">{label}</span>
			{#if count > 0 && badge}
				<span class="bg-ui-accent text-ui-accent-foreground ml-auto inline-flex min-w-5 items-center justify-center rounded-full px-1.5 text-xs font-semibold" data-tabular data-testid="nav-badge-{v}" title={t('sidebar.teamsBadge', { count })}>{count}</span>
			{:else if count > 0}
				<span class="text-muted-foreground ml-auto text-xs font-normal" data-tabular>{count}</span>
			{/if}
		</button>
	</li>
{/snippet}

{#snippet sectionToggle(open: boolean, toggle: () => void, label: string)}
	<button type="button" class="text-muted-foreground hover:bg-muted inline-flex size-6 items-center justify-center rounded" aria-label={t('common.toggleSection', { name: label })} aria-expanded={open} onclick={toggle}>
		<ChevronDown class={['size-4 transition-transform', !open && '-rotate-90']} aria-hidden="true" />
	</button>
{/snippet}

<nav
	id="main-nav"
	class={[
		'bg-sidebar text-sidebar-foreground flex-col border-r',
		ui.sidebarCollapsed ? 'menu:hidden' : 'menu:fixed menu:inset-y-0 menu:left-0 menu:z-30 menu:flex menu:w-72',
		drawerOpen ? 'fixed inset-y-0 left-0 z-50 flex w-[19rem] max-w-[88vw] shadow-pop' : 'hidden'
	]}
	aria-label={t('nav.sidebar')}
>
	<!-- Account menu, notifications, sidebar toggle -->
	<div class="flex items-center gap-1 px-3 pt-3 pb-1">
		<span class="flex-1 truncate px-1.5 text-sm font-semibold">{t('app.name')}</span>
		<Popover
			label={t('notifications.title')}
			align="end"
			bind:open={bellOpen}
			testid="notifications"
			class="text-muted-foreground hover:bg-muted relative inline-flex size-8 shrink-0 items-center justify-center rounded-lg"
			panelClass="w-72"
		>
			{#snippet trigger()}
				<Bell class="size-[18px]" aria-hidden="true" />
				{#if workspace.invitations.length > 0}
					<span class="bg-ui-accent absolute top-1 right-1 size-2 rounded-full" data-testid="notifications-dot"></span>
				{/if}
			{/snippet}
			{#snippet children(close)}
				<h3 class="px-2.5 py-1.5 text-sm font-semibold">{t('notifications.title')}</h3>
				{#if workspace.invitations.length === 0}
					<p class="text-muted-foreground px-2.5 pb-2 text-sm">{t('notifications.empty')}</p>
				{/if}
				{#each workspace.invitations as m (m.id)}
					<div class="flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm" data-testid="notification-invitation">
						<span class="min-w-0 flex-1">{t('teams.invitedTo', { name: m.teamName ?? t('teams.unknownTeam') })}</span>
						<Button size="sm" onclick={async () => { await accept(m); if (workspace.invitations.length === 0) close(); }}>{t('teams.accept')}</Button>
					</div>
				{/each}
			{/snippet}
		</Popover>
		<Button variant="ghost" size="icon-sm" class="hidden menu:inline-flex" aria-label={t('nav.collapseSidebar')} aria-pressed={ui.sidebarCollapsed} onclick={() => ui.toggleSidebar()}>
			<PanelLeft aria-hidden="true" />
		</Button>
		<Button variant="ghost" size="icon-sm" class="menu:hidden" aria-label={t('nav.closeNav')} onclick={onclose}>
			<X aria-hidden="true" />
		</Button>
	</div>

	<div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3 pt-1 pb-3">
		<button
			type="button"
			class="text-ui-accent-ink hover:bg-ui-accent-soft flex min-h-10 w-full items-center gap-2.5 rounded-lg px-2.5 text-left text-sm font-semibold"
			data-testid="quick-add-open"
			title={t('quickAdd.shortcut')}
			onclick={() => (ui.quickAdd = true)}
		>
			<CirclePlus class="size-6 shrink-0" aria-hidden="true" />{t('quickAdd.open')}
		</button>

		<ul class="flex flex-col gap-0.5" aria-label={t('nav.views')}>
			{@render navRow('forYou', Sparkles, t('nav.forYou'), workspace.attentionCount)}
			{@render navRow('search', Search, t('nav.search'))}
			{@render navRow('overview', Gauge, t('nav.overview'), workspace.attentionCount)}
			{@render navRow('inbox', Inbox, t('nav.inbox'), workspace.inboxCount)}
			{@render navRow('today', CalendarCheck, t('nav.today'), workspace.todayCount)}
			{@render navRow('upcoming', CalendarClock, t('nav.upcoming'))}
			{@render navRow('filters', LayoutGrid, t('nav.filters'))}
			{@render navRow('teams', Users, t('sidebar.teamsEntry'), workspace.invitations.length, '', true)}
			<li>
				<button class={row} aria-expanded={moreShown} onclick={() => (moreOpen = !moreShown)}>
					<Ellipsis class="size-[18px] shrink-0 opacity-80" aria-hidden="true" />
					<span class="truncate">{t('nav.more')}</span>
				</button>
				{#if moreShown}
					<ul class="mt-0.5 flex flex-col gap-0.5 pl-3">
						{#each MORE as m (m.v)}{@render navRow(m.v, m.icon, t(`nav.${m.v}` as MessageKey))}{/each}
					</ul>
				{/if}
			</li>
		</ul>

		{#if favorites.length > 0}
			<section aria-label={t('favorites.title')} data-testid="favorites">
				<div class={sectionHead}>
					<h2>{t('favorites.title')}</h2>
					{@render sectionToggle(favOpen, () => (favOpen = !favOpen), t('favorites.title'))}
				</div>
				{#if favOpen}
					<ul>
						{#each favorites as p (p.id)}
							<ProjectItem node={{ project: p, children: [] }} all={workspace.projects} flat selectedID={view === 'project' ? selectedID : null} onselect={onproject} onrename={rename} onadd={addSub} onmove={move} ondelete={remove} {onshare} onfavorite={favorite} onreorder={reorder} />
						{/each}
					</ul>
				{/if}
			</section>
		{/if}

		<section aria-label={t('projects.mine')}>
			<div class={sectionHead}>
				<h2>{t('projects.mine')}</h2>
				<span class="flex items-center gap-0.5">
					<button type="button" class="hover:bg-muted inline-flex size-6 items-center justify-center rounded" aria-label={t('projects.addProject')} data-testid="add-project" onclick={() => openAdd()}>
						<Plus class="size-4" aria-hidden="true" />
					</button>
					{@render sectionToggle(projectsOpen, () => (projectsOpen = !projectsOpen), t('projects.mine'))}
				</span>
			</div>
			{#if projectsOpen}
				{#if tree.length === 0}
					<p class="text-muted-foreground px-2.5 text-sm">{t('projects.empty')}</p>
				{/if}
				<ul>
					{#each tree as node (node.project.id)}
						<ProjectItem {node} all={workspace.projects} selectedID={view === 'project' ? selectedID : null} onselect={onproject} onrename={rename} onadd={addSub} onmove={move} ondelete={remove} {onshare} onfavorite={favorite} onreorder={reorder} />
					{/each}
				</ul>
			{/if}
		</section>

		{#if sharedTree.length > 0}
			<section aria-label={t('sidebar.shared')} data-testid="sidebar-shared">
				<div class={sectionHead}>
					<h2>{t('sidebar.shared')}</h2>
					{@render sectionToggle(sharedOpen, () => (sharedOpen = !sharedOpen), t('sidebar.shared'))}
				</div>
				{#if sharedOpen}
					<ul>
						{#each sharedTree as node (node.project.id)}
							<ProjectItem {node} all={workspace.projects} selectedID={view === 'project' ? selectedID : null} onselect={onproject} onrename={rename} onadd={addSub} onmove={move} ondelete={remove} {onshare} onfavorite={favorite} onreorder={reorder} />
						{/each}
					</ul>
				{/if}
			</section>
		{/if}

		{#if workspace.teams.length > 0}
			<section aria-label={t('sidebar.teams')} data-testid="sidebar-teams">
				<div class={sectionHead}>
					<h2>{t('sidebar.teams')}</h2>
					{@render sectionToggle(teamsOpen, () => (teamsOpen = !teamsOpen), t('sidebar.teams'))}
				</div>
				{#if teamsOpen}
					<ul>
						{#each workspace.teams as team (team.id)}
							<li>
								<button class={row} onclick={go('teams')}>
									<Users class="text-ui-accent-ink size-[18px] shrink-0" aria-hidden="true" /><span class="truncate">{team.name}</span>
								</button>
							</li>
						{/each}
					</ul>
				{/if}
			</section>
		{/if}
	</div>

</nav>

<Dialog bind:open={addOpen} title={t('projects.addProject')} testid="add-project-dialog">
	<form class="flex flex-col gap-3" onsubmit={createProject}>
		<Input data-autofocus bind:value={addName} placeholder={t('projects.newPlaceholder')} aria-label={t('projects.newPlaceholder')} class="h-10" />
		<label class="flex flex-col gap-1 text-xs font-medium">
			{t('projects.parent')}
			<Select bind:value={addParent}>
				<option value="">{t('projects.root')}</option>
				{#each parents as p (p.project.id)}<option value={p.project.id}>{'  '.repeat(p.depth)}{p.project.name}</option>{/each}
			</Select>
		</label>
		<div class="flex justify-end gap-2">
			<Button type="button" variant="ghost" onclick={() => (addOpen = false)}>{t('common.cancel')}</Button>
			<Button type="submit" disabled={!addName.trim()}>{t('projects.add')}</Button>
		</div>
	</form>
</Dialog>

