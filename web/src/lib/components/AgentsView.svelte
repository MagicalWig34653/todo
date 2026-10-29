<script lang="ts">
	import { api, type Pairing } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import Panel from './app/Panel.svelte';

	let label = $state('');
	let pairing = $state<Pairing | null>(null);

	async function pair(e: Event) {
		e.preventDefault();
		const l = label.trim();
		if (!l) return;
		if (await attempt(async () => (pairing = await api.pairDevice(l)))) label = '';
	}
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('nav.agents')} description={t('agents.hint')} testid="view-heading" />
	<Panel title={t('agents.pairTitle')} description={t('agents.pairHint')}>
		<form class="flex gap-2" onsubmit={pair}>
			<Input bind:value={label} placeholder={t('agents.labelPlaceholder')} aria-label={t('agents.label')} maxlength={100} />
			<Button type="submit" disabled={!label.trim()}>{t('agents.pair')}</Button>
		</form>
		{#if pairing}
			<div class="bg-muted/50 rounded-lg border p-3 text-sm" data-testid="pairing-code">
				<p class="text-muted-foreground mb-1">{t('agents.codeOnce', { until: formatWhen(pairing.expiresAt) })}</p>
				<code class="text-base font-semibold break-all">{pairing.code}</code>
			</div>
		{/if}
	</Panel>
	<Panel title={t('agents.limitsTitle')}>
		<p class="text-muted-foreground text-sm">{t('agents.limits')}</p>
	</Panel>
</section>
