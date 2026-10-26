<script lang="ts">
	import { api, type Passkey, type SessionInfo } from '#lib/api.js';
	import { auth, PasskeyError } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { passkeysSupported, serializeRegistration, toCreationOptions } from '#lib/webauthn.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	let passkeys = $state<Passkey[]>([]);
	let sessions = $state<SessionInfo[]>([]);
	let newName = $state('');
	let renamingID = $state<string | null>(null);
	let renameText = $state('');
	let revokingID = $state<string | null>(null);
	let info = $state<string | null>(null);

	async function load() {
		[passkeys, sessions] = await Promise.all([api.listPasskeys(), api.listSessions()]);
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
	async function endSession(s: SessionInfo) {
		if (s.current) {
			await auth.logout();
			return;
		}
		await attempt(async () => { await api.revokeSession(s.id); await load(); }, load);
	}
	async function endOthers() {
		info = null;
		if (await attempt(async () => { await api.revokeOtherSessions(); await load(); }, load)) info = t('account.sessions.revokeOthersDone');
	}
</script>

<section class="flex flex-col gap-6">
	<h2 class="text-xl font-semibold" data-testid="view-heading">{t('account.title')}</h2>

	<div class="flex flex-col gap-1 text-sm">
		<h3 class="font-medium">{t('account.id')}</h3>
		<code class="bg-muted w-fit rounded px-2 py-1 text-xs break-all" data-testid="account-id">{auth.user?.id}</code>
		<p class="text-muted-foreground text-xs">{t('account.idHint')}</p>
	</div>

	{#if info}<p class="text-sm" role="status" data-testid="account-info">{info}</p>{/if}

	<div class="flex flex-col gap-2">
		<h3 class="text-sm font-medium">{t('account.passkeys')}</h3>
		<ul class="flex flex-col gap-1">
			{#each passkeys as p (p.id)}
				<li class="rounded-md border p-2 text-sm" data-testid="passkey-item">
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
	</div>

	<div class="flex flex-col gap-2">
		<h3 class="text-sm font-medium">{t('account.sessions')}</h3>
		<ul class="flex flex-col gap-1">
			{#each sessions as s (s.id)}
				<li class="flex flex-wrap items-center gap-2 rounded-md border p-2 text-sm" data-testid="session-item">
					<span class="flex-1">
						{#if s.current}<strong>{t('account.sessions.current')}</strong>{/if}
						{#if s.createdAt}<span class="text-muted-foreground text-xs">{t('account.sessions.created', { when: formatWhen(s.createdAt) })}</span>{/if}
						<span class="text-muted-foreground text-xs">{t('account.sessions.expires', { when: formatWhen(s.expiresAt) })}</span>
					</span>
					<Button size="xs" variant="outline" onclick={() => endSession(s)}>{t('account.sessions.revoke')}</Button>
				</li>
			{/each}
		</ul>
		{#if sessions.length > 1}
			<div><Button size="sm" variant="outline" onclick={endOthers}>{t('account.sessions.revokeOthers')}</Button></div>
		{/if}
	</div>
</section>
