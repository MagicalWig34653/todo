<script lang="ts">
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';

	let { onsettings }: { onsettings: () => void } = $props();
	const STEPS = ['s1', 's2', 's3', 's4'] as const;
</script>

<div class="flex flex-col gap-4" data-testid="help-start">
	{#each STEPS as s (s)}
		<Panel title={t(`help.start.${s}.title` as MessageKey)}>
			<p class="text-sm">{t(`help.start.${s}.text` as MessageKey)}</p>
		</Panel>
	{/each}
	<div><Button variant="outline" onclick={onsettings}>{t('help.start.go')}</Button></div>
</div>
