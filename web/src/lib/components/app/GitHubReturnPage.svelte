<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { api } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { finishReturn, githubErrorText, parseGitHubReturn, type GitHubReturn } from '#lib/github.js';
	import { t } from '#lib/i18n/index.js';
	import AuthShell from './AuthShell.svelte';

	/** `/github/setup` and `/github/callback`: the way back from GitHub (card E51E8B8C). The signed-in person finishes the connection. */
	let phase = $state<'working' | 'done' | 'denied' | 'requested' | 'updated' | 'missing' | 'signIn' | 'error'>('working');
	let error = $state('');
	let pending = $state<GitHubReturn | null>(null);

	onMount(() => {
		const parsed = parseGitHubReturn(location.search);
		// Code and state leave the address bar (and the history) at once.
		history.replaceState(history.state, '', location.pathname);
		if (parsed.kind === 'setup' || parsed.kind === 'callback') pending = parsed;
		else phase = parsed.kind;
	});

	async function finish(r: Extract<GitHubReturn, { kind: 'setup' | 'callback' }>) {
		try {
			const result = await finishReturn(api, r);
			if ('redirect' in result) location.replace(result.redirect);
			else phase = 'done';
		} catch (e) {
			error = githubErrorText(e);
			phase = 'error';
		}
	}
	$effect(() => {
		if (!auth.ready || !pending) return;
		const r = pending;
		const signedIn = auth.user !== null;
		untrack(() => {
			pending = null;
			if (r.kind !== 'setup' && r.kind !== 'callback') return;
			if (signedIn) void finish(r);
			else phase = 'signIn';
		});
	});
</script>

<AuthShell title={t('github.return.title')} testid="github-return">
	<div aria-live="polite" data-testid="github-return-status" data-phase={phase}>
		{#if phase === 'working'}<p class="text-sm">{t('github.return.working')}</p>{/if}
		{#if phase === 'done'}<p role="status" class="text-sm">{t('github.return.done')}</p>{/if}
		{#if phase === 'denied'}<p class="text-sm">{t('github.return.denied')}</p>{/if}
		{#if phase === 'requested'}<p class="text-sm">{t('github.return.requested')}</p>{/if}
		{#if phase === 'updated'}<p class="text-sm">{t('github.return.updated')}</p>{/if}
		{#if phase === 'missing'}<p role="alert" class="text-destructive text-sm">{t('github.return.missing')}</p>{/if}
		{#if phase === 'signIn'}<p role="alert" class="text-sm">{t('github.return.signIn')}</p>{/if}
		{#if phase === 'error'}<p role="alert" class="text-destructive text-sm">{error}</p>{/if}
	</div>
	{#if phase === 'signIn'}
		<a class="text-muted-foreground text-sm underline" href="/">{t('github.return.toApp')}</a>
	{:else if phase !== 'working'}
		<a class="text-muted-foreground text-sm underline" href="/settings/github">{t('github.return.toSettings')}</a>
	{/if}
</AuthShell>
