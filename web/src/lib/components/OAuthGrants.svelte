<script lang="ts">
	import { api, type OAuthGrant, type Project } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { connectionName, mayBeEmpty, nextGrantProjects, resolveGrantProjects, revocationKey, scopeLabel, sortGrants } from '#lib/oauth.js';
	import { projectLabels } from '#lib/brainMandate.js';
	import { describeRule, emptySelection, namesSomething, selectionFrom, type ProjectGroup, type Selection } from '#lib/projectGroups.js';
	import ProjectSelectionPicker from './ProjectSelectionPicker.svelte';
	import { createKeyedGate, createLatest } from '#lib/serial.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { formatWhen } from '#lib/planning.js';

	let grants = $state<OAuthGrant[]>([]);
	let projects = $state<Project[]>([]);
	let confirmID = $state<string | null>(null);
	let info = $state<string | null>(null);
	let editID = $state<string | null>(null);
	let renameID = $state<string | null>(null);
	let nameDraft = $state('');
	let selection = $state<Selection>(emptySelection());
	let effective = $state<string[] | null>(null);
	let groups = $state<ProjectGroup[]>([]);
	const labels = $derived(projectLabels(projects));
	const groupName = (id: string) => groups.find((g) => g.id.toLowerCase() === id.toLowerCase())?.name ?? t('projectGroups.unknownGroup');
	const projectName = (id: string) => labels.get(id.toLowerCase()) ?? id.slice(0, 8).toLowerCase();
	// One write per grant at a time: a second PUT could overtake the first and bring back a withdrawn project.
	let busyIDs = $state<string[]>([]);
	const gate = createKeyedGate((b) => (busyIDs = b));
	const latest = createLatest();

	function edit(g: OAuthGrant) {
		editID = g.id;
		// Ids the person cannot see any more are dropped on save (least privilege).
		const stored = selectionFrom(g.selection?.projectIDs ?? g.project_ids, g.selection);
		selection = { ...stored, projectIDs: nextGrantProjects(new Set(stored.projectIDs), projects) };
		effective = null;
		confirmID = null;
	}
	async function save(g: OAuthGrant) {
		info = null;
		const next = $state.snapshot(selection);
		const done = await gate.run(g.id, () => attempt(async () => { await api.setOAuthGrantSelection(g.id, next); await load(); }, load));
		if (done?.value) {
			editID = null;
			info = t('account.oauth.editProjects.done');
		}
	}

	function startRename(g: OAuthGrant) {
		renameID = g.id;
		nameDraft = connectionName(g);
		info = null;
	}
	async function saveName(g: OAuthGrant) {
		const name = nameDraft.trim().replace(/\s+/g, ' ');
		if (!name || name.length > 80) {
			info = t('account.oauth.nameInvalid');
			return;
		}
		const done = await gate.run(g.id, () => attempt(async () => { await api.renameOAuthGrant(g.id, name); await load(); }, load));
		if (done?.value) {
			renameID = null;
			info = t('account.oauth.renamed');
		}
	}

	async function load() {
		const current = latest.begin();
		const [g, p, pg] = await Promise.all([api.listOAuthGrants(), api.listProjects(), api.listProjectGroups()]);
		if (!current()) return;
		grants = sortGrants(g);
		projects = p;
		groups = pg;
	}
	$effect(() => {
		attempt(load);
	});

	async function revoke(g: OAuthGrant) {
		info = null;
		const done = await gate.run(g.id, () => attempt(async () => { await api.revokeOAuthGrant(g.id); await load(); }, load));
		if (done?.value) {
			confirmID = null;
			info = t('account.oauth.revokedDone');
		}
	}
</script>

<div class="bg-card flex flex-col gap-3 rounded-xl border p-4 shadow-card sm:p-5" data-testid="oauth-grants">
	<h3 class="text-base font-semibold">{t('account.oauth')}</h3>
	<p class="text-muted-foreground text-xs">{t('account.oauth.hint')}</p>
	{#if info}<p class="text-sm" role="status" data-testid="oauth-info">{info}</p>{/if}
	{#if grants.length === 0}
		<p class="text-muted-foreground text-sm">{t('account.oauth.empty')}</p>
	{/if}
	<ul class="flex flex-col gap-1">
		{#each grants as g (g.id)}
			{@const resolved = resolveGrantProjects(g, projects)}
			{@const rule = describeRule(g.selection, groupName, projectName)}
			<li class="rounded-lg border p-2.5 text-sm" data-testid="oauth-grant">
				<div class="flex flex-wrap items-center gap-2">
					<span class={['flex-1 break-all', g.revoked && 'text-muted-foreground line-through']} data-testid="oauth-name"><strong>{connectionName(g)}</strong>{#if g.client_name && g.client_name !== connectionName(g)} <span class="text-muted-foreground text-xs">({g.client_name})</span>{/if}</span>
					{#if g.revoked}
						<span class="text-muted-foreground text-xs" data-testid="oauth-revoked">{t(revocationKey(g))}</span>
					{:else}
						<Button size="xs" variant="outline" disabled={busyIDs.includes(g.id)} onclick={() => startRename(g)} data-testid="oauth-rename">{t('account.oauth.rename')}</Button>
						<Button size="xs" variant="outline" disabled={busyIDs.includes(g.id)} onclick={() => edit(g)} data-testid="oauth-edit">{t('account.oauth.editProjects')}</Button>
						<Button size="xs" variant="destructive" disabled={busyIDs.includes(g.id)} onclick={() => (confirmID = g.id)}>{t('account.oauth.revoke')}</Button>
					{/if}
				</div>
				{#if g.revoked_reason === 'replay'}
					<div class="bg-warning-soft text-warning mt-1 flex flex-col items-start gap-2 rounded-lg px-3 py-2 text-sm" data-testid="oauth-replay">
						<p>{t('account.oauth.revoked.replay.text')}</p>
						<!-- Ends it for good: a revocation by the person is never taken over. -->
						<Button size="xs" variant="outline" disabled={busyIDs.includes(g.id)} onclick={() => revoke(g)} data-testid="oauth-replay-end">{t('account.oauth.revoked.replay.end')}</Button>
					</div>
				{/if}
				{#if renameID === g.id}
					<form class="mt-1 flex flex-wrap items-center gap-2" onsubmit={(e) => { e.preventDefault(); void saveName(g); }}>
						<Input class="min-w-40 flex-1" maxlength={80} aria-label={t('account.oauth.name')} bind:value={nameDraft} data-testid="oauth-name-input" />
						<Button size="sm" type="submit" disabled={busyIDs.includes(g.id)} data-testid="oauth-name-save">{t('account.oauth.renameSave')}</Button>
						<Button size="sm" variant="ghost" type="button" onclick={() => (renameID = null)}>{t('common.cancel')}</Button>
					</form>
				{/if}
				<p class="text-muted-foreground text-xs" data-testid="oauth-last-used">{g.last_used_at ? t('account.oauth.lastUsed', { when: formatWhen(g.last_used_at) }) : t('account.oauth.neverUsed')}</p>
				<p class="text-muted-foreground text-xs">{t('account.oauth.scopes', { scopes: g.scopes.map(scopeLabel).join(', ') })}</p>
				{#if rule}<p class="text-xs font-medium break-words" data-testid="oauth-rule">{t(rule.key, { groups: rule.groups, excluded: rule.excluded })}</p>{/if}
				<p class="text-muted-foreground text-xs break-words">
					{t('account.oauth.projects', { names: resolved.names.join(', ') || '–' })}{#if resolved.unknown > 0} ({t('account.oauth.unknownProjects', { count: resolved.unknown })}){/if}
				</p>
				{#if editID === g.id}
					{@const empty = !namesSomething(selection)}
					<div class="mt-2 flex flex-col gap-2" data-testid="oauth-edit-panel">
						<p class="text-muted-foreground text-xs">{t('account.oauth.editProjects.hint')}</p>
						<ProjectSelectionPicker bind:selection bind:effective {projects} {groups} testid="oauth-edit" perID before={g.project_ids} disabled={busyIDs.includes(g.id)} />
						{#if empty && !mayBeEmpty(g)}<p class="text-xs" role="status">{t('account.oauth.editProjects.needOne')}</p>{/if}
						<div class="flex gap-2">
							<Button size="sm" disabled={(empty && !mayBeEmpty(g)) || effective === null || busyIDs.includes(g.id)} onclick={() => save(g)} data-testid="oauth-edit-save">{t('account.oauth.editProjects.save')}</Button>
							<Button size="sm" variant="ghost" disabled={busyIDs.includes(g.id)} onclick={() => (editID = null)}>{t('common.cancel')}</Button>
						</div>
					</div>
				{/if}
				{#if confirmID === g.id}
					<div class="mt-2 flex flex-wrap items-center gap-2">
						<span>{t('account.oauth.revokeConfirm')}</span>
						<Button size="sm" variant="destructive" disabled={busyIDs.includes(g.id)} onclick={() => revoke(g)}>{t('account.oauth.revoke')}</Button>
						<Button size="sm" variant="ghost" onclick={() => (confirmID = null)}>{t('common.cancel')}</Button>
					</div>
				{/if}
			</li>
		{/each}
	</ul>
</div>
