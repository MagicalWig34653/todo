<script lang="ts">
	import { Select } from '#lib/components/ui/select/index.js';
	import { api, ApiError, type EffectiveVisibility, type PrincipalType, type Project, type ProjectGrant, type Role, type Team, type TeamMembership } from '#lib/api.js';
	import { accessRows, inheritedChain, ROLES, whoCanSee, type AccessRow, type AncestorGrants } from '#lib/access.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import Avatar from './app/Avatar.svelte';
	import PersonPicker from './PersonPicker.svelte';
	import RoleChip from './RoleChip.svelte';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import CornerLeftUp from '@lucide/svelte/icons/corner-left-up';

	/** Share dialog content: who has access with which role, add/change/remove, inheritance, effective visibility, ownership. */
	let { project, onchanged, onopen, onclose }: { project: Project; onchanged: () => unknown; onopen?: (id: string) => void; onclose?: () => void } = $props();

	const roleName = (r: Role) => t(`sharing.role.${r}` as MessageKey);
	const roleHelp = (r: Role) => t(`access.roleHelp.${r}` as MessageKey);
	const denied = (e: unknown) => e instanceof ApiError && (e.status === 403 || e.status === 404);

	let vis = $state<EffectiveVisibility | null>(null);
	let direct = $state<ProjectGrant[]>([]);
	let chain = $state<AncestorGrants[]>([]);
	let teams = $state<Team[]>([]);
	let teamMembers = $state<Record<string, TeamMembership[]>>({});
	let canManage = $state(false);
	let loaded = $state(false);

	let type = $state<PrincipalType>('person');
	let personID = $state('');
	let pickerKey = $state(0);
	let teamID = $state('');
	let role = $state<Role>('edit');
	let removingKey = $state<string | null>(null);
	let info = $state<string | null>(null);

	let transferOpen = $state(false);
	let transferType = $state<PrincipalType>('person');
	let transferPerson = $state('');
	let transferTeam = $state('');
	let transferKey = $state(0);

	/**
	 * Loads everything into locals and publishes it in one step, and only if no newer load was started meanwhile.
	 * Several loads overlap (explicit reload after a change plus the effect that follows `accessTick`); without this a
	 * slow, older response could overwrite the newer state (for example showing a just removed grant again).
	 */
	let loadSeq = 0;
	async function load() {
		const seq = ++loadSeq;
		const nextVis = await api.visibility(project.id);
		const nextTeams = await api.listTeams();
		let nextDirect: ProjectGrant[] = [];
		let nextManage = false;
		try {
			nextDirect = await api.listGrants(project.id);
			nextManage = true;
		} catch (e) {
			if (!denied(e)) throw e;
		}
		const nextChain = nextManage
			? await inheritedChain(project, nextVis.inherits, workspace.projects, async (anc) => {
					try {
						const [v, g] = await Promise.all([api.visibility(anc.id), api.listGrants(anc.id).catch((e) => (denied(e) ? null : Promise.reject(e)))]);
						return { inherits: v.inherits, grants: g };
					} catch (e) {
						if (!denied(e)) throw e;
						return { inherits: false, grants: null };
					}
				})
			: [];
		const nextMembers = await loadMembers(nextDirect, nextChain);
		if (seq !== loadSeq) return;
		vis = nextVis;
		teams = nextTeams;
		direct = nextDirect;
		canManage = nextManage;
		chain = nextChain;
		teamMembers = nextMembers;
		loaded = true;
	}
	/** Members of every team that matters here (owner, grants); teams the viewer is not in stay unknown. */
	async function loadMembers(grants: ProjectGrant[], levels: AncestorGrants[]): Promise<Record<string, TeamMembership[]>> {
		const ids = new Set<string>();
		if (project.ownerType === 'team' && project.ownerID) ids.add(project.ownerID);
		for (const g of grants) if (g.principalType === 'team') ids.add(g.principalID);
		for (const level of levels) for (const g of level.grants ?? []) if (g.principalType === 'team') ids.add(g.principalID);
		const next: Record<string, TeamMembership[]> = {};
		await Promise.all([...ids].map(async (id) => {
			try {
				next[id] = await api.teamMembers(id);
			} catch (e) {
				if (!denied(e)) throw e;
			}
		}));
		return next;
	}
	/** Primitive on purpose: a live refresh replaces the object, the effects below must only rerun for another id. */
	const projectKey = $derived(project.id);
	$effect(() => {
		void projectKey;
		void ui.accessTick;
		attempt(load);
	});

	const unknownName = (g: ProjectGrant) => `${t(g.principalType === 'team' ? 'share.teamBadge' : 'sharing.person')} ${g.principalID.slice(0, 8)}`;
	const rows = $derived<AccessRow[]>(accessRows(direct, chain, unknownName));
	const owner = $derived(project.ownerID && project.ownerType ? { type: project.ownerType, id: project.ownerID, name: project.ownerName?.trim() || project.ownerID.slice(0, 8) } : undefined);
	const unreadableLevels = $derived(chain.filter((c) => c.grants === null));
	const who = $derived(
		whoCanSee({
			owner,
			rows,
			teamMembers,
			labels: { owner: t('share.viaOwner'), direct: t('share.viaDirect'), team: (name) => t('share.viaTeam', { name }), inherited: (name) => t('share.viaInherited', { name }) }
		})
	);
	const myID = $derived(auth.user?.id);

	const changed = async () => {
		ui.accessTick++;
		await onchanged();
	};
	async function add(e: Event) {
		e.preventDefault();
		info = null;
		const id = type === 'person' ? personID.trim() : teamID;
		if (!id) return;
		await attempt(async () => {
			await api.putGrant(project.id, type, id, role);
			// Reset the form right away: the reloads below must not wipe what is typed next.
			personID = '';
			teamID = '';
			pickerKey++;
			info = t('share.addDone');
			await load();
			await changed();
		}, load);
	}
	const changeRole = (r: AccessRow, next: Role) =>
		attempt(async () => { await api.putGrant(project.id, r.principal.type, r.principal.id, next); await load(); await changed(); }, load);
	async function remove(r: AccessRow) {
		if (!r.grantID) return;
		if (await attempt(async () => { await api.deleteGrant(project.id, r.grantID!); await load(); await changed(); }, load)) removingKey = null;
	}
	const toggleInherit = () =>
		attempt(async () => {
			if (!vis) return;
			vis = await api.setInheritance(project, !vis.inherits);
			await onchanged();
			await load();
			ui.accessTick++;
		}, async () => { await onchanged(); await load(); });
	async function transfer(e: Event) {
		e.preventDefault();
		const id = transferType === 'person' ? transferPerson.trim() : transferTeam;
		if (!id) return;
		if (await attempt(async () => { await api.transferOwner(project, transferType, id); await changed(); }, async () => { await onchanged(); await load(); })) {
			transferOpen = false;
			onclose?.();
		}
	}
	function openParent(id: string) {
		onopen?.(id);
		onclose?.();
	}
</script>

<section class="flex flex-col gap-5" data-testid="sharing-panel">
	{#if vis}
		<div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm" data-testid="visibility">
			<RoleChip {project} />
			<span class="text-muted-foreground text-xs">
				<span class="sr-only">{t('sharing.yourRole')}:</span>
				<strong class="text-foreground font-medium" data-testid="my-role">{vis.role ? roleName(vis.role) : t('sharing.noRole')}</strong>
				– {vis.role ? roleHelp(vis.role) : ''}
			</span>
		</div>
	{/if}

	<div class="flex flex-col gap-2">
		<h3 class="text-sm font-semibold">{t('share.people')}</h3>
		<ul class="flex flex-col gap-1.5">
			{#if owner}
				<li class="flex flex-wrap items-center gap-2 rounded-lg border p-2.5 text-sm" data-testid="owner-row">
					<Avatar name={owner.name} team={owner.type === 'team'} />
					<span class="min-w-0 flex-1 truncate font-medium">{owner.name}{#if owner.type === 'person' && owner.id === myID}&nbsp;<span class="text-muted-foreground font-normal">({t('share.you')})</span>{/if}</span>
					<span class="bg-ui-accent-soft text-ui-accent-ink rounded-full px-2 py-0.5 text-xs font-medium">{t('share.owner')}</span>
					{#if owner.type === 'team'}<span class="bg-muted rounded-full px-2 py-0.5 text-xs">{t('share.teamBadge')}</span>{/if}
				</li>
			{/if}
			{#each rows as r (r.key)}
				<li class="flex flex-wrap items-center gap-2 rounded-lg border p-2.5 text-sm" data-testid={r.inheritedFrom ? 'grant-inherited' : 'grant'}>
					<Avatar name={r.principal.name} team={r.principal.type === 'team'} />
					<span class="min-w-0 flex-1 basis-32">
						<span class="block truncate font-medium" data-testid="grant-name">{r.principal.name}{#if r.principal.type === 'person' && r.principal.id === myID}&nbsp;<span class="text-muted-foreground font-normal">({t('share.you')})</span>{/if}</span>
						{#if r.inheritedFrom}
							<span class="text-muted-foreground flex flex-wrap items-center gap-1 text-xs" title={t('share.inheritedHint')}>
								{t('share.inheritedFrom')}
								<button type="button" class="text-ui-accent-ink inline-flex items-center gap-0.5 underline underline-offset-2" data-testid="grant-parent-link" aria-label={t('share.openParent', { name: r.inheritedFrom.name })} onclick={() => openParent(r.inheritedFrom!.id)}>
									<CornerLeftUp class="size-3" aria-hidden="true" />{r.inheritedFrom.name}
								</button>
							</span>
						{/if}
					</span>
					{#if r.principal.type === 'team'}<span class="bg-muted rounded-full px-2 py-0.5 text-xs">{t('share.teamBadge')}</span>{/if}
					{#if r.inheritedFrom}
						<span class="text-sm" title={t('share.inheritedHint')} data-testid="grant-role-static">{roleName(r.role)}</span>
					{:else}
						<Select class="w-40" aria-label={t('share.roleOf', { name: r.principal.name })} value={r.role} onchange={(e) => changeRole(r, e.currentTarget.value as Role)} data-testid="grant-role">
							{#each ROLES as x (x)}<option value={x}>{roleName(x)}</option>{/each}
						</Select>
						<Button size="icon-sm" variant="ghost" aria-label={t('share.removeTitle', { name: r.principal.name })} title={t('share.remove')} data-testid="grant-remove" onclick={() => (removingKey = r.key)}>
							<Trash2 aria-hidden="true" />
						</Button>
					{/if}
					{#if removingKey === r.key}
						<div class="bg-muted/60 flex basis-full flex-wrap items-center gap-2 rounded-md p-2" data-testid="grant-remove-confirm">
							<span class="flex-1 basis-48">{t('share.removeConfirm', { name: r.principal.name, project: project.name })}</span>
							<Button size="sm" variant="destructive" onclick={() => remove(r)}>{t('share.removeConfirmYes')}</Button>
							<Button size="sm" variant="ghost" onclick={() => (removingKey = null)}>{t('common.cancel')}</Button>
						</div>
					{/if}
				</li>
			{/each}
		</ul>
		{#if loaded && canManage && rows.length === 0}<p class="text-muted-foreground text-xs">{t('share.listEmpty')}</p>{/if}
		{#if loaded && owner?.type === 'team'}<p class="text-muted-foreground text-xs">{t('share.ownerTeam', { name: owner.name })}</p>{/if}
		{#if unreadableLevels.length > 0}<p class="text-muted-foreground text-xs" data-testid="inherited-unknown">{t('share.inheritedUnknown')}</p>{/if}
		{#if loaded && !canManage}<p class="bg-muted/60 rounded-lg px-3 py-2 text-sm" data-testid="no-manage">{t('share.noManage')}</p>{/if}
	</div>

	{#if canManage}
		<form class="flex flex-col gap-2 rounded-xl border p-3" onsubmit={add} aria-label={t('share.addTitle')}>
			<h3 class="text-sm font-semibold">{t('share.addTitle')}</h3>
			<div class="flex flex-wrap items-start gap-2">
				<Select class="w-32" aria-label={t('sharing.principalType')} bind:value={type}>
					<option value="person">{t('sharing.person')}</option>
					<option value="team">{t('sharing.team')}</option>
				</Select>
				{#if type === 'person'}
					{#key pickerKey}<PersonPicker bind:value={personID} idLabel={t('sharing.personID')} />{/key}
				{:else}
					<Select class="min-w-40 flex-1" aria-label={t('sharing.team')} bind:value={teamID}>
						<option value="">{t('sharing.pickTeam')}</option>
						{#each teams as team (team.id)}<option value={team.id}>{team.name}</option>{/each}
					</Select>
				{/if}
				<Select class="w-40" aria-label={t('share.addRole')} bind:value={role}>
					{#each ROLES as r (r)}<option value={r}>{roleName(r)}</option>{/each}
				</Select>
				<Button type="submit" size="lg" disabled={type === 'person' ? !personID.trim() : !teamID}>{t('share.add')}</Button>
			</div>
			<p class="text-muted-foreground text-xs" data-testid="role-help-selected"><strong>{roleName(role)}:</strong> {roleHelp(role)}</p>
			{#if type === 'team' && teams.length === 0}<p class="text-muted-foreground text-xs">{t('share.noTeams')}</p>{/if}
			{#if info}<p class="text-success text-xs" role="status" data-testid="share-info">{info}</p>{/if}
		</form>

		<label class="flex items-start gap-2 text-sm">
			<Checkbox class="mt-0.5 size-4" checked={vis?.inherits ?? false} onchange={toggleInherit} data-testid="inherit-toggle" />
			<span>{t('share.inherits')}<span class="text-muted-foreground block text-xs">{t('share.inheritsHint')}</span></span>
		</label>
	{/if}

	<details class="rounded-xl border p-3 text-sm" data-testid="role-explanations">
		<summary class="cursor-pointer font-semibold">{t('share.roleHelpTitle')}</summary>
		<dl class="mt-2 flex flex-col gap-1.5">
			{#each ROLES as r (r)}
				<div><dt class="inline font-medium">{roleName(r)}:</dt> <dd class="text-muted-foreground inline">{roleHelp(r)}</dd></div>
			{/each}
		</dl>
	</details>

	{#if loaded}
		<div class="flex flex-col gap-2" data-testid="who-can-see">
			<h3 class="text-sm font-semibold">{t('share.visibilityTitle')}</h3>
			<p class="text-muted-foreground text-xs">{t('share.visibilityHint')}</p>
			{#if who.length === 0}
				<p class="text-muted-foreground text-xs">{t('share.onlyYou')}</p>
			{/if}
			<ul class="flex flex-col gap-1">
				{#each who as p (p.userID)}
					<li class="flex flex-wrap items-center gap-2 text-sm" data-testid="who-row">
						<Avatar name={p.name} size="sm" />
						<span class="min-w-0 flex-1 basis-32 truncate">{p.name}{#if p.userID === myID}&nbsp;({t('share.you')}){/if}</span>
						<span class="bg-muted rounded-full px-2 py-0.5 text-xs font-medium" data-testid="who-role">{roleName(p.role)}</span>
						<span class="text-muted-foreground basis-full pl-8 text-xs">{t('share.visibilityVia', { sources: p.via.join(', ') })}</span>
					</li>
				{/each}
			</ul>
			<p class="text-muted-foreground text-xs">{t('share.visibilityNote')}</p>
		</div>
	{/if}

	{#if vis}
		<div class="flex flex-col gap-2 text-sm" data-testid="ownership">
			<h3 class="text-sm font-semibold">{t('share.ownerSection')}</h3>
			<ul class="text-muted-foreground flex flex-wrap gap-x-4 gap-y-1 text-xs">
				<li>{t('sharing.cap.canDelete')}: {vis.canDelete ? t('sharing.yes') : t('sharing.no')}</li>
				<li>{t('sharing.cap.canTransferOwnership')}: {vis.canTransferOwnership ? t('sharing.yes') : t('sharing.no')}</li>
				<li>{t('sharing.cap.canManageTeam')}: {vis.canManageTeam ? t('sharing.yes') : t('sharing.no')}</li>
			</ul>
			{#if vis.canTransferOwnership}
				{#if !transferOpen}
					<div><Button size="sm" variant="outline" data-testid="transfer-open" onclick={() => (transferOpen = true)}>{t('share.transfer')}</Button></div>
				{:else}
					<form class="flex flex-col gap-2 rounded-xl border p-3" onsubmit={transfer} data-testid="transfer-form">
						<p class="text-muted-foreground text-xs">{t('share.transferHint')}</p>
						<div class="flex flex-wrap items-start gap-2">
							<Select class="w-32" aria-label={t('share.transferTo')} bind:value={transferType}>
								<option value="person">{t('sharing.person')}</option>
								<option value="team">{t('sharing.team')}</option>
							</Select>
							{#if transferType === 'person'}
								{#key transferKey}<PersonPicker bind:value={transferPerson} idLabel={t('sharing.personID')} />{/key}
							{:else}
								<Select class="min-w-40 flex-1" aria-label={t('share.transferTeamOwner')} bind:value={transferTeam}>
									<option value="">{t('sharing.pickTeam')}</option>
									{#each teams as team (team.id)}<option value={team.id}>{team.name}</option>{/each}
								</Select>
							{/if}
						</div>
						<div class="flex gap-2">
							<Button type="submit" size="sm" variant="destructive" disabled={transferType === 'person' ? !transferPerson.trim() : !transferTeam}>{t('share.transferConfirm')}</Button>
							<Button type="button" size="sm" variant="ghost" onclick={() => { transferOpen = false; transferKey++; }}>{t('common.cancel')}</Button>
						</div>
					</form>
				{/if}
			{:else}
				<p class="text-muted-foreground text-xs">{t('share.transferNotAllowed')}</p>
			{/if}
		</div>
	{/if}
</section>
