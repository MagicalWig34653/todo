<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import Activity from '@lucide/svelte/icons/activity';
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('nav.activity')} testid="view-heading" />
	<EmptyState title={t('activity.title')} icon={Activity}>
		<p>{t('activity.hint')}</p>
	</EmptyState>
</section>
