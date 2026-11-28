<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { api } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { githubErrorText, safeGitHubURL, type GitHubConnectMode, type GitHubConnection, type GitHubOverview } from '#lib/github.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ExternalLink from '@lucide/svelte/icons/external-link';

	/**
	 * Settings page "GitHub" (card E51E8B8C): the person's own installations of the operator's GitHub App. Connecting sends the
	 * browser to GitHub and back (`/github/callback`). Removing forgets the connection and its project mappings in Todolino.
	 */
	let status = $state<'loading' | 'failed' | 'ready'>('loading');
	let overview = $state<GitHubOverview>({ available: false, connections: [] });
	let busy = $state<GitHubConnectMode | 'remove' | null>(null);
	let error = $state('');
	let message = $state('');
	let removing = $state<GitHubConnection | null>(null);
	let confirmEl = $state<HTMLElement | null>(null);

	async function load() {
		status = 'loading';
		try {
			overview = await api.githubOverview();
			status = 'ready';
		} catch {
			status = 'failed';
		}
	}
	onMount(() => {
		void load();
		// Coming back with the browser's back button from GitHub: the page may be restored with a pressed button.
		const restored = () => (busy = null);
		window.addEventListener('pageshow', restored);
		return () => window.removeEventListener('pageshow', restored);
	});

	async function connect(mode: GitHubConnectMode) {
		if (busy) return;
		busy = mode;
		error = '';
		message = '';
		try {
			const url = safeGitHubURL((await api.githubConnect(mode)).url);
			if (!url) throw 'github_address_invalid';
			location.assign(url);
		} catch (e) {
			error = githubErrorText(e);
			busy = null;
		}
	}
	async function askRemove(c: GitHubConnection) {
		removing = c;
		error = '';
		message = '';
		await tick();
		confirmEl?.querySelector<HTMLButtonElement>('button')?.focus();
	}
	async function remove() {
		if (!removing || busy) return;
		const id = removing.id;
		busy = 'remove';
		error = '';
		try {
			await api.removeGitHubConnection(id);
			overview = { ...overview, connections: overview.connections.filter((c) => c.id !== id) };
			removing = null;
			message = t('github.removed');
		} catch (e) {
			error = githubErrorText(e);
		} finally {
			busy = null;
		}
	}
</script>

<div class="flex min-w-0 flex-col gap-4" data-testid="github-page">
	<p class="text-muted-foreground text-sm">{t('github.intro')}</p>
	{#if status === 'loading'}
		<p class="text-muted-foreground min-h-16 text-sm" role="status">{t('github.loading')}</p>
	{:else if status === 'failed'}
		<div class="flex flex-wrap items-center gap-2" role="alert">
			<span>{t('github.loadFailed')}</span>
			<Button size="sm" variant="outline" onclick={() => void load()}>{t('common.retry')}</Button>
		</div>
	{:else}
		{#if !overview.available}
			<p class="bg-muted/60 rounded-xl border p-3 text-sm" data-testid="github-unavailable">{t('github.unavailable')}</p>
		{/if}
		{#if overview.connections.length === 0}
			{#if overview.available}
				<p class="text-muted-foreground rounded-xl border border-dashed p-4 text-center text-sm" data-testid="github-empty">{t('github.empty')}</p>
			{/if}
		{:else}
			<ul class="flex flex-col divide-y rounded-xl border" aria-label={t('github.list')}>
				{#each overview.connections as c (c.id)}
					<li class="flex min-w-0 flex-col gap-2 px-3 py-3" data-testid="github-connection">
						<div class="flex min-w-0 flex-wrap items-center gap-2">
							<span class="min-w-0 font-medium [overflow-wrap:anywhere]" data-testid="github-account">{c.accountLogin}</span>
							<Badge variant="outline">{t(`github.type.${c.accountType}` as MessageKey)}</Badge>
						</div>
						<p class="text-muted-foreground text-xs">{t('github.asLogin', { login: c.githubLogin })}</p>
						<div class="flex flex-wrap items-center gap-1.5">
							{#if safeGitHubURL(c.manageURL)}
								<a
									class="hover:bg-muted inline-flex min-h-9 items-center gap-1.5 rounded-lg border px-3 text-sm font-medium"
									href={safeGitHubURL(c.manageURL)}
									target="_blank"
									rel="noopener noreferrer"
									aria-label={t('github.manage.label', { account: c.accountLogin })}>{t('github.manage')}<ExternalLink class="size-3.5" aria-hidden="true" /></a>
							{/if}
							<Button size="sm" variant="ghost" class="text-destructive" aria-label={t('github.remove.label', { account: c.accountLogin })} data-testid="github-remove" onclick={() => void askRemove(c)}>{t('github.remove')}</Button>
						</div>
						{#if removing?.id === c.id}
							<div bind:this={confirmEl} class="border-destructive/40 flex min-w-0 flex-col gap-2 rounded-lg border p-3 text-sm" role="alertdialog" aria-label={t('github.remove')} data-testid="github-remove-confirm">
								<p class="[overflow-wrap:anywhere]">{t('github.remove.confirm', { account: c.accountLogin })}</p>
								<div class="flex flex-wrap gap-2">
									<Button size="sm" variant="destructive" class="aria-disabled:opacity-60" aria-disabled={busy === 'remove'} data-testid="github-remove-yes" onclick={() => void remove()}>{t('github.remove.yes')}</Button>
									<Button size="sm" variant="outline" onclick={() => (removing = null)}>{t('github.cancel')}</Button>
								</div>
							</div>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
		{#if overview.available}
			<div class="flex flex-wrap gap-2">
				<Button class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={busy !== null} data-testid="github-connect" onclick={() => void connect('install')}>{t('github.connect')}</Button>
				<Button variant="outline" class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={busy !== null} data-testid="github-connect-existing" onclick={() => void connect('existing')}>{t('github.connect.existing')}</Button>
			</div>
			<p class="text-muted-foreground text-xs">{t('github.connect.hint')} {t('github.connect.next')}</p>
		{/if}
	{/if}
	<p role="alert" class="text-destructive text-sm font-medium [overflow-wrap:anywhere] empty:hidden" data-testid="github-error">{error}</p>
	<p role="status" aria-live="polite" class="text-success text-sm font-medium empty:hidden">{message}</p>
</div>
