<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { instance, type HealthReady } from '#lib/instance.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { DOCS_URL } from '#lib/helpNav.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';
	import GapNotice from './GapNotice.svelte';

	/** Read-only server pages that only show what /health/ready reports: mail, push, system. Storage has no data at all. */
	let { kind }: { kind: 'mail' | 'push' | 'storage' | 'system' } = $props();
	let health = $state<HealthReady | null>(null);
	let failed = $state(false);

	async function load() {
		failed = false;
		try {
			health = await instance.health();
		} catch {
			health = null;
			failed = true;
		}
	}
	$effect(() => {
		if (kind !== 'storage') attempt(load);
	});
	let caps = $state<{ passkey: boolean; password: boolean; bootstrapOpen: boolean } | null>(null);
	$effect(() => {
		if (kind !== 'system') return;
		attempt(async () => {
			const r = await fetch('/v1/capabilities');
			caps = r.ok ? await r.json() : null;
		});
	});
	const yn = (b: boolean) => (b ? t('settings.admin.system.yes') : t('settings.admin.system.no'));
</script>

<div class="flex flex-col gap-4" data-testid="admin-info-{kind}">
	{#if kind === 'mail'}
		<Panel title={t('settings.verwaltung-mail')}>
			{#if health?.mail}
				<p class="text-sm font-medium" data-testid="admin-mail-status">{health.mail.enabled ? t('settings.admin.mail.on') : t('settings.admin.mail.off')}</p>
			{:else if failed}<p class="text-sm">{t('settings.admin.system.fail')}</p>{/if}
			<p class="text-muted-foreground text-sm">{t('settings.admin.mail.edit')}</p>
			<p class="text-sm"><a class="text-ui-accent-ink underline underline-offset-2" href={DOCS_URL} target="_blank" rel="noopener noreferrer">{t('settings.admin.docs')}</a></p>
		</Panel>
		<GapNotice testid="admin-gap">{t('settings.admin.mail.gap')}</GapNotice>
	{:else if kind === 'push'}
		<Panel title={t('settings.verwaltung-push')}>
			{#if health?.push}
				<p class="text-sm font-medium" data-testid="admin-push-status">{health.push.enabled ? t('settings.admin.push.on', { env: health.push.environment }) : t('settings.admin.push.off')}</p>
			{:else if failed}<p class="text-sm">{t('settings.admin.system.fail')}</p>{/if}
		</Panel>
		<GapNotice testid="admin-gap">{t('settings.admin.push.gap')}</GapNotice>
	{:else if kind === 'storage'}
		<GapNotice testid="admin-gap">{t('settings.admin.storage.gap')}</GapNotice>
	{:else}
		<Panel title={t('settings.verwaltung-system')}>
			<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm" data-testid="admin-system">
				<dt class="text-muted-foreground">{t('settings.admin.system.status')}</dt>
				<dd data-testid="admin-system-status">{health ? t('settings.admin.system.ok') : failed ? t('settings.admin.system.fail') : t('common.loading')}</dd>
				{#if health?.maintenance}
					<dt class="text-muted-foreground">{t('settings.admin.system.maintenance')}</dt>
					<dd>{health.maintenance.enabled ? t('settings.admin.system.maintenance.on', { status: health.maintenance.lastStatus }) : t('settings.admin.system.maintenance.off')}</dd>
				{/if}
				{#if caps}
					<dt class="text-muted-foreground">{t('settings.admin.system.passkey')}</dt>
					<dd>{yn(caps.passkey)}</dd>
					<dt class="text-muted-foreground">{t('settings.admin.system.password')}</dt>
					<dd>{yn(caps.password)}</dd>
					<dt class="text-muted-foreground">{t('settings.admin.system.bootstrap')}</dt>
					<dd>{yn(caps.bootstrapOpen)}</dd>
				{/if}
			</dl>
			<div><Button size="sm" variant="outline" onclick={() => attempt(load)}>{t('settings.admin.system.refresh')}</Button></div>
		</Panel>
		<GapNotice testid="admin-gap">{t('settings.admin.system.gap')}</GapNotice>
	{/if}
</div>
