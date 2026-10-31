<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { CHANGELOG_URL, DOCS_URL, ISSUES_URL } from '#lib/helpNav.js';
	import { instance, type HealthReady } from '#lib/instance.js';
	import Panel from '../app/Panel.svelte';

	let health = $state<HealthReady | null>(null);
	let failed = $state(false);
	$effect(() => {
		instance.health().then(
			(h) => (health = h),
			() => (failed = true)
		);
	});
	const link = 'text-ui-accent-ink underline underline-offset-2';
</script>

<div class="flex flex-col gap-4" data-testid="about">
	<Panel title={t('about.server')}>
		<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
			<dt class="text-muted-foreground">{t('about.origin')}</dt>
			<dd class="break-all" data-testid="about-origin">{window.location.origin}</dd>
			<dt class="text-muted-foreground">{t('about.status')}</dt>
			<dd data-testid="about-status">{health ? t('settings.admin.system.ok') : failed ? t('settings.admin.system.fail') : t('common.loading')}</dd>
			<dt class="text-muted-foreground">{t('about.pwa')}</dt>
			<dd>{t('about.version', { version: __APP_VERSION__ })}</dd>
		</dl>
		<p class="text-muted-foreground text-xs">{t('about.servernote')}</p>
	</Panel>
	<Panel title={t('about.docs')}>
		<ul class="flex flex-col gap-1 text-sm">
			<li><a class={link} href={DOCS_URL} target="_blank" rel="noopener noreferrer">{t('help.docs')}</a></li>
			<li><a class={link} href={CHANGELOG_URL} target="_blank" rel="noopener noreferrer">{t('about.changes')}</a></li>
			<li><a class={link} href={ISSUES_URL} target="_blank" rel="noopener noreferrer">{t('about.report')}</a></li>
		</ul>
		<p class="text-muted-foreground text-xs">{t('about.changes.note')}</p>
	</Panel>
</div>
