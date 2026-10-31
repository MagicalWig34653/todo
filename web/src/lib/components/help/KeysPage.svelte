<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import Panel from '../app/Panel.svelte';
	import ShortcutList from './ShortcutList.svelte';
</script>

<Panel title={t('help.keys')}>
	<ShortcutList />
	<p class="text-muted-foreground text-xs">{t('help.keys.note')}</p>
</Panel>
