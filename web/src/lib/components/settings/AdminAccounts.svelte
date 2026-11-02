<script lang="ts">
	import { onMount } from 'svelte';
	import { auth } from '#lib/auth.svelte.js';
	import { adminSettings, lockActions, refreshAfterRoleChange, sortUsers, statusOf, type AdminUser, type LockAction } from '#lib/adminSettings.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Avatar from '../app/Avatar.svelte';
	import Dialog from '../app/Dialog.svelte';
	import Panel from '../app/Panel.svelte';
	import RecoveryIssue from '../RecoveryIssue.svelte';

	let users = $state<AdminUser[]>([]);
	let loaded = $state(false);
	let busyID = $state<string | null>(null);
	// Lock action waiting for confirmation.
	let pending = $state<{ user: AdminUser; action: LockAction } | null>(null);
	let dialogOpen = $state(false);

	const active = $derived(users.filter((u) => statusOf(u) === 'active'));
	const locked = $derived(users.filter((u) => statusOf(u) !== 'active'));

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

	function ask(user: AdminUser, action: LockAction) {
		notice.clear();
		pending = { user, action };
		dialogOpen = true;
	}

	async function confirm() {
		if (!pending) return;
		const { user, action } = pending;
		busyID = user.id;
		const ok = await attempt(async () => {
			const updated = await adminSettings.lock(user.id, action);
			users = sortUsers(users.map((x) => (x.id === updated.id ? updated : x)));
		});
		busyID = null;
		if (ok) dialogOpen = false;
	}

	$effect(() => {
		if (!dialogOpen) pending = null;
	});
</script>

{#snippet row(u: AdminUser)}
	{@const status = statusOf(u)}
	<li class="flex flex-wrap items-center gap-3 py-2.5" data-testid="admin-account-{u.id}" data-status={status}>
		<Avatar name={u.displayName} />
		<div class="min-w-0 flex-1">
			<div class="flex flex-wrap items-center gap-2 text-sm font-medium">
				<span class="truncate">{u.displayName}</span>
				{#if u.id === auth.user?.id}<span class="text-muted-foreground text-xs font-normal">({t('settings.admin.accounts.you')})</span>{/if}
				{#if u.isAdmin}<span class="bg-muted rounded-full px-2 py-0.5 text-xs">{t('settings.admin.accounts.admin')}</span>{/if}
				<span
					class={['rounded-full px-2 py-0.5 text-xs', status === 'active' ? 'text-muted-foreground border' : 'bg-warning-soft text-foreground']}
					data-testid="admin-status-{u.id}"
				>
					{t(`settings.admin.accounts.status.${status}` as MessageKey)}
				</span>
			</div>
			{#if u.username}<div class="text-muted-foreground truncate text-xs">{u.username}</div>{/if}
			<code class="text-muted-foreground text-[11px] break-all">{u.id}</code>
		</div>
		<div class="flex flex-wrap items-center gap-1">
			{#if status === 'active'}
				<Button size="sm" variant="ghost" disabled={busyID === u.id} onclick={() => toggle(u)} data-testid="admin-toggle-{u.id}">
					{u.isAdmin ? t('settings.admin.accounts.revoke') : t('settings.admin.accounts.grant')}
				</Button>
			{/if}
			{#each lockActions(u, auth.user?.id) as action (action)}
				<Button
					size="sm"
					variant={action === 'enable' ? 'ghost' : 'destructive'}
					disabled={busyID === u.id}
					onclick={() => ask(u, action)}
					data-testid="admin-{action}-{u.id}"
				>
					{t(`settings.admin.accounts.${action}` as MessageKey)}
				</Button>
			{/each}
		</div>
	</li>
{/snippet}

<div class="flex flex-col gap-4" data-testid="admin-area">
	<Panel title={t('settings.admin.accounts.title')} description={t('settings.admin.accounts.hint')}>
		{#if loaded && users.length === 0}
			<p class="text-muted-foreground text-sm">{t('settings.admin.accounts.empty')}</p>
		{/if}
		<ul class="flex flex-col divide-y" data-testid="admin-accounts">
			{#each active as u (u.id)}{@render row(u)}{/each}
		</ul>
	</Panel>
	{#if locked.length > 0}
		<Panel title={t('settings.admin.accounts.locked.title')} description={t('settings.admin.accounts.locked.hint')} class="bg-muted/40">
			<ul class="flex flex-col divide-y" data-testid="admin-accounts-locked">
				{#each locked as u (u.id)}{@render row(u)}{/each}
			</ul>
		</Panel>
	{/if}
	<RecoveryIssue />
</div>

<Dialog bind:open={dialogOpen} title={pending ? t(`settings.admin.accounts.confirm.${pending.action}.title` as MessageKey) : ''} testid="admin-lock-dialog">
	{#if pending}
		<div class="flex flex-col gap-3 text-sm">
			<p class="font-medium">{t('settings.admin.accounts.confirm.account', { name: pending.user.displayName })}</p>
			<p>{t(`settings.admin.accounts.confirm.${pending.action}.what` as MessageKey)}</p>
			{#if pending.action !== 'enable'}
				<p class="text-muted-foreground">{t(`settings.admin.accounts.confirm.${pending.action}.kept` as MessageKey)}</p>
			{/if}
			<div class="flex flex-wrap justify-end gap-2">
				<Button variant="ghost" onclick={() => (dialogOpen = false)}>{t('settings.admin.accounts.cancel')}</Button>
				<Button
					variant={pending.action === 'enable' ? 'default' : 'destructive'}
					disabled={busyID === pending.user.id}
					onclick={confirm}
					data-testid="admin-lock-confirm"
				>
					{t(`settings.admin.accounts.confirm.submit.${pending.action}` as MessageKey)}
				</Button>
			</div>
		</div>
	{/if}
</Dialog>
