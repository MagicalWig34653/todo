<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type Capabilities } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { loginRedirectTarget } from '#lib/routing.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import AuthShell from '#lib/components/app/AuthShell.svelte';
	import Fingerprint from '@lucide/svelte/icons/fingerprint';
	import { Label } from '#lib/components/ui/label/index.js';

	let caps = $state<Capabilities | null>(null);
	let showOther = $state(false);
	let username = $state('');
	let password = $state('');
	let busy = $state(false);
	let error = $state<string | null>(null);

	onMount(async () => {
		try {
			caps = await api.capabilities();
		} catch (e) {
			error = describeError(e);
		}
	});

	async function run(action: () => Promise<void>) {
		busy = true;
		error = null;
		// After sign-in the workspace opens the URL in the address bar; `?redirect=` (same origin only) names where to go.
		const target = loginRedirectTarget(location.search);
		if (target) history.replaceState(null, '', target);
		try {
			await action();
		} catch (e) {
			error = describeError(e);
		} finally {
			busy = false;
		}
	}
</script>

<AuthShell title={t('login.title')}>

	<Button size="lg" class="h-11 w-full text-[15px]" disabled={busy} onclick={() => run(() => auth.loginWithPasskey())}>
		<Fingerprint aria-hidden="true" />{t('login.passkey')}
	</Button>

	{#if caps?.password}
		<Button variant="ghost" class="w-full" onclick={() => (showOther = !showOther)}>
			{t('login.otherMethod')}
		</Button>
		{#if showOther}
			<form
				class="flex flex-col gap-3"
				onsubmit={(e) => {
					e.preventDefault();
					run(() => auth.loginWithPassword(username, password));
				}}
			>
				<Label for="username">{t('login.username')}</Label>
				<Input id="username" autocomplete="username" bind:value={username} />
				<Label for="password">{t('login.password')}</Label>
				<Input id="password" type="password" autocomplete="current-password" bind:value={password} />
				<Button type="submit" variant="secondary" disabled={busy}>{t('login.passwordSubmit')}</Button>
			</form>
		{/if}
	{/if}

	{#if error}
		<p role="alert" class="text-destructive text-sm">{error}</p>
	{/if}

	<div class="text-muted-foreground flex flex-col gap-1 text-sm">
		{#if caps?.bootstrapOpen}
			<p>{t('login.bootstrapHint')}</p>
		{/if}
		<a class="hover:text-foreground underline" href="/recover">{t('login.recoveryLink')}</a>
		<a class="hover:text-foreground underline" href="/setup">
			{caps?.bootstrapOpen ? t('login.bootstrapLink') : t('login.inviteLink')}
		</a>
	</div>
</AuthShell>
