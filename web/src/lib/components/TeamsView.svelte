<script lang="ts">
	import { onMount } from 'svelte';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';
	import { api, type Team, type TeamMembership } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { memberLabel } from '#lib/people.js';
	import PersonPicker from './PersonPicker.svelte';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { loadManagedGrants, projectsOfTeam } from '#lib/accessOverview.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { ui } from '#lib/ui.svelte.js';
	import type { ProjectGrant } from '#lib/api.js';
	import PageHeader from './app/PageHeader.svelte';
	import Panel from './app/Panel.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import UsersIcon from '@lucide/svelte/icons/users';
	import Plus from '@lucide/svelte/icons/plus';
	import UserPlus from '@lucide/svelte/icons/user-plus';

	let teams = $state<Team[]>([]);
	let invitations = $state<TeamMembership[]>([]);
	let selectedID = $state<string | null>(null);
	let members = $state<TeamMembership[]>([]);
	let newName = $state('');
	let inviteID = $state('');
	let pickerKey = $state(0);
	let grants = $state<Map<string, ProjectGrant[]>>(new Map());
	let confirm = $state<{ kind: 'remove' | 'leave' | 'decline'; id: string } | null>(null);
	let info = $state<string | null>(null);
	const me = $derived(auth.user?.id);
	const teamProjects = $derived(selectedID ? projectsOfTeam(workspace.projects, grants, selectedID) : []);

	const selected = $derived(teams.find((x) => x.id === selectedID) ?? null);
	const iAmAdmin = $derived(members.some((m) => m.userID === auth.user?.id && m.isAdmin && m.accepted));

	/**
	 * All three loaders publish only if no newer call of the same loader was started meanwhile and only when the data
	 * changed, so a slow older response cannot overwrite newer data and a live refresh causes no needless re-render.
	 */
	let loadSeq = 0;
	let membersSeq = 0;
	let grantsSeq = 0;
	async function load() {
		const seq = ++loadSeq;
		const [nextTeams, nextInvitations] = await Promise.all([api.listTeams(), api.teamInvitations()]);
		if (seq !== loadSeq) return;
		if (!sameList(teams, nextTeams)) teams = nextTeams;
		if (!sameList(invitations, nextInvitations)) invitations = nextInvitations;
		if (selectedID && !nextTeams.some((x) => x.id === selectedID)) selectedID = null;
	}
	async function loadMembers() {
		const seq = ++membersSeq;
		const id = selectedID;
		const next = id ? await api.teamMembers(id) : [];
		if (seq !== membersSeq || id !== selectedID) return;
		if (!sameList(members, next)) members = next;
	}
	async function loadGrants() {
		const seq = ++grantsSeq;
		const next = await loadManagedGrants(workspace.projects);
		if (seq === grantsSeq) grants = next;
	}
	$effect(() => {
		attempt(load);
	});
	$effect(() => {
		void selectedID;
		attempt(loadMembers);
	});
	$effect(() => {
		// Also after changes made elsewhere in the app (share dialog, other team actions) and whenever the project list changes.
		void selectedID;
		void workspace.projects;
		void ui.accessTick;
		if (selectedID) loadGrants().catch(() => undefined);
	});
	// Invitations, members and the shared projects change on other accounts' actions: follow the central live refresh.
	onMount(() =>
		startLiveRefresh(async () => {
			await Promise.allSettled([load(), loadMembers(), selectedID ? loadGrants() : undefined]);
		})
	);

	async function create(e: Event) {
		e.preventDefault();
		const name = newName.trim();
		if (!name) return;
		if (await attempt(async () => { const team = await api.createTeam(name); await load(); selectedID = team.id; })) newName = '';
	}
	const refreshAll = async () => {
		await Promise.all([load(), workspace.reloadTeams(), workspace.reloadProjects()]);
		ui.accessTick++;
	};
	const accept = (m: TeamMembership) =>
		attempt(async () => { await api.acceptTeam(m.teamID); await refreshAll(); info = t('teams.accepted'); }, refreshAll);
	/** Declining an invitation and leaving a team are the same call: withdraw the own membership. */
	const withdraw = (m: { teamID: string; userID: string }, text: string) =>
		attempt(async () => {
			await api.removeTeamMember(m.teamID, m.userID);
			confirm = null;
			await refreshAll();
			if (selectedID === m.teamID) selectedID = null;
			info = text;
		}, refreshAll);
	async function invite(e: Event) {
		e.preventDefault();
		const id = inviteID.trim();
		if (!id || !selectedID) return;
		if (await attempt(async () => { await api.putTeamMember(selectedID!, id, false); await loadMembers(); }, loadMembers)) {
			inviteID = '';
			pickerKey++;
		}
	}
	const setAdmin = (m: TeamMembership, isAdmin: boolean) =>
		attempt(async () => { await api.putTeamMember(m.teamID, m.userID, isAdmin); await loadMembers(); }, loadMembers);
	const remove = (m: TeamMembership) =>
		attempt(async () => { await api.removeTeamMember(m.teamID, m.userID); confirm = null; await loadMembers(); ui.accessTick++; }, loadMembers);
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('teams.title')} testid="view-heading" />
	<p class="text-muted-foreground max-w-2xl text-sm">{t('teams.intro')}</p>
	{#if info}<p class="bg-success-soft text-success rounded-lg px-3 py-2 text-sm" role="status" data-testid="teams-info">{info}</p>{/if}

	{#if invitations.length > 0}
		<Panel title={t('teams.invitations')}>
			{#each invitations as m (m.id)}
				<div class="flex items-center gap-2 rounded-lg border p-2.5 text-sm" data-testid="team-invitation">
					<span class="flex-1">{t('teams.invitedTo', { name: m.teamName ?? teams.find((x) => x.id === m.teamID)?.name ?? t('teams.unknownTeam') })}</span>
					<Button size="sm" onclick={() => accept(m)}>{t('teams.accept')}</Button>
					<Button size="sm" variant="ghost" data-testid="team-decline" onclick={() => withdraw(m, t('teams.declined'))}>{t('teams.decline')}</Button>
				</div>
			{/each}
		</Panel>
	{/if}

	<form class="flex gap-2" onsubmit={create}>
		<Input class="h-10" bind:value={newName} placeholder={t('teams.new')} aria-label={t('teams.new')} />
		<Button type="submit" class="h-10"><Plus aria-hidden="true" />{t('teams.create')}</Button>
	</form>

	{#if teams.length === 0}<EmptyState title={t('teams.empty')} icon={UsersIcon} />{/if}
	<ul class="flex flex-wrap gap-2">
		{#each teams as team (team.id)}
			<li>
				<Button size="sm" variant={selectedID === team.id ? 'default' : 'outline'} onclick={() => (selectedID = team.id)} data-testid="team-item">{team.name}</Button>
			</li>
		{/each}
	</ul>

	{#if selected}
		<Panel title={t('teams.members', { name: selected.name })}>
			<ul class="flex flex-col gap-2">
				{#each members as m (m.id)}
					<li class="flex flex-wrap items-center gap-2 rounded-lg border p-2.5 text-sm" data-testid="team-member">
						<span class="flex-1 break-all" title={m.userID}>{memberLabel(m, auth.user?.id, t('teams.you'))}</span>
						{#if m.userID === selected.founderID}<Badge>{t('teams.founder')}</Badge>{/if}
						{#if !m.accepted}<Badge variant="warning">{t('teams.pending')}</Badge>{/if}
						{#if m.isAdmin}<Badge variant="accent">{t('teams.admin')}</Badge>{/if}
						{#if iAmAdmin && m.userID === selected.founderID}
							<span class="text-muted-foreground text-xs" data-testid="team-founder-locked">{t('teams.founderLocked')}</span>
						{:else if iAmAdmin}
							{#if m.accepted}
								<Button size="xs" variant="ghost" onclick={() => setAdmin(m, !m.isAdmin)}>
									{m.isAdmin ? t('teams.removeAdmin') : t('teams.makeAdmin')}
								</Button>
							{/if}
							<Button size="xs" variant="destructive" onclick={() => (confirm = { kind: 'remove', id: m.userID })}>{t('teams.removeMember')}</Button>
						{/if}
						{#if confirm?.kind === 'remove' && confirm.id === m.userID}
							<div class="bg-muted/60 flex basis-full flex-wrap items-center gap-2 rounded-md p-2" data-testid="team-remove-confirm">
								<span class="flex-1">{t('teams.removeConfirm', { name: memberLabel(m, me, t('teams.you')) })}</span>
								<Button size="sm" variant="destructive" onclick={() => remove(m)}>{t('teams.removeYes')}</Button>
								<Button size="sm" variant="ghost" onclick={() => (confirm = null)}>{t('common.cancel')}</Button>
							</div>
						{/if}
					</li>
				{/each}
			</ul>
			<p class="text-muted-foreground text-xs" data-testid="team-role-help">{t('teams.roleYou')}: <strong>{iAmAdmin ? t('teams.roleAdmin') : t('teams.roleMember')}</strong>. {t('teams.roleHelp')}</p>
			{#if iAmAdmin}
				<form class="flex items-start gap-2" onsubmit={invite}>
					{#key pickerKey}<PersonPicker bind:value={inviteID} idLabel={t('teams.memberID')} />{/key}
					<Button type="submit" variant="outline" disabled={!inviteID.trim()}><UserPlus aria-hidden="true" />{t('teams.invite')}</Button>
				</form>
			{/if}
			{#if me && selected.founderID !== me}
				{#if confirm?.kind === 'leave'}
					<div class="bg-muted/60 flex flex-wrap items-center gap-2 rounded-md p-2 text-sm" data-testid="team-leave-confirm">
						<span class="flex-1">{t('teams.leaveConfirm', { name: selected.name })}</span>
						<Button size="sm" variant="destructive" onclick={() => withdraw({ teamID: selected.id, userID: me }, t('teams.left'))}>{t('teams.leaveYes')}</Button>
						<Button size="sm" variant="ghost" onclick={() => (confirm = null)}>{t('common.cancel')}</Button>
					</div>
				{:else}
					<div><Button size="sm" variant="outline" data-testid="team-leave" onclick={() => (confirm = { kind: 'leave', id: selected.id })}>{t('teams.leave')}</Button></div>
				{/if}
			{/if}
		</Panel>
		<Panel title={t('teams.projects')}>
			{#if teamProjects.length === 0}<p class="text-muted-foreground text-sm">{t('teams.noProjects')}</p>{/if}
			<ul class="flex flex-col gap-1" data-testid="team-projects">
				{#each teamProjects as tp (tp.project.id)}
					<li class="flex items-center gap-2 text-sm"><span class="flex-1 truncate">{tp.project.name}</span>{#if tp.via === 'owner'}<Badge>{t('share.owner')}</Badge>{:else if tp.role}<Badge variant="accent">{t(`sharing.role.${tp.role}`)}</Badge>{/if}</li>
				{/each}
			</ul>
			<p class="text-muted-foreground text-xs">{t('teams.projectsHint')}</p>
		</Panel>
	{:else if teams.length > 0}
		<p class="text-muted-foreground text-sm">{t('teams.select')}</p>
	{/if}
</section>
