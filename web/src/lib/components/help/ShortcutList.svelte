<script lang="ts">
	import { t } from '#lib/i18n/index.js';
</script>

<dl class="grid grid-cols-[auto_1fr] items-center gap-x-4 gap-y-2 text-sm" data-testid="shortcut-list">
	<dt><kbd class="bg-muted rounded border px-1.5 py-0.5 text-xs">Q</kbd></dt>
	<dd>{t('help.keys.q')}</dd>
	<dt><kbd class="bg-muted rounded border px-1.5 py-0.5 text-xs">?</kbd></dt>
	<dd>{t('help.keys.question')}</dd>
	<dt><kbd class="bg-muted rounded border px-1.5 py-0.5 text-xs">Esc</kbd></dt>
	<dd>{t('help.keys.esc')}</dd>
</dl>
