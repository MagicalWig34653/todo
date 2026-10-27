<script lang="ts">
	import { api, type Team, type TeamMembership } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { memberLabel } from '#lib/people.js';
	import PersonPicker from './PersonPicker.svelte';
	import { Badge } from '#lib/components/ui/badge/index.js';
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

	const selected = $derived(teams.find((x) => x.id === selectedID) ?? null);
	const iAmAdmin = $derived(members.some((m) => m.userID === auth.user?.id && m.isAdmin && m.accepted));

	async function load() {
		[teams, invitations] = await Promise.all([api.listTeams(), api.teamInvitations()]);
		if (selectedID && !teams.some((x) => x.id === selectedID)) selectedID = null;
	}
	async function loadMembers() {
		members = selectedID ? await api.teamMembers(selectedID) : [];
	}
	$effect(() => {
		attempt(load);
	});
	$effect(() => {
		void selectedID;
		attempt(loadMembers);
	});

	async function create(e: Event) {
		e.preventDefault();
		const name = newName.trim();
		if (!name) return;
		if (await attempt(async () => { const team = await api.createTeam(name); await load(); selectedID = team.id; })) newName = '';
	}
	const accept = (m: TeamMembership) => attempt(async () => { await api.acceptTeam(m.teamID); await load(); });
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
		attempt(async () => { await api.removeTeamMember(m.teamID, m.userID); await loadMembers(); }, loadMembers);
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('teams.title')} testid="view-heading" />

	{#if invitations.length > 0}
		<Panel title={t('teams.invitations')}>
			{#each invitations as m (m.id)}
				<div class="flex items-center gap-2 rounded-lg border p-2.5 text-sm" data-testid="team-invitation">
					<span class="flex-1">{t('teams.invitedTo', { name: m.teamName ?? teams.find((x) => x.id === m.teamID)?.name ?? t('teams.unknownTeam') })}</span>
					<Button size="sm" onclick={() => accept(m)}>{t('teams.accept')}</Button>
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
						{#if iAmAdmin}
							{#if m.accepted}
								<Button size="xs" variant="ghost" onclick={() => setAdmin(m, !m.isAdmin)}>
									{m.isAdmin ? t('teams.removeAdmin') : t('teams.makeAdmin')}
								</Button>
							{/if}
							<Button size="xs" variant="destructive" onclick={() => remove(m)}>{t('teams.removeMember')}</Button>
						{/if}
					</li>
				{/each}
			</ul>
			{#if iAmAdmin}
				<form class="flex items-start gap-2" onsubmit={invite}>
					{#key pickerKey}<PersonPicker bind:value={inviteID} idLabel={t('teams.memberID')} />{/key}
					<Button type="submit" variant="outline" disabled={!inviteID.trim()}><UserPlus aria-hidden="true" />{t('teams.invite')}</Button>
				</form>
			{/if}
		</Panel>
	{:else if teams.length > 0}
		<p class="text-muted-foreground text-sm">{t('teams.select')}</p>
	{/if}
</section>
