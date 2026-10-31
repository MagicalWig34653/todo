<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/api.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { fragmentParam } from '#lib/notify.js';
	import AuthShell from '#lib/components/app/AuthShell.svelte';

	let phase = $state<'working' | 'done' | 'missing' | 'error'>('working');
	let error = $state<string | null>(null);

	onMount(async () => {
		// The token travels in the URL fragment, so it is not part of any server request log.
		const token = fragmentParam(location.hash, 'token');
		history.replaceState(null, '', location.pathname);
		if (!token) {
			phase = 'missing';
			return;
		}
		try {
			await api.confirmEmail(token);
			phase = 'done';
		} catch (e) {
			error = describeError(e);
			phase = 'error';
		}
	});
</script>

<AuthShell title={t('confirmEmail.title')} testid="confirm-email">
	<div aria-live="polite">
		{#if phase === 'working'}<p class="text-sm">{t('confirmEmail.working')}</p>{/if}
		{#if phase === 'done'}<p role="status" class="text-sm" data-testid="confirm-email-done">{t('confirmEmail.done')}</p>{/if}
		{#if phase === 'missing'}<p role="alert" class="text-destructive text-sm">{t('confirmEmail.missing')}</p>{/if}
		{#if phase === 'error'}<p role="alert" class="text-destructive text-sm" data-testid="confirm-email-error">{error}</p>{/if}
	</div>
	<a class="text-muted-foreground text-sm underline" href="/">{t('confirmEmail.toApp')}</a>
</AuthShell>
