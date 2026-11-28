<script lang="ts">
	import { untrack } from 'svelte';
	import { api, type Project } from '#lib/api.js';
	import { can, roleOf } from '#lib/access.js';
	import { t } from '#lib/i18n/index.js';
	import { githubErrorText, repositoryChoices, type GitHubAssignment, type GitHubOverview, type GitHubRepository } from '#lib/github.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';

	/**
	 * Which repository the project's pull requests go to (card E51E8B8C): everybody with access sees the mappings, a person with
	 * `manage` maps a repository of their own GitHub connection or removes a mapping. The server checks every right again.
	 */
	let { project }: { project: Project } = $props();
	const canManage = $derived(can(roleOf(project), 'editProject'));
	const projectID = $derived(project.id);

	let status = $state<'loading' | 'failed' | 'ready'>('loading');
	let assigned = $state<GitHubAssignment[]>([]);
	let overview = $state<GitHubOverview>({ available: false, connections: [] });
	let connectionID = $state('');
	let repositories = $state<GitHubRepository[] | null>(null);
	let truncated = $state(false);
	let repository = $state('');
	let busy = $state(false);
	let error = $state('');
	let message = $state('');
	const choices = $derived(repositoryChoices(repositories ?? [], assigned));
	/** Nothing to show: the server has no GitHub app and the project no repository. */
	const hidden = $derived(status === 'ready' && !overview.available && assigned.length === 0);

	async function load(id: string) {
		status = 'loading';
		try {
			[assigned, overview] = await Promise.all([api.githubAssignments(id).then((r) => r.items), api.githubOverview()]);
			status = 'ready';
			if (canManage && overview.connections.length === 1) await choose(overview.connections[0].id);
		} catch {
			status = 'failed';
		}
	}
	$effect(() => {
		const id = projectID;
		untrack(() => void load(id));
	});

	/** Only the answer for the connection chosen last counts. */
	async function choose(id: string) {
		connectionID = id;
		repository = '';
		repositories = null;
		truncated = false;
		error = '';
		if (!id) return;
		try {
			const list = await api.githubRepositories(id);
			if (connectionID !== id) return;
			if (list.ok) {
				repositories = list.items;
				truncated = list.truncated === true;
			} else {
				repositories = [];
				error = githubErrorText(list.code ?? 'generic');
			}
		} catch (e) {
			if (connectionID !== id) return;
			repositories = [];
			error = githubErrorText(e);
		}
	}
	async function assign() {
		if (busy || !connectionID || !repository) return;
		busy = true;
		error = '';
		message = '';
		try {
			const made = await api.assignGitHubRepository(projectID, connectionID, repository);
			assigned = [...assigned, made];
			repository = '';
			message = t('github.repos.assigned');
		} catch (e) {
			error = githubErrorText(e);
		} finally {
			busy = false;
		}
	}
	async function unassign(a: GitHubAssignment) {
		if (busy || !a.id) return;
		busy = true;
		error = '';
		message = '';
		try {
			await api.unassignGitHubRepository(projectID, a.id);
			assigned = assigned.filter((x) => x.id !== a.id);
			message = t('github.repos.removed');
		} catch (e) {
			error = githubErrorText(e);
		} finally {
			busy = false;
		}
	}
	const who = (a: GitHubAssignment) =>
		a.source === 'operator' ? t('github.repos.operator') : a.mine ? t('github.repos.byYou') : a.assignedBy ? t('github.repos.by', { name: a.assignedBy }) : t('github.repos.byUnknown');
</script>

{#if !hidden}
	<section class="flex min-w-0 flex-col gap-3 border-t pt-4" aria-labelledby="github-repos-title" data-testid="github-repos">
		<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase" id="github-repos-title">{t('github.repos.title')}</h3>
		{#if status === 'loading'}
			<p class="text-muted-foreground min-h-10 text-sm" role="status">{t('github.loading')}</p>
		{:else if status === 'failed'}
			<div class="flex flex-wrap items-center gap-2" role="alert">
				<span class="text-sm">{t('github.loadFailed')}</span>
				<Button size="sm" variant="outline" onclick={() => void load(projectID)}>{t('common.retry')}</Button>
			</div>
		{:else}
			<p class="text-muted-foreground text-xs">{t('github.repos.hint')}</p>
			{#if assigned.length === 0}
				<p class="text-muted-foreground text-sm" data-testid="github-repos-empty">{t('github.repos.empty')}</p>
			{:else}
				<ul class="flex flex-col divide-y rounded-xl border">
					{#each assigned as a (a.id ?? `operator:${a.repository}`)}
						<li class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2" data-testid="github-repo">
							<span class="flex min-w-0 flex-1 flex-col">
								<span class="font-mono text-sm [overflow-wrap:anywhere]" data-testid="github-repo-name">{a.repository}</span>
								<span class="text-muted-foreground text-xs" data-testid="github-repo-by">{who(a)}</span>
							</span>
							{#if canManage && a.id}
								<Button size="sm" variant="ghost" class="text-destructive aria-disabled:opacity-60" aria-disabled={busy} aria-label={t('github.repos.remove.label', { repository: a.repository })} data-testid="github-repo-remove" onclick={() => void unassign(a)}>{t('github.repos.remove')}</Button>
							{/if}
							{#if !a.active}
								<p class="text-warning flex w-full items-start gap-1.5 text-xs font-medium" data-testid="github-repo-inactive"><TriangleAlert class="mt-0.5 size-3.5 shrink-0" aria-hidden="true" />{t('github.repos.inactive')}</p>
							{/if}
						</li>
					{/each}
				</ul>
			{/if}

			{#if canManage && overview.available}
				{#if overview.connections.length === 0}
					<p class="text-sm" data-testid="github-repos-connect-first">
						{t('github.repos.connectFirst')} <a class="font-medium underline underline-offset-2" href="/settings/github">{t('github.repos.settingsLink')}</a>
					</p>
				{:else}
					<form class="grid min-w-0 gap-3 sm:grid-cols-2" data-testid="github-repos-form" onsubmit={(e) => { e.preventDefault(); void assign(); }}>
						<div class="flex min-w-0 flex-col gap-1">
							<label class="text-sm font-medium" for="github-connection">{t('github.repos.connection')}</label>
							<Select id="github-connection" value={connectionID} onchange={(e) => void choose((e.currentTarget as HTMLSelectElement).value)}>
								<option value="">{t('github.repos.connection.choose')}</option>
								{#each overview.connections as c (c.id)}<option value={c.id}>{c.accountLogin}</option>{/each}
							</Select>
						</div>
						<div class="flex min-w-0 flex-col gap-1">
							<label class="text-sm font-medium" for="github-repository">{t('github.repos.repository')}</label>
							<Select id="github-repository" disabled={!connectionID || repositories === null || choices.length === 0} bind:value={repository}>
								<option value="">{connectionID && repositories === null ? t('github.repos.repository.loading') : t('github.repos.repository.choose')}</option>
								{#each choices as c (c.repository)}
									<option value={c.repository} disabled={c.disabled}>{c.disabled ? t('github.repos.public', { repository: c.repository }) : c.repository}</option>
								{/each}
							</Select>
						</div>
						{#if connectionID && repositories !== null && choices.length === 0 && !error}
							<p class="text-muted-foreground text-xs sm:col-span-2">{t('github.repos.repository.none')}</p>
						{/if}
						{#if truncated}<p class="text-muted-foreground text-xs sm:col-span-2">{t('github.repos.truncated')}</p>{/if}
						<div class="sm:col-span-2">
							<Button type="submit" variant="outline" class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={busy || !repository} data-testid="github-repo-assign">{t('github.repos.assign')}</Button>
						</div>
					</form>
				{/if}
			{/if}
		{/if}
		<p role="alert" class="text-destructive text-sm font-medium [overflow-wrap:anywhere] empty:hidden" data-testid="github-repos-error">{error}</p>
		<p role="status" aria-live="polite" class="text-success text-sm font-medium empty:hidden">{message}</p>
	</section>
{/if}
