<script lang="ts">
	import { api, type OAuthGrant, type Passkey, type RunnerDevice, type SessionInfo } from '#lib/api.js';
	import { loadManagedGrants, sharedByMe } from '#lib/accessOverview.js';
	import { sharedWithMe, roleOf } from '#lib/access.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Avatar from './app/Avatar.svelte';
	import PageHeader from './app/PageHeader.svelte';
	import type { ProjectGrant } from '#lib/api.js';

	/** Account > "Berechtigungen & Zugriff": one place for teams, shared projects, invitations, apps/agents and sign-in. */
	let { onnav }: { onnav: (target: 'teams' | 'agents' | 'general' | 'project', projectID?: string) => void } = $props();

	let oauth = $state<OAuthGrant[]>([]);
	let devices = $state<RunnerDevice[]>([]);
	let passkeys = $state<Passkey[]>([]);
	let sessions = $state<SessionInfo[]>([]);
	let grants = $state<Map<string, ProjectGrant[]>>(new Map());
	let grantsLoaded = $state(false);

	async function load() {
		await Promise.all([workspace.reloadTeams(), workspace.reloadProjects()]);
		[oauth, devices, passkeys, sessions] = await Promise.all([api.listOAuthGrants(), api.listDevices(), api.listPasskeys(), api.listSessions()]);
	}
	$effect(() => {
		void ui.accessTick;
		attempt(load);
	});
	$effect(() => {
		const projects = workspace.projects;
		grantsLoaded = false;
		loadManagedGrants(projects).then((g) => {
			grants = g;
			grantsLoaded = true;
		});
	});

	const incoming = $derived(sharedWithMe(workspace.projects).filter((p) => !workspace.projects.some((x) => x.id === p.parentID && !x.isOwner)));
	const outgoing = $derived(sharedByMe(workspace.projects, grants));
	const activeOAuth = $derived(oauth.filter((g) => !g.revoked));
	const activeDevices = $derived(devices.filter((d) => !d.revokedAt));
	const activePasskeys = $derived(passkeys.filter((p) => !p.revokedAt));
	const accept = (teamID: string) =>
		attempt(async () => { await api.acceptTeam(teamID); await load(); ui.accessTick++; }, load);
	const decline = (teamID: string) =>
		attempt(async () => { await api.removeTeamMember(teamID, auth.user!.id); await load(); ui.accessTick++; }, load);
	const names = (list: ProjectGrant[]) => list.map((g) => g.principalName?.trim() || g.principalID.slice(0, 8));
</script>

<section class="flex flex-col gap-4" data-testid="access-overview">
	<p class="text-muted-foreground max-w-2xl text-sm">{t('access.intro')} <a class="text-ui-accent-ink underline underline-offset-2" href="https://magicalwig34653.github.io/todo/berechtigungen.html" target="_blank" rel="noopener noreferrer">{t('access.docs')}</a></p>

	{#if workspace.invitations.length > 0}
		<div class="bg-card flex flex-col gap-2 rounded-xl border p-4 shadow-card sm:p-5" data-testid="access-invitations">
			<h3 class="text-base font-semibold">{t('access.invitations')}</h3>
			{#each workspace.invitations as m (m.id)}
				<div class="flex flex-wrap items-center gap-2 rounded-lg border p-2.5 text-sm">
					<span class="flex-1">{t('teams.invitedTo', { name: m.teamName ?? t('teams.unknownTeam') })}</span>
					<Button size="sm" onclick={() => accept(m.teamID)}>{t('teams.accept')}</Button>
					<Button size="sm" variant="ghost" onclick={() => decline(m.teamID)}>{t('teams.decline')}</Button>
				</div>
			{/each}
		</div>
	{/if}

	<div class="bg-card flex flex-col gap-2 rounded-xl border p-4 shadow-card sm:p-5" data-testid="access-teams">
		<div class="flex items-center gap-2">
			<h3 class="flex-1 text-base font-semibold">{t('access.teams')}</h3>
			<Button size="sm" variant="outline" onclick={() => onnav('teams')}>{t('access.teams.manage')}</Button>
		</div>
		{#if workspace.teams.length === 0}<p class="text-muted-foreground text-sm">{t('access.teams.empty')}</p>{/if}
		<ul class="flex flex-col gap-1.5">
			{#each workspace.teams as team (team.id)}
				<li class="flex items-center gap-2 text-sm"><Avatar name={team.name} team size="sm" /><span class="flex-1 truncate">{team.name}</span>{#if team.founderID === auth.user?.id}<Badge>{t('teams.founder')}</Badge>{/if}</li>
			{/each}
		</ul>
	</div>

	<div class="bg-card flex flex-col gap-2 rounded-xl border p-4 shadow-card sm:p-5" data-testid="access-shared-with-me">
		<h3 class="text-base font-semibold">{t('access.sharedWithMe')}</h3>
		{#if incoming.length === 0}<p class="text-muted-foreground text-sm">{t('access.sharedWithMe.empty')}</p>{/if}
		<ul class="flex flex-col gap-1.5">
			{#each incoming as p (p.id)}
				<li class="flex flex-wrap items-center gap-2 text-sm" data-testid="access-incoming">
					<button type="button" class="text-ui-accent-ink min-w-0 flex-1 truncate text-left underline underline-offset-2" onclick={() => onnav('project', p.id)}>{p.name}</button>
					{#if p.ownerName}<span class="text-muted-foreground text-xs">{t('access.sharedWithMe.from', { name: p.ownerName })}</span>{/if}
					<Badge variant="accent" title={t(`access.roleHelp.${roleOf(p)}` as MessageKey)}>{t(`sharing.role.${roleOf(p)}` as MessageKey)}</Badge>
				</li>
			{/each}
		</ul>
	</div>

	<div class="bg-card flex flex-col gap-2 rounded-xl border p-4 shadow-card sm:p-5" data-testid="access-shared-by-me">
		<h3 class="text-base font-semibold">{t('access.sharedByMe')}</h3>
		{#if !grantsLoaded}<p class="text-muted-foreground text-sm">{t('access.sharedByMe.loading')}</p>
		{:else if outgoing.length === 0}<p class="text-muted-foreground text-sm">{t('access.sharedByMe.empty')}</p>{/if}
		<ul class="flex flex-col gap-1.5">
			{#each outgoing as o (o.project.id)}
				<li class="flex flex-wrap items-center gap-2 text-sm" data-testid="access-outgoing">
					<button type="button" class="text-ui-accent-ink min-w-0 flex-1 basis-40 truncate text-left underline underline-offset-2" onclick={() => onnav('project', o.project.id)}>{o.project.name}</button>
					<span class="text-muted-foreground basis-full text-xs sm:basis-auto">{t('access.sharedByMe.who', { names: names(o.grants).join(', ') })}</span>
				</li>
			{/each}
		</ul>
	</div>

	<div class="bg-card flex flex-col gap-2 rounded-xl border p-4 shadow-card sm:p-5" data-testid="access-apps">
		<h3 class="text-base font-semibold">{t('access.apps')}</h3>
		<p class="text-muted-foreground text-xs">{t('access.apps.hint')}</p>
		<div class="flex flex-wrap items-center gap-2 text-sm">
			<span class="flex-1">{t('access.apps.oauth')}: <strong>{activeOAuth.length === 0 ? t('access.apps.none') : t('access.apps.oauthCount', { count: activeOAuth.length })}</strong></span>
			<Button size="sm" variant="outline" onclick={() => onnav('general')}>{t('access.apps.manageOauth')}</Button>
		</div>
		<div class="flex flex-wrap items-center gap-2 text-sm">
			<span class="flex-1">{t('access.apps.runners')}: <strong>{activeDevices.length === 0 ? t('access.apps.none') : t('access.apps.runnersCount', { count: activeDevices.length })}</strong></span>
			<Button size="sm" variant="outline" onclick={() => onnav('agents')}>{t('access.apps.manageRunners')}</Button>
		</div>
	</div>

	<div class="bg-card flex flex-col gap-2 rounded-xl border p-4 shadow-card sm:p-5" data-testid="access-security">
		<h3 class="text-base font-semibold">{t('access.security')}</h3>
		<div class="flex flex-wrap items-center gap-2 text-sm">
			<span class="flex-1">{t('access.security.passkeys')}: <strong>{activePasskeys.length}</strong> · {t('access.security.sessions')}: <strong>{sessions.length}</strong></span>
			<Button size="sm" variant="outline" onclick={() => onnav('general')}>{t('access.security.manage')}</Button>
		</div>
	</div>
</section>
