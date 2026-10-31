<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { DOCS_URL } from '#lib/helpNav.js';
	import Panel from '../app/Panel.svelte';
	import GapNotice from './GapNotice.svelte';
</script>

<GapNotice testid="data-gap">{t('settings.data.text')}</GapNotice>
<Panel title={t('settings.daten')}>
	<p class="text-muted-foreground text-sm">{t('settings.data.owned')}</p>
	<p class="text-sm"><a class="text-ui-accent-ink underline underline-offset-2" href={DOCS_URL} target="_blank" rel="noopener noreferrer">{t('settings.gap.roadmap')}</a></p>
</Panel>
