<script lang="ts">
	import { api, type ProjectSync, type Role } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { describeError } from '#lib/errors.js';
	import { bindingError, bindingList, canAddBinding, canEditSync, repositoryLink } from '#lib/syncState.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import SyncChip from './SyncChip.svelte';
	import SyncDetail from './SyncDetail.svelte';

	/**
	 * Repository bindings of one project (GET /v1/projects/{id}/sync, ADR 0018): one row per binding with link and sync state,
	 * unbind (with confirmation) and add for editors, empty and error state. Also feeds the detail panel, so one request serves both.
	 */
	let { projectID, showDetails = false, onchanged }: { projectID: string; showDetails?: boolean; onchanged?: () => unknown } = $props();

	let phase = $state<'loading' | 'ready' | 'error'>('loading');
	let sync = $state<ProjectSync | null>(null);
	let role = $state<Role | null>(null);
	let confirming = $state<string | null>(null);
	let adding = $state(false);
	let draft = $state('');
	let formError = $state<string | null>(null);
	let status = $state('');

	// The prop is a getter that may re-evaluate (a refreshed project object) without a new value. Reading it through a
	// derived keeps the effect below from re-running, which would flip the line back to "loading" on every refresh.
	const stableID = $derived(projectID);

	$effect(() => {
		const id = stableID;
		phase = 'loading';
		sync = null;
		confirming = null;
		adding = false;
		status = '';
		let current = true;
		Promise.all([api.getProjectSync(id), api.visibility(id).catch(() => null)]).then(
			([s, v]) => {
				if (!current) return;
				sync = s;
				role = v?.role ?? null;
				phase = 'ready';
			},
			() => {
				if (current) phase = 'error';
			}
		);
		return () => (current = false);
	});

	const bindings = $derived(bindingList(sync));
	const editable = $derived(canEditSync(role));

	async function remove(repository: string) {
		formError = null;
		status = '';
		let known = false;
		const ok = await attempt(async () => {
			try {
				sync = await api.deleteProjectBinding(projectID, repository);
			} catch (e) {
				const key = bindingError(e);
				if (!key) throw e;
				known = true;
				formError = t(key);
			}
		});
		confirming = null;
		if (ok && !known) {
			status = t('sync.removed');
			await onchanged?.();
		}
	}

	async function add(e: Event) {
		e.preventDefault();
		formError = null;
		status = '';
		const repository = draft.trim();
		if (!repository) {
			formError = t('sync.addEmpty');
			return;
		}
		try {
			await api.putProjectSync(projectID, { repository });
			// A new binding answers with that binding only; reload the full overview.
			sync = await api.getProjectSync(projectID);
		} catch (err) {
			const key = bindingError(err);
			formError = key ? t(key) : describeError(err);
			return;
		}
		draft = '';
		adding = false;
		status = t('sync.added');
		await onchanged?.();
	}

	function cancelAdd() {
		adding = false;
		draft = '';
		formError = null;
	}
</script>

<div class="flex min-h-9 flex-col gap-2" data-testid="repo-line" aria-live="polite">
	{#if phase === 'loading'}
		<p class="text-muted-foreground text-xs">{t('sync.loading')}</p>
	{:else if phase === 'error'}
		<p class="text-destructive text-xs" role="alert" data-testid="repo-error">{t('sync.repoError')}</p>
	{:else}
		{#if bindings.length === 0}
			<p class="text-muted-foreground text-xs" data-testid="repo-none">{t('sync.repoNone')}</p>
		{:else}
			<ul class="flex flex-col gap-1.5" aria-label={t('sync.repositories')} data-testid="repo-list">
				{#each bindings as b (b.repository)}
					{@const repository = b.repository ?? ''}
					{@const link = repositoryLink(repository)}
					<li class="flex flex-col gap-1 text-xs" data-testid="repo-row">
						<div class="flex flex-wrap items-center gap-x-2 gap-y-1">
							<span class="text-muted-foreground">{t('sync.repository')}:</span>
							{#if link}
								<a
									class="text-ui-accent-ink inline-flex min-h-9 min-w-0 items-center break-all underline underline-offset-2"
									href={link}
									target="_blank"
									rel="noopener noreferrer"
									aria-label="{t('sync.repoOpen')}: {repository}"
									data-testid="repo-name">{repository}</a
								>
							{:else}
								<code class="min-w-0 break-all" data-testid="repo-name">{repository}</code>
							{/if}
							<SyncChip sync={b} />
							{#if editable && confirming !== repository}
								<Button
									type="button"
									size="sm"
									variant="ghost"
									aria-label={t('sync.removeAria', { repository })}
									data-testid="repo-remove"
									onclick={() => (confirming = repository)}>{t('sync.remove')}</Button
								>
							{/if}
						</div>
						{#if editable && confirming === repository}
							<div class="flex flex-col gap-1.5 rounded-lg border p-2" role="group" aria-label={t('sync.removeAria', { repository })} data-testid="repo-confirm">
								<p class="text-sm break-words">{t('sync.removeConfirm', { repository })}</p>
								<div class="flex gap-1">
									<Button type="button" size="sm" variant="destructive" data-testid="repo-remove-yes" onclick={() => remove(repository)}>{t('sync.removeYes')}</Button>
									<Button type="button" size="sm" variant="ghost" onclick={() => (confirming = null)}>{t('common.cancel')}</Button>
								</div>
							</div>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}

		{#if editable}
			{#if adding}
				<form class="flex flex-col gap-1" onsubmit={add} data-testid="repo-add-form">
					<label class="text-xs font-medium" for="repo-add-{projectID}">{t('sync.addLabel')}</label>
					<div class="flex flex-wrap items-center gap-2">
						<Input
							id="repo-add-{projectID}"
							class="min-w-0 flex-1"
							bind:value={draft}
							autocomplete="off"
							autocapitalize="none"
							spellcheck={false}
							aria-invalid={formError !== null}
							aria-describedby="repo-add-error-{projectID}"
							data-testid="repo-add-input"
						/>
						<Button type="submit" size="sm" data-testid="repo-add-submit">{t('sync.addSubmit')}</Button>
						<Button type="button" size="sm" variant="ghost" onclick={cancelAdd}>{t('common.cancel')}</Button>
					</div>
				</form>
			{:else if canAddBinding(bindings.length)}
				<div>
					<Button type="button" size="sm" variant="outline" data-testid="repo-add" onclick={() => (adding = true)}>{t('sync.add')}</Button>
				</div>
			{:else}
				<p class="text-muted-foreground text-xs">{t('sync.addLimit')}</p>
			{/if}
			<p id="repo-add-error-{projectID}" class="text-destructive text-xs" role={formError ? 'alert' : undefined} data-testid="repo-form-error">{formError ?? ''}</p>
		{/if}
		<p class="text-success text-xs empty:hidden" role="status" data-testid="repo-status">{status}</p>

		{#if showDetails}<SyncDetail {projectID} {sync} {role} onsync={(s) => (sync = s)} {onchanged} />{/if}
	{/if}
</div>
