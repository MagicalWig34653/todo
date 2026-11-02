<script lang="ts">
	import { onMount } from 'svelte';
	import { auth } from '#lib/auth.svelte.js';
	import { adminSettings, refreshAfterRoleChange, sortUsers, type AdminUser } from '#lib/adminSettings.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Avatar from '../app/Avatar.svelte';
	import Panel from '../app/Panel.svelte';
	import RecoveryIssue from '../RecoveryIssue.svelte';
	import GapNotice from './GapNotice.svelte';

	let users = $state<AdminUser[]>([]);
	let loaded = $state(false);
	let busyID = $state<string | null>(null);

	async function load() {
		await attempt(async () => {
			users = sortUsers(await adminSettings.users());
		});
		loaded = true;
	}
	onMount(load);

	async function toggle(u: AdminUser) {
		busyID = u.id;
		await attempt(async () => {
			const updated = await adminSettings.setAdmin(u.id, !u.isAdmin);
			users = sortUsers(users.map((x) => (x.id === updated.id ? updated : x)));
			// Own role changed: navigation and admin pages read auth.user, so refresh it from the server.
			await refreshAfterRoleChange(updated.id, auth.user?.id, () => auth.restore());
		});
		busyID = null;
	}
</script>

<div class="flex flex-col gap-4" data-testid="admin-area">
	<Panel title={t('settings.admin.accounts.title')} description={t('settings.admin.accounts.hint')}>
		{#if loaded && users.length === 0}
			<p class="text-muted-foreground text-sm">{t('settings.admin.accounts.empty')}</p>
		{/if}
		<ul class="flex flex-col divide-y" data-testid="admin-accounts">
			{#each users as u (u.id)}
				<li class="flex flex-wrap items-center gap-3 py-2.5" data-testid="admin-account-{u.id}">
					<Avatar name={u.displayName} />
					<div class="min-w-0 flex-1">
						<div class="flex flex-wrap items-center gap-2 text-sm font-medium">
							<span class="truncate">{u.displayName}</span>
							{#if u.id === auth.user?.id}<span class="text-muted-foreground text-xs font-normal">({t('settings.admin.accounts.you')})</span>{/if}
							{#if u.isAdmin}<span class="bg-muted rounded-full px-2 py-0.5 text-xs">{t('settings.admin.accounts.admin')}</span>{/if}
						</div>
						{#if u.username}<div class="text-muted-foreground truncate text-xs">{u.username}</div>{/if}
						<code class="text-muted-foreground text-[11px] break-all">{u.id}</code>
					</div>
					<Button size="sm" variant="ghost" disabled={busyID === u.id} onclick={() => toggle(u)} data-testid="admin-toggle-{u.id}">
						{u.isAdmin ? t('settings.admin.accounts.revoke') : t('settings.admin.accounts.grant')}
					</Button>
				</li>
			{/each}
		</ul>
	</Panel>
	<RecoveryIssue />
	<GapNotice testid="admin-gaps">{t('settings.admin.accounts.gap')}</GapNotice>
</div>
