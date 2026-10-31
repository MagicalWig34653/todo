<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';

	let { onagents }: { onagents: () => void } = $props();
	let count = $state<number | null>(null);
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
