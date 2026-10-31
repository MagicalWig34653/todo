<script lang="ts">
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { theme, type ThemeMode } from '#lib/theme.svelte.js';
	import Popover from './app/Popover.svelte';
	import MenuItem from './app/MenuItem.svelte';
	import Avatar from './app/Avatar.svelte';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import CircleHelp from '@lucide/svelte/icons/circle-help';
	import LogOut from '@lucide/svelte/icons/log-out';
	import Settings from '@lucide/svelte/icons/settings';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import UserCog from '@lucide/svelte/icons/user-cog';

	/** User menu (top right): identity, settings, appearance, help, administration (admins only), sign out. */
	let { onsettings, onhelp }: { onsettings: (area?: string) => void; onhelp: () => void } = $props();
	let open = $state(false);
	const MODES: { mode: ThemeMode; label: 'user.theme.system' | 'user.theme.light' | 'user.theme.dark' }[] = [
		{ mode: 'light', label: 'user.theme.light' },
		{ mode: 'dark', label: 'user.theme.dark' },
		{ mode: 'system', label: 'user.theme.system' }
	];
</script>

<Popover label={t('nav.accountMenu')} align="end" bind:open testid="account-menu" class="hover:bg-muted flex min-w-0 items-center gap-2 rounded-lg p-1 text-left" panelClass="w-64">
	{#snippet trigger()}
		<Avatar name={auth.user?.displayName ?? '?'} />
		<span class="hidden max-w-32 truncate text-sm font-medium sm:inline" data-testid="signed-in-as">{auth.user?.displayName ?? ''}</span>
		<ChevronDown class="text-muted-foreground hidden size-3.5 shrink-0 sm:block" aria-hidden="true" />
	{/snippet}
	{#snippet children(close)}
		<div class="px-2.5 py-1.5">
			<p class="text-sm font-semibold">{auth.user?.displayName}</p>
			<p class="text-muted-foreground text-xs">{auth.user?.isAdmin ? t('settings.profile.admin') : t('settings.profile.member')}</p>
		</div>
		<MenuItem testid="menu-settings" onclick={() => { onsettings(); close(); }}><Settings class="size-4" aria-hidden="true" />{t('user.settings')}</MenuItem>
		<MenuItem testid="menu-permissions" onclick={() => { onsettings('berechtigungen'); close(); }}><ShieldCheck class="size-4" aria-hidden="true" />{t('settings.berechtigungen')}</MenuItem>
		{#if auth.user?.isAdmin}
			<MenuItem testid="menu-admin" onclick={() => { onsettings('verwaltung-konten'); close(); }}><UserCog class="size-4" aria-hidden="true" />{t('user.admin')}</MenuItem>
		{/if}
		<div class="px-2.5 pt-2 pb-1" role="group" aria-label={t('user.appearance')}>
			<p class="text-muted-foreground mb-1 text-xs">{t('user.appearance')}</p>
			<div class="bg-muted grid grid-cols-3 gap-0.5 rounded-lg p-0.5">
				{#each MODES as m (m.mode)}
					<button
						type="button"
						class={['min-h-8 rounded-md px-2 text-xs font-medium transition-colors', theme.mode === m.mode ? 'bg-background shadow-card' : 'text-muted-foreground hover:text-foreground']}
						aria-pressed={theme.mode === m.mode}
						data-testid="theme-{m.mode}"
						onclick={() => theme.setMode(m.mode)}
					>{t(m.label)}</button>
				{/each}
			</div>
		</div>
		<MenuItem testid="menu-help" onclick={() => { onhelp(); close(); }}><CircleHelp class="size-4" aria-hidden="true" />{t('user.help')}</MenuItem>
		<div class="bg-border my-1 h-px" role="separator"></div>
		<MenuItem onclick={() => auth.logout()}><LogOut class="size-4" aria-hidden="true" />{t('user.logout')}</MenuItem>
	{/snippet}
</Popover>
