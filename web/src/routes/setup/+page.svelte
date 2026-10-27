<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { auth } from '#lib/auth.svelte.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import AuthShell from '#lib/components/app/AuthShell.svelte';
	import { Label } from '#lib/components/ui/label/index.js';

	let token = $state(page.url.searchParams.get('token') ?? '');
	let displayName = $state('');
	let passkeyName = $state('');
	let busy = $state(false);
	let error = $state<string | null>(null);

	async function submit(e: Event) {
		e.preventDefault();
		busy = true;
		error = null;
		try {
			await auth.registerWithPasskey(token.trim(), displayName.trim(), passkeyName.trim());
			await goto('/');
		} catch (err) {
			error = describeError(err);
		} finally {
			busy = false;
		}
	}
</script>

<AuthShell title={t('setup.title')}>
	<p class="text-muted-foreground text-sm">{t('setup.intro')}</p>

	<form class="flex flex-col gap-3" onsubmit={submit}>
		<Label for="token">{t('setup.token')}</Label>
		<Input id="token" autocomplete="off" required bind:value={token} />
		<Label for="displayName">{t('setup.displayName')}</Label>
		<Input id="displayName" autocomplete="name" required bind:value={displayName} />
		<Label for="passkeyName">{t('setup.passkeyName')}</Label>
		<Input id="passkeyName" bind:value={passkeyName} />
		<Button type="submit" size="lg" class="h-11" disabled={busy}>{t('setup.submit')}</Button>
	</form>

	{#if error}
		<p role="alert" class="text-destructive text-sm">{error}</p>
	{/if}

	<a class="text-muted-foreground text-sm underline" href="/">{t('setup.toLogin')}</a>
</AuthShell>
