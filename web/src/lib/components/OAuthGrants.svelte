<script lang="ts">
	import { api, type OAuthGrant, type Project } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { resolveGrantProjects, scopeLabel, sortGrants } from '#lib/oauth.js';
	import { Button } from '#lib/components/ui/button/index.js';

	let grants = $state<OAuthGrant[]>([]);
	let projects = $state<Project[]>([]);
	let confirmID = $state<string | null>(null);
	let info = $state<string | null>(null);

	async function load() {
		const [g, p] = await Promise.all([api.listOAuthGrants(), api.listProjects()]);
		grants = sortGrants(g);
		projects = p;
	}
	$effect(() => {
		attempt(load);
	});

	async function revoke(g: OAuthGrant) {
		info = null;
		if (await attempt(async () => { await api.revokeOAuthGrant(g.id); await load(); }, load)) {
			confirmID = null;
			info = t('account.oauth.revokedDone');
		}
	}
</script>

<div class="flex flex-col gap-2" data-testid="oauth-grants">
	<h3 class="text-sm font-medium">{t('account.oauth')}</h3>
	<p class="text-muted-foreground text-xs">{t('account.oauth.hint')}</p>
	{#if info}<p class="text-sm" role="status" data-testid="oauth-info">{info}</p>{/if}
	{#if grants.length === 0}
		<p class="text-muted-foreground text-sm">{t('account.oauth.empty')}</p>
	{/if}
	<ul class="flex flex-col gap-1">
		{#each grants as g (g.id)}
			{@const resolved = resolveGrantProjects(g, projects)}
			<li class="rounded-md border p-2 text-sm" data-testid="oauth-grant">
				<div class="flex flex-wrap items-center gap-2">
					<span class={['flex-1 break-all', g.revoked && 'text-muted-foreground line-through']}>{t('account.oauth.client', { id: g.client_id })}</span>
					{#if g.revoked}
						<span class="text-muted-foreground text-xs">{t('account.oauth.revoked')}</span>
					{:else}
						<Button size="xs" variant="destructive" onclick={() => (confirmID = g.id)}>{t('account.oauth.revoke')}</Button>
					{/if}
				</div>
				<p class="text-muted-foreground text-xs">{t('account.oauth.scopes', { scopes: g.scopes.map(scopeLabel).join(', ') })}</p>
				<p class="text-muted-foreground text-xs">
					{t('account.oauth.projects', { names: resolved.names.join(', ') || '–' })}{#if resolved.unknown > 0} ({t('account.oauth.unknownProjects', { count: resolved.unknown })}){/if}
				</p>
				{#if confirmID === g.id}
					<div class="mt-2 flex flex-wrap items-center gap-2">
						<span>{t('account.oauth.revokeConfirm')}</span>
						<Button size="sm" variant="destructive" onclick={() => revoke(g)}>{t('account.oauth.revoke')}</Button>
						<Button size="sm" variant="ghost" onclick={() => (confirmID = null)}>{t('common.cancel')}</Button>
					</div>
				{/if}
			</li>
		{/each}
	</ul>
</div>
