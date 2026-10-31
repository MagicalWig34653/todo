<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { checkConnection, connectCommands, type CheckResult } from '#lib/claudeConnect.js';
	import { DOCS_URL } from '#lib/helpNav.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import CircleAlert from '@lucide/svelte/icons/circle-alert';
	import CircleX from '@lucide/svelte/icons/circle-x';
	import Panel from '../app/Panel.svelte';
	import CopyBox from '../settings/CopyBox.svelte';

	// The server address is the origin of this page: the PWA is served by the same host as the API and /mcp.
	const origin = window.location.origin;
	const cmd = connectCommands(origin);
	let results = $state<CheckResult[] | null>(null);
	let busy = $state(false);

	async function run() {
		busy = true;
		results = null;
		results = await checkConnection((u, i) => fetch(u, i), origin);
		busy = false;
	}
</script>

<div class="flex flex-col gap-4" data-testid="claude-connect">
	<p class="text-sm">{t('claude.intro')}</p>
	<Panel title={t('claude.server')}>
		<CopyBox value={origin} label={t('claude.server')} testid="claude-origin" />
	</Panel>
	<Panel title={t('claude.step1')} description={t('claude.step1.hint')}>
		<CopyBox value={cmd.marketplace} label="1" testid="claude-cmd-marketplace" />
		<CopyBox value={cmd.install} label="2" testid="claude-cmd-install" />
	</Panel>
	<Panel title={t('claude.step2')} description={t('claude.step2.hint')}>
		<CopyBox value={cmd.mcpAdd} label="claude mcp add" testid="claude-cmd-mcp" />
	</Panel>
	<Panel title={t('claude.step3')} description={t('claude.step3.hint')}></Panel>
	<Panel title={t('claude.check')} description={t('claude.check.hint')}>
		<div><Button size="lg" disabled={busy} onclick={run} data-testid="claude-check">{busy ? t('claude.checking') : t('claude.check')}</Button></div>
		{#if results}
			<ul class="flex flex-col gap-2" data-testid="claude-check-results">
				{#each results as r (r.id)}
					<li class="flex items-start gap-2 rounded-lg border p-2.5 text-sm" data-state={r.state} data-testid="claude-check-{r.id}">
						{#if r.state === 'ok'}<CircleCheck class="text-success mt-0.5 size-4 shrink-0" aria-hidden="true" />
						{:else if r.state === 'warn'}<CircleAlert class="text-warning mt-0.5 size-4 shrink-0" aria-hidden="true" />
						{:else}<CircleX class="text-destructive mt-0.5 size-4 shrink-0" aria-hidden="true" />{/if}
						<span><strong>{t(`claude.state.${r.state}`)}:</strong> {t(r.message, r.params)}</span>
					</li>
				{/each}
			</ul>
		{/if}
	</Panel>
	<p class="text-sm"><a class="text-ui-accent-ink underline underline-offset-2" href={DOCS_URL} target="_blank" rel="noopener noreferrer">{t('claude.docs')}</a></p>
</div>
