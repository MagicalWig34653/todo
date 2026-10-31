<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import Panel from '../app/Panel.svelte';

	let active = $state<number | null>(null);
	$effect(() => {
		attempt(async () => {
			active = (await api.listPasskeys()).filter((p) => !p.revokedAt).length;
		});
	});
</script>

<Panel title={t('settings.recovery.title')}>
	<p class="text-sm">{t('settings.recovery.p1')}</p>
	<p class="text-sm">{t('settings.recovery.p2')}</p>
	{#if active !== null}
		<p class="text-sm font-medium" data-testid="recovery-passkey-count">{t('settings.recovery.passkeys', { count: active })}</p>
	{/if}
	<p class="text-muted-foreground text-sm">{t('settings.recovery.tip')}</p>
	<p class="text-sm"><a class="text-ui-accent-ink underline underline-offset-2" href="/recover">{t('settings.recovery.open')}</a></p>
</Panel>
