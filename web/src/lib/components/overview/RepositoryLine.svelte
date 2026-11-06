<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { repositoryLink } from '#lib/syncState.js';

	/** Repository bound to one project (GET /v1/projects/{id}/sync, ADR 0018): name, link for normalized remotes, empty and error state. */
	let { projectID }: { projectID: string } = $props();

	let phase = $state<'loading' | 'ready' | 'error'>('loading');
	let repository = $state<string | null>(null);

	$effect(() => {
		const id = projectID;
		phase = 'loading';
		let current = true;
		api.getProjectSync(id).then(
			(s) => {
				if (!current) return;
				repository = s.bound ? (s.repository ?? null) : null;
				phase = 'ready';
			},
			() => {
				if (current) phase = 'error';
			}
		);
		return () => (current = false);
	});

	const link = $derived(repositoryLink(repository));
</script>

<p class="text-xs" data-testid="repo-line" aria-live="polite">
	{#if phase === 'loading'}
		<span class="text-muted-foreground">{t('sync.loading')}</span>
	{:else if phase === 'error'}
		<span class="text-destructive" role="alert" data-testid="repo-error">{t('sync.repoError')}</span>
	{:else if !repository}
		<span class="text-muted-foreground" data-testid="repo-none">{t('sync.repoNone')}</span>
	{:else}
		<span class="text-muted-foreground">{t('sync.repository')}:</span>
		{#if link}
			<a
				class="text-ui-accent-ink inline-flex min-h-9 items-center break-all underline underline-offset-2"
				href={link}
				target="_blank"
				rel="noopener noreferrer"
				aria-label="{t('sync.repoOpen')}: {repository}"
				data-testid="repo-name">{repository}</a
			>
		{:else}
			<code class="break-all" data-testid="repo-name">{repository}</code>
		{/if}
	{/if}
</p>
