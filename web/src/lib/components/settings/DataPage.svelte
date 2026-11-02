<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import Panel from '../app/Panel.svelte';
	import GapNotice from './GapNotice.svelte';
</script>

<GapNotice testid="data-gap">{t('settings.data.text')}</GapNotice>
<Panel title={t('settings.daten')}>
	<p class="text-muted-foreground text-sm">{t('settings.data.owned')}</p>
</Panel>
