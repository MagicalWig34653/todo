<script lang="ts">
	import { api, ApiError, type EffectiveVisibility, type PrincipalType, type Project, type ProjectGrant, type Role, type Team } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import PersonPicker from './PersonPicker.svelte';

	let { project, onchanged }: { project: Project; onchanged: () => unknown } = $props();

	const ROLES: Role[] = ['read', 'comment', 'edit', 'manage'];

	let vis = $state<EffectiveVisibility | null>(null);
	let grants = $state<ProjectGrant[]>([]);
	let teams = $state<Team[]>([]);
	let canManage = $state(true);
	let type = $state<PrincipalType>('person');
	let personID = $state('');
	let pickerKey = $state(0);
	let teamID = $state('');
	let role = $state<Role>('read');
	let checkID = $state('');
	let checked = $state<EffectiveVisibility | null>(null);

	async function load() {
		vis = await api.visibility(project.id);
		canManage = true;
		try {
			grants = await api.listGrants(project.id);
			teams = await api.listTeams();
		} catch (e) {
			// Without the manage role the grant list is not readable; the visibility above stays shown.
			if (e instanceof ApiError && (e.status === 403 || e.status === 404)) {
				canManage = false;
				grants = [];
			} else throw e;
		}
	}
	$effect(() => {
		void project.id;
		checked = null;
		attempt(load);
	});

	const teamName = (id: string) => teams.find((x) => x.id === id)?.name ?? id;
	const principalLabel = (g: ProjectGrant) => (g.principalType === 'team' ? teamName(g.principalID) : g.principalID);

	async function add(e: Event) {
		e.preventDefault();
		const id = type === 'person' ? personID.trim() : teamID;
		if (!id) return;
		if (await attempt(async () => { await api.putGrant(project.id, type, id, role); await load(); }, load)) {
			personID = '';
			pickerKey++;
		}
	}
	const revoke = (g: ProjectGrant) => attempt(async () => { await api.deleteGrant(project.id, g.id); await load(); }, load);
	const toggleInherit = () =>
		attempt(async () => {
			if (!vis) return;
			vis = await api.setInheritance(project, !vis.inherits);
			await onchanged();
		}, async () => { await onchanged(); await load(); });
	async function check(e: Event) {
		e.preventDefault();
		const id = checkID.trim();
		if (id) await attempt(async () => (checked = await api.visibility(project.id, id)));
	}
	const roleText = (r?: Role) => (r ? t(`sharing.role.${r}` as MessageKey) : t('sharing.noRole'));
	const yn = (b: boolean) => (b ? t('sharing.yes') : t('sharing.no'));
</script>

<section class="flex flex-col gap-4" data-testid="sharing-panel">
	{#if vis}
		<div class="flex flex-col gap-1 rounded-md border p-3 text-sm" data-testid="visibility">
			<h3 class="font-medium">{t('sharing.visibility')}</h3>
			<p>{t('sharing.yourRole')}: <strong data-testid="my-role">{roleText(vis.role)}</strong></p>
			<p>{vis.inherits ? t('sharing.inheritsOn') : t('sharing.inheritsOff')}</p>
			<ul class="text-muted-foreground text-xs">
				<li>{t('sharing.cap.canDelete')}: {yn(vis.canDelete)}</li>
				<li>{t('sharing.cap.canManageTeam')}: {yn(vis.canManageTeam)}</li>
				<li>{t('sharing.cap.canTransferOwnership')}: {yn(vis.canTransferOwnership)}</li>
				<li>{t('sharing.cap.canStartAgent')}: {yn(vis.canStartAgent)}</li>
			</ul>
		</div>
	{/if}

	{#if !canManage}
		<p class="text-muted-foreground text-sm">{t('sharing.forbidden')}</p>
	{:else}
		<div class="flex items-center gap-2 text-sm">
			<label class="flex items-center gap-2">
				<input type="checkbox" class="size-4" checked={vis?.inherits ?? false} onchange={toggleInherit} />
				{t('sharing.inherits')}
			</label>
		</div>

		<div class="flex flex-col gap-1">
			<h3 class="text-sm font-medium">{t('sharing.grants')}</h3>
			{#if grants.length === 0}<p class="text-muted-foreground text-xs">{t('sharing.grants.empty')}</p>{/if}
			<ul class="flex flex-col gap-1">
				{#each grants as g (g.id)}
					<li class="flex flex-wrap items-center gap-2 rounded-md border p-2 text-sm" data-testid="grant">
						<span class="bg-muted rounded px-1.5 py-0.5 text-xs">{t(g.principalType === 'team' ? 'sharing.team' : 'sharing.person')}</span>
						<span class="flex-1 font-mono text-xs break-all">{principalLabel(g)}</span>
						<span class="text-xs">{roleText(g.role)}</span>
						<Button size="xs" variant="destructive" onclick={() => revoke(g)}>{t('sharing.revoke')}</Button>
					</li>
				{/each}
			</ul>
		</div>

		<form class="flex flex-wrap items-end gap-2" onsubmit={add}>
			<select class="border-input bg-background h-9 rounded-md border px-2 text-sm" aria-label={t('sharing.principalType')} bind:value={type}>
				<option value="person">{t('sharing.person')}</option>
				<option value="team">{t('sharing.team')}</option>
			</select>
			{#if type === 'person'}
				{#key pickerKey}<PersonPicker bind:value={personID} idLabel={t('sharing.personID')} />{/key}
			{:else}
				<select class="border-input bg-background h-9 rounded-md border px-2 text-sm" aria-label={t('sharing.team')} bind:value={teamID}>
					<option value="">{t('sharing.pickTeam')}</option>
					{#each teams as team (team.id)}<option value={team.id}>{team.name}</option>{/each}
				</select>
			{/if}
			<select class="border-input bg-background h-9 rounded-md border px-2 text-sm" aria-label={t('sharing.yourRole')} bind:value={role}>
				{#each ROLES as r (r)}<option value={r}>{roleText(r)}</option>{/each}
			</select>
			<Button type="submit" size="lg">{t('sharing.add')}</Button>
		</form>

		<form class="flex flex-col gap-1" onsubmit={check}>
			<h3 class="text-sm font-medium">{t('sharing.checkUser')}</h3>
			<div class="flex gap-2">
				<Input bind:value={checkID} placeholder={t('sharing.checkUserID')} aria-label={t('sharing.checkUserID')} />
				<Button type="submit" variant="outline" size="lg">{t('sharing.check')}</Button>
			</div>
			{#if checked}
				<p class="text-sm" data-testid="check-result">{t('sharing.checkResult', { id: checked.userID })}: {roleText(checked.role)}</p>
			{/if}
		</form>
	{/if}
</section>
