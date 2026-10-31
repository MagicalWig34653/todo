<script lang="ts">
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import Panel from '../app/Panel.svelte';
	import Avatar from '../app/Avatar.svelte';
</script>

<Panel title={t('settings.profil')}>
	<div class="flex items-center gap-3">
		<Avatar name={auth.user?.displayName ?? '?'} />
		<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
			<dt class="text-muted-foreground">{t('settings.profile.name')}</dt>
			<dd data-testid="profile-name">{auth.user?.displayName}</dd>
			<dt class="text-muted-foreground">{t('settings.profile.username')}</dt>
			<dd>{auth.user?.username ?? t('settings.profile.none')}</dd>
			<dt class="text-muted-foreground">{t('settings.profile.role')}</dt>
			<dd data-testid="profile-role">{auth.user?.isAdmin ? t('settings.profile.admin') : t('settings.profile.member')}</dd>
		</dl>
	</div>
	<p class="text-muted-foreground text-xs">{t('settings.profile.hint')}</p>
</Panel>

<Panel title={t('account.id')}>
	<code class="bg-muted w-fit rounded px-2 py-1 text-xs break-all" data-testid="account-id">{auth.user?.id}</code>
	<p class="text-muted-foreground text-xs">{t('account.idHint')}</p>
</Panel>
