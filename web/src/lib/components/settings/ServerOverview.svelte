<script lang="ts">
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { adminSettings, type AuditEntry, type ServerSettingsOverview } from '#lib/adminSettings.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';

	/** Server overview for administrators: key status, values that only exist in the environment, change log. */
	let overview = $state<ServerSettingsOverview | null>(null);
	let audit = $state<AuditEntry[] | null>(null);

	async function load() {
		overview = await adminSettings.overview();
		audit = await adminSettings.audit(100);
	}
	$effect(() => {
		attempt(load);
	});
	const actionText = (a: AuditEntry['action']) => t(`admin.server.audit.${a}` as MessageKey);
</script>

<div class="flex flex-col gap-4" data-testid="server-overview">
	{#if overview}
		{#if overview.lastError}<p class="bg-warning-soft text-warning rounded-lg px-3 py-2 text-sm" role="status">{t('admin.server.lastError')}</p>{/if}
		<Panel title={t('admin.server.overview.key')}>
			<p class="flex items-center gap-2 text-sm" data-testid="server-key" data-configured={overview.encryptionKeyConfigured}>
				<Badge variant={overview.encryptionKeyConfigured ? 'success' : 'warning'}>{overview.encryptionKeyConfigured ? t('admin.server.secret.set') : t('admin.server.secret.unset')}</Badge>
				{overview.encryptionKeyConfigured ? t('admin.server.overview.key.on') : t('admin.server.overview.key.off')}
			</p>
		</Panel>
		<Panel title={t('admin.server.fixed.title')} description={t('admin.server.fixed.intro')}>
			<dl class="grid gap-3 text-sm" data-testid="server-fixed">
				{#each overview.fixed as f (f.name)}
					<div class="flex flex-col gap-0.5">
						<dt class="flex flex-wrap items-center gap-2 font-medium">
							{f.label}
							<Badge variant={f.isSet ? 'success' : 'default'}>{f.isSet ? t('admin.server.fixed.set') : t('admin.server.fixed.unset')}</Badge>
						</dt>
						<dd class="text-muted-foreground text-[13px]">{f.help}{#if f.value}&nbsp;<code class="text-foreground break-all">{f.value}</code>{/if}</dd>
					</div>
				{/each}
			</dl>
		</Panel>
	{/if}
	<Panel title={t('admin.server.audit.title')}>
		{#snippet action()}
			<Button size="sm" variant="ghost" onclick={() => attempt(load)}>{t('admin.server.audit.refresh')}</Button>
		{/snippet}
		{#if audit && audit.length === 0}
			<p class="text-muted-foreground text-sm">{t('admin.server.audit.empty')}</p>
		{:else if audit}
			<ul class="divide-y text-sm" data-testid="server-audit">
				{#each audit as e (e.id)}
					<li class="flex flex-wrap items-baseline justify-between gap-x-3 py-1.5" data-testid="server-audit-row" data-key={e.key}>
						<span>{t('admin.server.audit.row', { who: e.actorName, key: e.key, action: actionText(e.action) })}</span>
						<span class="text-muted-foreground text-xs">{formatWhen(e.at)}</span>
					</li>
				{/each}
			</ul>
		{/if}
	</Panel>
</div>
