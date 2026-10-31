<script lang="ts">
	import { api, type EmailStatus } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	let status = $state<EmailStatus | null>(null);
	let address = $state('');
	let info = $state<string | null>(null);
	let confirmRemove = $state(false);
	let busy = $state(false);

	async function load() {
		status = await api.getEmail();
	}
	$effect(() => {
		attempt(load);
	});

	async function save(e: Event) {
		e.preventDefault();
		const email = address.trim();
		if (!email) return;
		info = null;
		if (await attempt(async () => { await api.setEmail(email); await load(); }, load)) {
			address = '';
			info = t('email.requested');
		}
	}
	async function remove() {
		info = null;
		if (await attempt(async () => { await api.removeEmail(); await load(); }, load)) {
			confirmRemove = false;
			info = t('email.removed');
		}
	}
	async function test() {
		busy = true;
		info = null;
		try {
			if (await attempt(async () => { await api.sendTestEmail(); })) {
				info = t('email.test.queued');
				// the worker sends within seconds; show the outcome afterwards
				setTimeout(() => void load().catch(() => {}), 15000);
			}
		} finally {
			busy = false;
		}
	}
	const last = $derived(status?.lastMail ?? null);
</script>

<div class="bg-card flex flex-col gap-3 rounded-xl border p-4 shadow-card sm:p-5" data-testid="email-settings">
	<div>
		<h3 class="text-base font-semibold">{t('email.title')}</h3>
		<p class="text-muted-foreground mt-1 text-xs">{t('email.intro')}</p>
	</div>

	{#if status}
		<p class={['rounded-lg px-3 py-2 text-sm', status.mailEnabled ? 'bg-success-soft text-success' : 'bg-muted text-muted-foreground']} role="status" data-testid="email-server" data-enabled={status.mailEnabled}>
			{status.mailEnabled ? t('email.server.on') : t('email.server.off')}
		</p>
		{#if info}<p class="text-sm" role="status" data-testid="email-info">{info}</p>{/if}

		<div class="text-sm">
			<span class="text-muted-foreground text-xs">{t('email.current')}</span>
			{#if status.email}
				<div class="flex flex-wrap items-center gap-2">
					<strong class="break-all" data-testid="email-current">{status.email}</strong>
					<span class="text-muted-foreground text-xs">{t('email.verifiedAt', { when: formatWhen(status.verifiedAt) })}</span>
				</div>
			{:else}
				<p class="text-muted-foreground">{t('email.none')}</p>
			{/if}
			{#if status.pending}
				<p class="mt-1 text-sm" data-testid="email-pending">{t('email.pending', { email: status.pending, when: formatWhen(status.pendingExpiresAt) })}</p>
			{/if}
		</div>

		{#if status.mailEnabled}
			<form class="flex flex-col gap-2 sm:flex-row" onsubmit={save}>
				<Input type="email" autocomplete="email" bind:value={address} placeholder={t('email.address')} aria-label={t('email.address')} data-testid="email-input" />
				<Button type="submit" size="lg" data-testid="email-save">{t('email.save')}</Button>
			</form>
			<div class="flex flex-wrap items-center gap-2">
				{#if status.email}
					<Button size="sm" variant="outline" disabled={busy} onclick={test} data-testid="email-test">{t('email.test')}</Button>
					<Button size="sm" variant="ghost" onclick={() => (confirmRemove = true)}>{t('email.remove')}</Button>
				{/if}
			</div>
			{#if confirmRemove}
				<div class="flex flex-wrap items-center gap-2 text-sm">
					<span>{t('email.removeConfirm')}</span>
					<Button size="sm" variant="destructive" onclick={remove}>{t('email.remove')}</Button>
					<Button size="sm" variant="ghost" onclick={() => (confirmRemove = false)}>{t('common.cancel')}</Button>
				</div>
			{/if}
		{/if}
		{#if last}
			<p class="text-muted-foreground text-xs" data-testid="email-last">
				{t('email.last', {
					kind: t(`email.kind.${last.kind}` as MessageKey),
					state: t(`email.state.${last.state}` as MessageKey),
					when: last.at ? `, ${formatWhen(last.at)}` : ''
				})}
			</p>
		{/if}
	{/if}
</div>
