<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';

	let { onagents }: { onagents: () => void } = $props();
	let count = $state<number | null>(null);
	let allowed = $state<boolean | null>(null);
	let saving = $state(false);
	let autoError = $state('');
	async function loadAllowed() {
		try {
			allowed = (await api.autoStartSetting()).allowed;
		} catch {
			autoError = t('autostart.account.loadFailed');
		}
	}
	async function setAllowed(next: boolean) {
		saving = true;
		autoError = '';
		try {
			allowed = (await api.setAutoStartSetting(next)).allowed;
		} catch {
			autoError = t('autostart.account.saveFailed');
			await loadAllowed();
		} finally {
			saving = false;
		}
	}
	$effect(() => {
		void loadAllowed();
	});
	$effect(() => {
		attempt(async () => {
			count = (await api.listDevices()).filter((d) => d.paired && !d.revokedAt).length;
		});
	});
</script>

<Panel title={t('settings.runner')}>
	<p class="text-sm">{t('settings.runner.hint')}</p>
	{#if count !== null}<p class="text-sm font-medium" data-testid="runner-count">{t('settings.runner.count', { count })}</p>{/if}
	<div><Button size="sm" onclick={onagents}>{t('settings.runner.open')}</Button></div>
</Panel>

<Panel title={t('autostart.account.title')}>
	<label class="flex items-start gap-2 text-sm" for="account-autostart">
		<input
			id="account-autostart"
			type="checkbox"
			role="switch"
			class="focus-visible:ring-ring mt-0.5 size-4 shrink-0 rounded focus-visible:ring-2 focus-visible:outline-none"
			checked={allowed === true}
			disabled={allowed === null || saving}
			aria-describedby="account-autostart-hint"
			data-testid="account-autostart"
			onchange={(ev) => setAllowed((ev.currentTarget as HTMLInputElement).checked)}
		/>
		<span class="font-medium">{t('autostart.account.label')}</span>
	</label>
	<p id="account-autostart-hint" class="text-muted-foreground text-xs">{t('autostart.account.hint')}</p>
	<p class="text-xs" role="status" aria-live="polite" data-testid="account-autostart-state">{allowed === null ? '' : allowed ? t('autostart.account.on') : t('autostart.account.off')}</p>
	{#if autoError}<p class="text-destructive text-xs" role="alert">{autoError}</p>{/if}
</Panel>
