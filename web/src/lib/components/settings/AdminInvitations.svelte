<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { onMount } from 'svelte';
	import { instance, sortInvitations, type Invitation, type InvitationSummary } from '#lib/instance.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { createLatest } from '#lib/serial.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';
	import { buildInviteLink } from '#lib/inviteLink.js';
	import CopyBox from './CopyBox.svelte';

	// Held in memory only; the server stores a hash and shows the token once.
	let issued = $state<Invitation | null>(null);
	let busy = $state(false);
	let list = $state<InvitationSummary[]>([]);
	let info = $state<string | null>(null);

	const latest = createLatest();
	async function load() {
		const current = latest.begin();
		await attempt(async () => {
			const next = sortInvitations(await instance.listInvitations());
			if (current()) list = next;
		});
	}
	onMount(load);

	async function withdraw(i: InvitationSummary) {
		info = null;
		if (await attempt(async () => { await instance.withdrawInvitation(i.id); await load(); }, load)) info = t('settings.admin.invite.withdrawn');
	}

	async function create() {
		busy = true;
		issued = null;
		await attempt(async () => {
			issued = await instance.createInvitation();
			await load();
		});
		busy = false;
	}
	const link = $derived(issued ? buildInviteLink(location.origin, issued.token) : '');
</script>

<Panel title={t('settings.verwaltung-einladungen')} description={t('settings.admin.invite.hint')}>
	<div><Button size="lg" disabled={busy} onclick={create} data-testid="invite-create">{t('settings.admin.invite.create')}</Button></div>
	{#if issued}
		<div class="flex flex-col gap-2 rounded-lg border p-3" role="status" data-testid="invite-result" data-id={issued.id}>
			<CopyBox value={issued.token} label={t('settings.admin.invite.code')} testid="invite-code" />
			<CopyBox value={link} label={t('settings.admin.invite.link')} testid="invite-link" />
			<p class="text-muted-foreground text-xs">{t('settings.admin.invite.expires', { when: formatWhen(issued.expiresAt) })}</p>
		</div>
	{/if}
</Panel>
<Panel title={t('settings.admin.invite.list')} description={t('settings.admin.invite.listHint')}>
	{#if info}<p class="text-sm" role="status" data-testid="invite-info">{info}</p>{/if}
	{#if list.length === 0}<p class="text-muted-foreground text-sm">{t('settings.admin.invite.empty')}</p>{/if}
	<ul class="flex flex-col divide-y" data-testid="invite-list">
		{#each list as i (i.id)}
			<li class="flex flex-wrap items-center gap-2 py-2 text-sm" data-testid="invite-row" data-status={i.status} data-id={i.id}>
				<span class="flex-1">
					{t(`settings.admin.invite.status.${i.status}`, { when: formatWhen(i.status === 'used' && i.usedAt ? i.usedAt : i.expiresAt) })}
					<span class="text-muted-foreground text-xs">· {t('settings.admin.invite.by', { name: i.createdByName })}</span>
				</span>
				{#if i.status === 'open'}
					<Button size="xs" variant="outline" onclick={() => withdraw(i)} data-testid="invite-withdraw">{t('settings.admin.invite.withdraw')}</Button>
				{/if}
			</li>
		{/each}
	</ul>
</Panel>
