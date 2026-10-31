<script lang="ts">
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import Panel from '../app/Panel.svelte';
	import RecoveryIssue from '../RecoveryIssue.svelte';
	import GapNotice from './GapNotice.svelte';
</script>

<div class="flex flex-col gap-4" data-testid="admin-area">
	<Panel title={t('access.admin.accountID')}>
		<code class="bg-muted w-fit rounded px-2 py-1 text-xs break-all">{auth.user?.id}</code>
	</Panel>
	<RecoveryIssue />
	<GapNotice testid="admin-gaps">{t('settings.admin.accounts.gap')}</GapNotice>
</div>
