<script lang="ts">
	import { api, type Team, type TeamMembership } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	let teams = $state<Team[]>([]);
	let invitations = $state<TeamMembership[]>([]);
	let selectedID = $state<string | null>(null);
	let members = $state<TeamMembership[]>([]);
	let newName = $state('');
	let inviteID = $state('');

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
		if (await attempt(async () => { await api.putTeamMember(selectedID!, id, false); await loadMembers(); }, loadMembers)) inviteID = '';
	}
	const setAdmin = (m: TeamMembership, isAdmin: boolean) =>
		attempt(async () => { await api.putTeamMember(m.teamID, m.userID, isAdmin); await loadMembers(); }, loadMembers);
	const remove = (m: TeamMembership) =>
		attempt(async () => { await api.removeTeamMember(m.teamID, m.userID); await loadMembers(); }, loadMembers);
</script>

<section class="flex flex-col gap-4">
	<h2 class="text-xl font-semibold" data-testid="view-heading">{t('teams.title')}</h2>

	{#if invitations.length > 0}
		<div class="flex flex-col gap-1">
			<h3 class="text-sm font-medium">{t('teams.invitations')}</h3>
			{#each invitations as m (m.id)}
				<div class="flex items-center gap-2 rounded-md border p-2 text-sm">
					<span class="flex-1">{t('teams.invitedTo', { name: teams.find((x) => x.id === m.teamID)?.name ?? t('teams.unknownTeam') })}</span>
					<Button size="sm" onclick={() => accept(m)}>{t('teams.accept')}</Button>
				</div>
			{/each}
		</div>
	{/if}

	<form class="flex gap-2" onsubmit={create}>
		<Input bind:value={newName} placeholder={t('teams.new')} aria-label={t('teams.new')} />
		<Button type="submit" size="lg">{t('teams.create')}</Button>
	</form>

	{#if teams.length === 0}<p class="text-muted-foreground text-sm">{t('teams.empty')}</p>{/if}
	<ul class="flex flex-wrap gap-1">
		{#each teams as team (team.id)}
			<li>
				<Button size="sm" variant={selectedID === team.id ? 'default' : 'outline'} onclick={() => (selectedID = team.id)} data-testid="team-item">{team.name}</Button>
			</li>
		{/each}
	</ul>

	{#if selected}
		<div class="flex flex-col gap-2">
			<h3 class="text-sm font-medium">{t('teams.members', { name: selected.name })}</h3>
			<ul class="flex flex-col gap-1">
				{#each members as m (m.id)}
					<li class="flex flex-wrap items-center gap-2 rounded-md border p-2 text-sm" data-testid="team-member">
						<span class="flex-1 font-mono text-xs break-all">{m.userID === auth.user?.id ? t('teams.you') : m.userID}</span>
						{#if m.userID === selected.founderID}<span class="text-muted-foreground text-xs">{t('teams.founder')}</span>{/if}
						{#if !m.accepted}<span class="text-muted-foreground text-xs">{t('teams.pending')}</span>{/if}
						{#if m.isAdmin}<span class="bg-muted rounded px-1.5 py-0.5 text-xs">{t('teams.admin')}</span>{/if}
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
				<form class="flex gap-2" onsubmit={invite}>
					<Input bind:value={inviteID} placeholder={t('teams.memberID')} aria-label={t('teams.memberID')} />
					<Button type="submit" size="lg" variant="outline">{t('teams.invite')}</Button>
				</form>
				<p class="text-muted-foreground text-xs">{t('teams.memberIDHint')}</p>
			{/if}
		</div>
	{:else if teams.length > 0}
		<p class="text-muted-foreground text-sm">{t('teams.select')}</p>
	{/if}
</section>
