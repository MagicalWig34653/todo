<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { instance, type Invitation } from '#lib/instance.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';
	import CopyBox from './CopyBox.svelte';
	import GapNotice from './GapNotice.svelte';

	// Held in memory only; the server stores a hash and shows the token once.
	let issued = $state<Invitation | null>(null);
	let busy = $state(false);

	async function create() {
		busy = true;
		issued = null;
		await attempt(async () => {
			issued = await instance.createInvitation();
		});
		busy = false;
	}
	const link = $derived(issued ? `${location.origin}/setup?token=${encodeURIComponent(issued.token)}` : '');
</script>

<Panel title={t('settings.verwaltung-einladungen')} description={t('settings.admin.invite.hint')}>
	<div><Button size="lg" disabled={busy} onclick={create} data-testid="invite-create">{t('settings.admin.invite.create')}</Button></div>
	{#if issued}
		<div class="flex flex-col gap-2 rounded-lg border p-3" role="status" data-testid="invite-result">
			<CopyBox value={issued.token} label={t('settings.admin.invite.code')} testid="invite-code" />
			<CopyBox value={link} label={t('settings.admin.invite.link')} testid="invite-link" />
			<p class="text-muted-foreground text-xs">{t('settings.admin.invite.expires', { when: formatWhen(issued.expiresAt) })}</p>
		</div>
	{/if}
</Panel>
<GapNotice testid="invite-gap">{t('settings.admin.invite.gap')}</GapNotice>
