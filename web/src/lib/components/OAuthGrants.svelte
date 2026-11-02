<script lang="ts">
	import { api, type OAuthGrant, type Project } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { mayBeEmpty, nextGrantProjects, resolveGrantProjects, scopeLabel, sortGrants } from '#lib/oauth.js';
	import { createKeyedGate, createLatest } from '#lib/serial.js';
	import { Button } from '#lib/components/ui/button/index.js';

	let grants = $state<OAuthGrant[]>([]);
	let projects = $state<Project[]>([]);
	let confirmID = $state<string | null>(null);
	let info = $state<string | null>(null);
	let editID = $state<string | null>(null);
	let selected = $state<Set<string>>(new Set());
	// One write per grant at a time: a second PUT could overtake the first and bring back a withdrawn project.
	let busyIDs = $state<string[]>([]);
	const gate = createKeyedGate((b) => (busyIDs = b));
	const latest = createLatest();

	function edit(g: OAuthGrant) {
		editID = g.id;
		selected = new Set(g.project_ids);
		confirmID = null;
	}
	function toggle(id: string) {
		const next = new Set(selected);
		if (next.has(id)) next.delete(id);
		else next.add(id);
		selected = next;
	}
	async function save(g: OAuthGrant) {
		info = null;
		const ids = nextGrantProjects(selected, projects);
		const done = await gate.run(g.id, () => attempt(async () => { await api.setOAuthGrantProjects(g.id, ids); await load(); }, load));
		if (done?.value) {
			editID = null;
			info = t('account.oauth.editProjects.done');
		}
	}

	async function load() {
		const current = latest.begin();
		const [g, p] = await Promise.all([api.listOAuthGrants(), api.listProjects()]);
		if (!current()) return;
		grants = sortGrants(g);
		projects = p;
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
			<li class="rounded-lg border p-2.5 text-sm" data-testid="oauth-grant">
				<div class="flex flex-wrap items-center gap-2">
					<span class={['flex-1 break-all', g.revoked && 'text-muted-foreground line-through']}>{g.client_name ? t('account.oauth.clientNamed', { name: g.client_name, id: g.client_id }) : t('account.oauth.client', { id: g.client_id })}</span>
					{#if g.revoked}
						<span class="text-muted-foreground text-xs">{t('account.oauth.revoked')}</span>
					{:else}
						<Button size="xs" variant="outline" disabled={busyIDs.includes(g.id)} onclick={() => edit(g)} data-testid="oauth-edit">{t('account.oauth.editProjects')}</Button>
						<Button size="xs" variant="destructive" disabled={busyIDs.includes(g.id)} onclick={() => (confirmID = g.id)}>{t('account.oauth.revoke')}</Button>
					{/if}
				</div>
				<p class="text-muted-foreground text-xs">{t('account.oauth.scopes', { scopes: g.scopes.map(scopeLabel).join(', ') })}</p>
				<p class="text-muted-foreground text-xs">
					{t('account.oauth.projects', { names: resolved.names.join(', ') || '–' })}{#if resolved.unknown > 0} ({t('account.oauth.unknownProjects', { count: resolved.unknown })}){/if}
				</p>
				{#if editID === g.id}
					{@const empty = nextGrantProjects(selected, projects).length === 0}
					<div class="mt-2 flex flex-col gap-2" data-testid="oauth-edit-panel">
						<p class="text-muted-foreground text-xs">{t('account.oauth.editProjects.hint')}</p>
						<ul class="flex max-h-60 flex-col gap-1 overflow-auto">
							{#each projects as p (p.id)}
								<li><label class="flex items-center gap-2"><input type="checkbox" class="size-[18px]" checked={selected.has(p.id)} disabled={busyIDs.includes(g.id)} onchange={() => toggle(p.id)} data-testid="oauth-edit-project-{p.id}" /> <span>{p.name}</span></label></li>
							{/each}
						</ul>
						{#if empty && !mayBeEmpty(g)}<p class="text-xs" role="status">{t('account.oauth.editProjects.needOne')}</p>{/if}
						<div class="flex gap-2">
							<Button size="sm" disabled={(empty && !mayBeEmpty(g)) || busyIDs.includes(g.id)} onclick={() => save(g)} data-testid="oauth-edit-save">{t('account.oauth.editProjects.save')}</Button>
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
