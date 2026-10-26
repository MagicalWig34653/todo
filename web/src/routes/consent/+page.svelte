<script lang="ts">
	import { api, ApiError, type ConsentRequest } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { redirectTarget, safeRedirect, scopeLabel } from '#lib/oauth.js';
	import LoginView from '#lib/components/LoginView.svelte';
	import { Button } from '#lib/components/ui/button/index.js';

	let request = $state<ConsentRequest | null>(null);
	let selected = $state<Record<string, boolean>>({});
	let invalid = $state(false);
	let busy = $state(false);
	let error = $state<string | null>(null);
	let leaving = $state(false);
	let loadedFor: string | null = null;

	// Load once the user is signed in; the raw query string of the authorization request is passed through unchanged.
	$effect(() => {
		if (!auth.user || loadedFor === auth.user.id) return;
		loadedFor = auth.user.id;
		api.oauthAuthorize(location.search).then(
			(r) => (request = r),
			(e) => {
				if (e instanceof ApiError && e.isUnauthorized) {
					loadedFor = null;
					auth.user = null;
				} else invalid = true;
			}
		);
	});

	async function decide(approve: boolean) {
		if (!request) return;
		const ids = Object.keys(selected).filter((id) => selected[id]);
		if (approve && ids.length === 0) {
			error = t('consent.needProject');
			return;
		}
		busy = true;
		error = null;
		try {
			const { redirect_uri } = await api.oauthConsent(request.consent_token, approve, ids);
			const target = safeRedirect(redirect_uri);
			if (!target) {
				error = t('consent.badRedirect');
				return;
			}
			leaving = true;
			location.href = target;
		} catch (e) {
			error = describeError(e);
		} finally {
			busy = false;
		}
	}
</script>

{#if !auth.ready}
	<p class="text-muted-foreground p-6 text-sm">{t('common.loading')}</p>
{:else if !auth.user}
	<LoginView />
{:else}
	<main class="mx-auto flex max-w-xl flex-col gap-4 p-6">
		<h1 class="text-xl font-semibold" data-testid="consent-heading">{t('consent.title')}</h1>
		{#if invalid}
			<p role="alert" data-testid="consent-invalid">{t('consent.invalid')}</p>
		{:else if !request}
			<p class="text-muted-foreground text-sm">{t('common.loading')}</p>
		{:else}
			<p>{t('consent.intro', { client: request.client_name })}</p>
			<p class="text-muted-foreground text-sm" data-testid="consent-redirect">{t('consent.redirect', { target: redirectTarget(request.redirect_uri) })}</p>
			<div>
				<h2 class="text-sm font-medium">{t('consent.scopes')}</h2>
				<ul class="list-disc pl-5 text-sm">
					{#each request.scopes as s (s)}<li>{scopeLabel(s)}</li>{/each}
				</ul>
			</div>
			<fieldset class="flex flex-col gap-1">
				<legend class="text-sm font-medium">{t('consent.projects')}</legend>
				<p class="text-muted-foreground text-xs">{t('consent.projectsHint')}</p>
				{#if request.projects.length === 0}
					<p class="text-sm">{t('consent.noProjects')}</p>
				{/if}
				{#each request.projects as p (p.id)}
					<label class="flex min-h-9 items-center gap-2 text-sm">
						<input type="checkbox" bind:checked={selected[p.id]} />
						<span>{p.name}</span>
					</label>
				{/each}
			</fieldset>
			{#if error}<p role="alert" class="text-destructive text-sm" data-testid="consent-error">{error}</p>{/if}
			{#if leaving}<p class="text-sm" role="status">{t('consent.redirecting')}</p>{/if}
			<div class="flex gap-2">
				<Button size="lg" disabled={busy || leaving} onclick={() => decide(true)}>{t('consent.approve')}</Button>
				<Button size="lg" variant="outline" disabled={busy || leaving} onclick={() => decide(false)}>{t('consent.deny')}</Button>
			</div>
		{/if}
	</main>
{/if}
