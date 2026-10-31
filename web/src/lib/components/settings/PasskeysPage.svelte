<script lang="ts">
	import { api, type Passkey } from '#lib/api.js';
	import { PasskeyError } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { passkeysSupported, serializeRegistration, toCreationOptions } from '#lib/webauthn.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import Panel from '../app/Panel.svelte';

	let passkeys = $state<Passkey[]>([]);
	let newName = $state('');
	let renamingID = $state<string | null>(null);
	let renameText = $state('');
	let revokingID = $state<string | null>(null);
	let info = $state<string | null>(null);

	async function load() {
		passkeys = await api.listPasskeys();
	}
	$effect(() => {
		attempt(load);
	});

	async function addPasskey(e: Event) {
		e.preventDefault();
		info = null;
		const ok = await attempt(async () => {
			if (!passkeysSupported()) throw new PasskeyError('passkey_unsupported');
			const { challengeID, options } = await api.addPasskeyBegin();
			let credential: Credential | null;
			try {
				credential = await navigator.credentials.create({ publicKey: toCreationOptions(options) });
			} catch {
				throw new PasskeyError('passkey_cancelled');
			}
			if (!credential) throw new PasskeyError('passkey_cancelled');
			await api.addPasskeyFinish(challengeID, serializeRegistration(credential as PublicKeyCredential), newName.trim() || undefined);
			await load();
		}, load);
		if (ok) {
			newName = '';
			info = t('account.added');
		}
	}
	async function rename(p: Passkey) {
		const name = renameText.trim();
		if (!name) return;
		if (await attempt(async () => { await api.renamePasskey(p.id, name); await load(); }, load)) renamingID = null;
	}
	async function revoke(p: Passkey) {
		if (await attempt(async () => { await api.revokePasskey(p.id); await load(); }, load)) revokingID = null;
	}
</script>

{#if info}<p class="bg-success-soft text-success rounded-lg px-3 py-2 text-sm" role="status" data-testid="account-info">{info}</p>{/if}

<Panel title={t('account.passkeys')}>
	<ul class="flex flex-col gap-2">
		{#each passkeys as p (p.id)}
			<li class="rounded-lg border p-2.5 text-sm" data-testid="passkey-item">
				<div class="flex flex-wrap items-center gap-2">
					<span class={['flex-1', p.revokedAt && 'text-muted-foreground line-through']}>{p.name || t('account.passkeys.unnamed')}</span>
					{#if p.createdAt}<span class="text-muted-foreground text-xs">{t('account.passkeys.created', { when: formatWhen(p.createdAt) })}</span>{/if}
					{#if p.revokedAt}
						<span class="text-muted-foreground text-xs">{t('account.passkeys.revoked')}</span>
					{:else}
						<Button size="xs" variant="ghost" aria-label={t('account.passkeys.rename', { name: p.name })} onclick={() => ((renamingID = p.id), (renameText = p.name))}>{t('common.rename')}</Button>
						<Button size="xs" variant="destructive" onclick={() => (revokingID = p.id)}>{t('account.passkeys.revoke')}</Button>
					{/if}
				</div>
				{#if renamingID === p.id}
					<form class="mt-2 flex gap-1" onsubmit={(e) => { e.preventDefault(); rename(p); }}>
						<Input bind:value={renameText} aria-label={t('common.rename')} />
						<Button type="submit" size="lg">{t('common.save')}</Button>
						<Button type="button" size="lg" variant="ghost" onclick={() => (renamingID = null)}>{t('common.cancel')}</Button>
					</form>
				{/if}
				{#if revokingID === p.id}
					<div class="mt-2 flex flex-wrap items-center gap-2">
						<span>{t('account.passkeys.revokeConfirm', { name: p.name })}</span>
						<Button size="sm" variant="destructive" onclick={() => revoke(p)}>{t('account.passkeys.revoke')}</Button>
						<Button size="sm" variant="ghost" onclick={() => (revokingID = null)}>{t('common.cancel')}</Button>
					</div>
				{/if}
			</li>
		{/each}
	</ul>
	<form class="flex gap-2" onsubmit={addPasskey}>
		<Input bind:value={newName} placeholder={t('account.passkeys.name')} aria-label={t('account.passkeys.name')} />
		<Button type="submit" size="lg">{t('account.passkeys.add')}</Button>
	</form>
</Panel>
