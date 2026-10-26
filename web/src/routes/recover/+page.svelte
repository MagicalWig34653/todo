<script lang="ts">
	import { api } from '#lib/api.js';
	import { PasskeyError } from '#lib/auth.svelte.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { passkeysSupported, serializeRegistration, toCreationOptions } from '#lib/webauthn.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';

	let code = $state('');
	let passkeyName = $state('');
	let bearer = $state<string | null>(null);
	let done = $state(false);
	let busy = $state(false);
	let error = $state<string | null>(null);

	async function run(action: () => Promise<void>) {
		busy = true;
		error = null;
		try {
			await action();
		} catch (e) {
			error = describeError(e);
		} finally {
			busy = false;
		}
	}

	const redeem = (e: Event) => {
		e.preventDefault();
		return run(async () => {
			// The recovery bearer is held in memory only; it is never persisted or sent with cookies.
			bearer = (await api.redeemRecovery(code.trim())).token;
			code = '';
		});
	};

	const create = (e: Event) => {
		e.preventDefault();
		return run(async () => {
			if (!bearer) return;
			if (!passkeysSupported()) throw new PasskeyError('passkey_unsupported');
			const { challengeID, options } = await api.recoveryPasskeyBegin(bearer);
			let credential: Credential | null;
			try {
				credential = await navigator.credentials.create({ publicKey: toCreationOptions(options) });
			} catch {
				throw new PasskeyError('passkey_cancelled');
			}
			if (!credential) throw new PasskeyError('passkey_cancelled');
			await api.recoveryPasskeyFinish(
				bearer,
				challengeID,
				serializeRegistration(credential as PublicKeyCredential),
				passkeyName.trim() || undefined
			);
			bearer = null;
			done = true;
		});
	};
</script>

<main class="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-4 px-4 py-10">
	<h1 class="text-2xl font-semibold">{t('recovery.title')}</h1>
	<p class="text-muted-foreground text-sm">{t('recovery.intro')}</p>

	{#if done}
		<p role="status" class="text-sm" data-testid="recovery-done">{t('recovery.done')}</p>
	{:else if !bearer}
		<form class="flex flex-col gap-3" onsubmit={redeem}>
			<Label for="code">{t('recovery.code')}</Label>
			<Input id="code" autocomplete="off" bind:value={code} />
			<Button type="submit" disabled={busy || !code.trim()}>{t('recovery.redeem')}</Button>
		</form>
	{:else}
		<form class="flex flex-col gap-3" onsubmit={create}>
			<Label for="pk">{t('recovery.passkeyName')}</Label>
			<Input id="pk" bind:value={passkeyName} />
			<Button type="submit" disabled={busy}>{t('recovery.create')}</Button>
		</form>
	{/if}

	{#if error}<p role="alert" class="text-destructive text-sm">{error}</p>{/if}
	<a class="text-muted-foreground text-sm underline" href="/">{t('recovery.toLogin')}</a>
</main>
