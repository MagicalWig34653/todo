<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import OAuthGrants from '../OAuthGrants.svelte';

	let { onopen }: { onopen: (id: string) => void } = $props();
</script>

<p class="text-sm">
	{t('settings.connected.hint')}
	<a href="/settings/mcp" class="text-ui-accent-ink underline underline-offset-2" onclick={(e) => { e.preventDefault(); onopen('mcp'); }}>{t('settings.connected.setup')}</a>
</p>
<OAuthGrants />
