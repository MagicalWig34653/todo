<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { api, ApiError, type Project } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { createLatest } from '#lib/serial.js';
	import {
		AUTO_DISABLE_FAILURES,
		MAX_EXCLUSIONS,
		deliveryRow,
		exclusionsChanged,
		orderedProjects,
		prefillExclusions,
		safeMask,
		secretInput,
		testOutcome,
		toggleExclusion,
		urlInput,
		webhookErrorKey,
		webhookStatus,
		type WebhookDelivery,
		type WebhookSettings
	} from '#lib/webhook.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import Timestamp from '../Timestamp.svelte';

	/**
	 * Settings page "Webhook" (ADR 0035): one outgoing wake-up call per person. The address is a secret: it is typed into a masked
	 * field, sent once, and never shown again; the page only knows the mask the API returns. Nothing typed is logged or echoed,
	 * error texts are fixed German sentences chosen by status and reason (lib/webhook.ts).
	 */
	type Section = 'url' | 'enabled' | 'signing' | 'exclusions' | 'remove' | 'test' | 'deliveries';

	const latest = createLatest();
	let loaded = $state(false);
	let loadError = $state<string | null>(null);
	let settings = $state<WebhookSettings | null>(null);
	let projects = $state<Project[]>([]);
	let deliveries = $state<WebhookDelivery[]>([]);
	let deliveriesFailed = $state(false);

	// Typed secrets live only here, only until the request went through.
	let urlValue = $state('');
	let signingValue = $state('');
	let selected = $state<Set<string>>(new Set());
	let withChildren = $state(false);
	let confirmingRemove = $state(false);
	let testResult = $state<{ ok: boolean; text: string } | null>(null);
	let busy = $state<Section | null>(null);
	let message = $state('');
	let error = $state<{ section: Section; text: string } | null>(null);
	let inFlight = false;

	let exclusionsHeading = $state<HTMLElement | null>(null);
	let removeConfirm = $state<HTMLElement | null>(null);
	let removeButton = $state<HTMLButtonElement | null>(null);

	const status = $derived(webhookStatus(settings));
	const configured = $derived(status !== 'none');
	const mask = $derived(safeMask(settings?.maskedURL));
	const rows = $derived(orderedProjects(projects));
	const changed = $derived(exclusionsChanged(settings?.excludedProjectIDs ?? [], selected));
	const url = $derived(urlInput(urlValue));
	const secret = $derived(secretInput(signingValue));
	const last = $derived(settings?.lastDelivery ? deliveryRow(settings.lastDelivery) : null);
	const countLabel = $derived(
		selected.size === 0 ? t('webhook.exclusions.countNone') : selected.size === 1 ? t('webhook.exclusions.countOne') : t('webhook.exclusions.count', { count: selected.size })
	);

	async function load() {
		const current = latest.begin();
		const [s, p, d] = await Promise.all([api.getWebhook(), api.listProjects(), api.listWebhookDeliveries().catch(() => null)]);
		if (!current()) return;
		settings = s;
		projects = p;
		deliveriesFailed = d === null;
		deliveries = d ?? [];
		selected = new Set(prefillExclusions(s.excludedProjectIDs, p));
	}
	async function init() {
		loadError = null;
		try {
			await load();
		} catch (e) {
			if (e instanceof ApiError && e.isUnauthorized) auth.user = null;
			loadError = describeError(e);
		} finally {
			loaded = true;
		}
	}
	onMount(() => {
		void init();
	});

	async function refreshDeliveries() {
		try {
			deliveries = await api.listWebhookDeliveries();
			deliveriesFailed = false;
		} catch {
			deliveriesFailed = true;
		}
	}
	async function refreshSettings() {
		settings = await api.getWebhook();
	}

	/** One request at a time; a failure shows the fixed German text of its section and nothing of what was typed. */
	async function act(section: Section, work: () => Promise<void>): Promise<boolean> {
		if (inFlight) return false;
		inFlight = true;
		busy = section;
		error = null;
		message = '';
		try {
			await work();
			return true;
		} catch (e) {
			if (e instanceof ApiError && e.isUnauthorized) auth.user = null;
			error = { section, text: t(webhookErrorKey(e)) };
			// A project that vanished: show the current lists so the next choice is made on what exists.
			if (e instanceof ApiError && e.status === 404) {
				await Promise.all([api.listProjects().then((p) => (projects = p)), refreshSettings()]).catch(() => undefined);
				selected = new Set(prefillExclusions([...selected], projects));
			}
			return false;
		} finally {
			inFlight = false;
			busy = null;
		}
	}

	async function saveURL(ev: SubmitEvent) {
		ev.preventDefault();
		const value = url;
		if (!value || busy) return;
		const ok = await act('url', async () => {
			settings = await api.updateWebhook({ url: value });
			urlValue = '';
			await refreshDeliveries();
			message = t('webhook.url.saved');
		});
		if (ok) {
			await tick();
			focusField('wh-url');
		}
	}
	async function setEnabled(want: boolean, input?: HTMLInputElement) {
		const ok = await act('enabled', async () => {
			settings = await api.updateWebhook({ enabled: want });
			message = t(want ? 'webhook.enabled.on' : 'webhook.enabled.off');
		});
		// The box shows what the server stores, also after a refusal.
		if (!ok && input) input.checked = !want;
	}
	async function saveSigning(ev: SubmitEvent) {
		ev.preventDefault();
		const value = secret;
		if (!value || busy) return;
		const ok = await act('signing', async () => {
			settings = await api.updateWebhook({ signingSecret: value });
			signingValue = '';
			message = t('webhook.signing.saved');
		});
		if (ok) {
			await tick();
			focusField('wh-signing');
		}
	}
	async function removeSigning() {
		const ok = await act('signing', async () => {
			settings = await api.updateWebhook({ signingSecret: null });
			message = t('webhook.signing.removed');
		});
		if (ok) {
			await tick();
			focusField('wh-signing');
		}
	}
	function toggle(id: string) {
		selected = toggleExclusion(selected, projects, id, withChildren);
	}
	async function saveExclusions(ev: SubmitEvent) {
		ev.preventDefault();
		if (busy || !changed) return;
		const ok = await act('exclusions', async () => {
			settings = await api.updateWebhook({ excludedProjectIDs: [...selected] });
			selected = new Set(prefillExclusions(settings.excludedProjectIDs, projects));
			message = t('webhook.exclusions.saved');
		});
		if (ok) {
			await tick();
			exclusionsHeading?.focus();
		}
	}
	async function askRemove() {
		confirmingRemove = true;
		message = '';
		error = null;
		await tick();
		removeConfirm?.focus();
	}
	async function cancelRemove() {
		confirmingRemove = false;
		await tick();
		removeButton?.focus();
	}
	async function remove() {
		const ok = await act('remove', async () => {
			await api.deleteWebhook();
			confirmingRemove = false;
			urlValue = '';
			signingValue = '';
			testResult = null;
			await load();
			message = t('webhook.remove.done');
		});
		if (ok) {
			await tick();
			focusField('wh-url');
		} else confirmingRemove = false;
	}
	async function sendTest() {
		testResult = null;
		await act('test', async () => {
			const result = await api.testWebhook();
			testResult = testOutcome(result);
			await Promise.all([refreshDeliveries(), refreshSettings()]);
		});
	}
	async function refresh() {
		await act('deliveries', async () => {
			await Promise.all([refreshDeliveries(), refreshSettings()]);
		});
	}
	/** The text fields are plain inputs without a ref prop: focus by id. */
	function focusField(id: string) {
		document.getElementById(id)?.focus();
	}
	function onEscape(ev: KeyboardEvent, action: () => void) {
		if (ev.key !== 'Escape') return;
		ev.stopPropagation();
		action();
	}

	const card = 'bg-card flex flex-col gap-3 rounded-xl border p-4 shadow-card sm:p-5';
	const heading = 'text-base font-semibold';
	const muted = 'text-muted-foreground text-sm';
	const noteClass = 'rounded-lg px-3 py-2 text-sm';
</script>

{#snippet notice(section: Section)}
	{#if error?.section === section}
		<p class="bg-destructive/10 text-destructive {noteClass}" role="alert" data-testid="wh-error">{error.text}</p>
	{/if}
{/snippet}

<div class="flex max-w-3xl flex-col gap-4" data-testid="webhook-page">
	<section class={card} data-testid="wh-intro">
		<p class="text-sm">{t('webhook.intro.what')}</p>
		<p class="text-sm">{t('webhook.intro.limits')}</p>
	</section>

	<div role="status" aria-live="polite" class={message ? 'bg-success-soft text-success {noteClass}' : 'sr-only'} data-testid="wh-message">{message}</div>

	{#if !loaded}
		<p class={muted} role="status">{t('common.loading')}</p>
	{:else if loadError}
		<div class={card} data-testid="wh-load-error">
			<p class="text-sm" role="alert">{t('webhook.loadFailed')} {loadError}</p>
			<div><Button size="sm" variant="outline" onclick={init}>{t('webhook.retry')}</Button></div>
		</div>
	{:else}
		<section class={card} aria-labelledby="wh-url-title" data-testid="wh-url-card">
			<div class="flex flex-wrap items-center gap-x-3 gap-y-1">
				<h3 id="wh-url-title" class={heading}>{t('webhook.url.title')}</h3>
				<Badge variant={status === 'active' ? 'success' : status === 'none' ? 'outline' : 'warning'} data-testid="wh-status" data-status={status}>{t(`webhook.status.${status}`)}</Badge>
			</div>

			{#if configured}
				<p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm" data-testid="wh-hinterlegt">
					<Badge variant="accent">{t('webhook.url.stored')}</Badge>
					{#if mask}<span class="font-mono break-all" data-testid="wh-masked">{mask}</span>{:else}<span>{t('webhook.url.storedNoMask')}</span>{/if}
				</p>
				{#if last}
					<p class="text-muted-foreground flex flex-wrap items-center gap-x-2 gap-y-1 text-xs" data-testid="wh-last">
						<span>{t('webhook.url.lastDelivery')}:</span>
						<Badge variant={last.tone}>{last.stateLabel}</Badge>
						<Timestamp value={settings?.lastDelivery?.createdAt} />
					</p>
				{/if}
				{#if status === 'auto_disabled'}
					<div class="bg-warning-soft text-warning flex flex-col gap-2 {noteClass}" role="status" data-testid="wh-auto-disabled">
						<p class="font-semibold">{t('webhook.autoDisabled.title')}</p>
						<p>{t('webhook.autoDisabled.text', { count: AUTO_DISABLE_FAILURES })}</p>
						<div>
							<Button size="sm" variant="outline" type="button" onclick={() => setEnabled(true)} disabled={!!busy} data-testid="wh-reenable">{t('webhook.autoDisabled.go')}</Button>
						</div>
					</div>
				{/if}
				<div class="flex flex-col gap-1">
					<label class="hover:bg-muted/50 has-[:focus-visible]:ring-ring/50 flex min-h-10 w-fit cursor-pointer items-center gap-2.5 rounded-md pr-2 text-sm has-[:focus-visible]:ring-2">
						<Checkbox checked={settings?.enabled ?? false} disabled={!!busy} aria-describedby="wh-enabled-hint" onchange={(e) => setEnabled(e.currentTarget.checked, e.currentTarget)} data-testid="wh-enabled" />
						<span>{t('webhook.enabled.label')}</span>
					</label>
					<p class="text-muted-foreground text-xs" id="wh-enabled-hint">{t('webhook.enabled.hint')}</p>
				</div>
				{@render notice('enabled')}
			{/if}

			<form class="flex flex-col gap-2" onsubmit={saveURL} data-testid="wh-url-form" novalidate autocomplete="off">
				<label class="text-sm font-medium" for="wh-url">{t('webhook.url.label')}</label>
				<Input
					id="wh-url"
					type="password"
					autocomplete="new-password"
					autocapitalize="off"
					spellcheck={false}
					inputmode="url"
					data-1p-ignore
					data-lpignore="true"
					data-bwignore
					data-form-type="other"
					aria-describedby="wh-url-hint"
					bind:value={urlValue}
					data-testid="wh-url-input"
				/>
				<p class="text-muted-foreground text-xs" id="wh-url-hint">{t('webhook.url.hint')}{#if configured}{' '}{t('webhook.url.hintReplace')}{/if}</p>
				{@render notice('url')}
				<div class="flex flex-wrap gap-2">
					<Button type="submit" disabled={!!busy || !url} data-testid="wh-url-save">{busy === 'url' ? t('webhook.url.saving') : configured ? t('webhook.url.replace') : t('webhook.url.save')}</Button>
					{#if configured && !confirmingRemove}
						<Button type="button" variant="destructive" bind:ref={removeButton} onclick={askRemove} disabled={!!busy} data-testid="wh-remove">{t('webhook.remove.button')}</Button>
					{/if}
				</div>
				{#if !configured}<p class={muted} data-testid="wh-needs-url">{t('webhook.exclusions.needsUrl')}</p>{/if}
			</form>

			{#if confirmingRemove}
				<div class="border-destructive/40 bg-destructive/5 focus-visible:ring-ring/50 flex flex-col gap-2 rounded-lg border p-3 text-sm outline-none focus-visible:ring-2" role="alertdialog" aria-labelledby="wh-remove-title" tabindex="-1" bind:this={removeConfirm} onkeydown={(e) => onEscape(e, cancelRemove)} data-testid="wh-remove-confirm">
					<p id="wh-remove-title" class="font-semibold">{t('webhook.remove.title')}</p>
					<p>{t('webhook.remove.text')}</p>
					<div class="flex flex-wrap gap-2">
						<Button size="sm" variant="ghost" type="button" onclick={cancelRemove} disabled={!!busy} data-testid="wh-remove-cancel">{t('common.cancel')}</Button>
						<Button size="sm" variant="destructive" type="button" onclick={remove} disabled={!!busy} data-testid="wh-remove-go">{t('webhook.remove.go')}</Button>
					</div>
				</div>
			{/if}
			{@render notice('remove')}
		</section>

		{#if configured}
			<section class={card} aria-labelledby="wh-signing-title" data-testid="wh-signing-card">
				<div class="flex flex-wrap items-center gap-x-3 gap-y-1">
					<h3 id="wh-signing-title" class={heading}>{t('webhook.signing.title')}</h3>
					<Badge variant={settings?.signingConfigured ? 'success' : 'outline'} data-testid="wh-signing-state">{settings?.signingConfigured ? t('webhook.signing.state.set') : t('webhook.signing.state.unset')}</Badge>
				</div>
				<p class="text-muted-foreground text-xs">{t('webhook.signing.hint')}</p>
				<form class="flex flex-col gap-2" onsubmit={saveSigning} novalidate autocomplete="off" data-testid="wh-signing-form">
					<label class="text-sm font-medium" for="wh-signing">{t('webhook.signing.label')}</label>
					<Input
						id="wh-signing"
						type="password"
						autocomplete="new-password"
						autocapitalize="off"
						spellcheck={false}
						data-1p-ignore
						data-lpignore="true"
						data-bwignore
						data-form-type="other"
						aria-describedby="wh-signing-hint"
						bind:value={signingValue}
						data-testid="wh-signing-input"
					/>
					<p class="text-muted-foreground text-xs" id="wh-signing-hint">{t('webhook.signing.fieldHint')}</p>
					{@render notice('signing')}
					<div class="flex flex-wrap gap-2">
						<Button type="submit" variant="outline" disabled={!!busy || !secret} data-testid="wh-signing-save">{settings?.signingConfigured ? t('webhook.signing.replace') : t('webhook.signing.set')}</Button>
						{#if settings?.signingConfigured}
							<Button type="button" variant="ghost" onclick={removeSigning} disabled={!!busy} data-testid="wh-signing-remove">{t('webhook.signing.remove')}</Button>
						{/if}
					</div>
				</form>
			</section>

			<section class={card} aria-labelledby="wh-exclusions-title" data-testid="wh-exclusions">
				<div>
					<h3 id="wh-exclusions-title" class="{heading} outline-none" tabindex="-1" bind:this={exclusionsHeading}>{t('webhook.exclusions.title')}</h3>
					<p class="text-muted-foreground mt-1 text-xs">{t('webhook.exclusions.hint')}</p>
				</div>
				<form class="flex flex-col gap-3" onsubmit={saveExclusions} novalidate>
					<div class="flex flex-col gap-1">
						<label class="hover:bg-muted/50 has-[:focus-visible]:ring-ring/50 flex min-h-10 w-fit cursor-pointer items-center gap-2.5 rounded-md pr-2 text-sm has-[:focus-visible]:ring-2">
							<Checkbox bind:checked={withChildren} aria-describedby="wh-children-hint" data-testid="wh-with-children" />
							<span>{t('webhook.exclusions.children')}</span>
						</label>
						<p class="text-muted-foreground text-xs" id="wh-children-hint">{t('webhook.exclusions.childrenHint')}</p>
					</div>
					<fieldset class="flex min-w-0 flex-col gap-1" disabled={!!busy}>
						<legend class="sr-only">{t('webhook.exclusions.list')}</legend>
						<ul class="flex max-h-72 flex-col overflow-auto rounded-lg border p-1" data-testid="wh-project-list">
							{#each rows as r (r.project.id)}
								<li data-testid="wh-project" data-depth={r.depth}>
									<label class="hover:bg-muted/50 has-[:focus-visible]:ring-ring/50 flex min-h-10 cursor-pointer items-center gap-2.5 rounded-md px-2 text-sm has-[:focus-visible]:ring-2" style:padding-inline-start="{0.5 + Math.min(r.depth, 6) * 1.25}rem">
										<Checkbox checked={selected.has(r.project.id)} aria-label={r.label} onchange={() => toggle(r.project.id)} />
										<span class="min-w-0 break-words">{r.project.name}</span>
									</label>
								</li>
							{:else}
								<li class="text-muted-foreground px-2 py-2 text-sm">{t('webhook.exclusions.none')}</li>
							{/each}
						</ul>
					</fieldset>
					<div class="flex flex-wrap items-center justify-between gap-2">
						<p class="text-muted-foreground text-xs" aria-live="polite" data-testid="wh-exclusions-count">{countLabel}</p>
						{#if selected.size > 0}
							<Button size="xs" variant="ghost" type="button" onclick={() => (selected = new Set())} disabled={!!busy} data-testid="wh-exclusions-clear">{t('webhook.exclusions.clear')}</Button>
						{/if}
					</div>
					{#if selected.size >= MAX_EXCLUSIONS}<p class={muted}>{t('webhook.exclusions.limit', { max: MAX_EXCLUSIONS })}</p>{/if}
					{@render notice('exclusions')}
					<div>
						<Button type="submit" disabled={!!busy || !changed} data-testid="wh-exclusions-save">{t('webhook.exclusions.save')}</Button>
					</div>
				</form>
			</section>

			<section class={card} aria-labelledby="wh-test-title" data-testid="wh-test-card">
				<div>
					<h3 id="wh-test-title" class={heading}>{t('webhook.test.title')}</h3>
					<p class="text-muted-foreground mt-1 text-xs">{t('webhook.test.hint')}</p>
				</div>
				<div>
					<Button variant="outline" onclick={sendTest} disabled={!!busy} data-testid="wh-test">{busy === 'test' ? t('webhook.test.sending') : t('webhook.test.button')}</Button>
				</div>
				<div role="status" aria-live="polite" class={testResult ? (testResult.ok ? 'bg-success-soft text-success' : 'bg-destructive/10 text-destructive') + ' ' + noteClass : 'sr-only'} data-testid="wh-test-result">{testResult?.text ?? ''}</div>
				{@render notice('test')}
			</section>
		{/if}

		<section class={card} aria-labelledby="wh-deliveries-title" data-testid="wh-deliveries">
			<div class="flex flex-wrap items-start justify-between gap-2">
				<div class="min-w-0">
					<h3 id="wh-deliveries-title" class={heading}>{t('webhook.deliveries.title')}</h3>
					<p class="text-muted-foreground mt-1 text-xs">{t('webhook.deliveries.hint')}</p>
				</div>
				<Button size="sm" variant="outline" type="button" onclick={refresh} disabled={!!busy} data-testid="wh-refresh">{busy === 'deliveries' ? t('webhook.deliveries.refreshing') : t('webhook.deliveries.refresh')}</Button>
			</div>
			{#if deliveriesFailed}
				<p class="bg-destructive/10 text-destructive {noteClass}" role="alert" data-testid="wh-deliveries-failed">{t('webhook.deliveries.failed')}</p>
			{/if}
			{@render notice('deliveries')}
			{#if deliveries.length === 0}
				<div class="text-muted-foreground flex flex-col items-center gap-1 rounded-xl border border-dashed px-4 py-8 text-center text-sm" data-testid="wh-deliveries-empty">
					<p class="text-foreground font-medium">{t('webhook.deliveries.empty')}</p>
					<p>{t('webhook.deliveries.emptyText')}</p>
				</div>
			{:else}
				<ul class="flex flex-col gap-2">
					{#each deliveries as d (d.id)}
						{@const row = deliveryRow(d)}
						<li class="flex flex-col gap-1.5 rounded-lg border p-3 text-sm" data-testid="wh-delivery" data-state={row.state}>
							<div class="flex flex-wrap items-center gap-x-2 gap-y-1">
								<Badge variant={row.tone} data-testid="wh-delivery-state">{row.stateLabel}</Badge>
								<strong class="min-w-0 break-words">{row.eventLabel}</strong>
								<span class="text-muted-foreground text-xs"><Timestamp value={d.createdAt} /></span>
							</div>
							<p class="text-muted-foreground flex flex-wrap gap-x-3 gap-y-0.5 text-xs">
								<span data-testid="wh-delivery-attempts">{row.attemptsLabel}</span>
								{#if row.countLabel}<span data-testid="wh-delivery-count">{row.countLabel}</span>{/if}
								{#if d.state === 'pending' && d.nextAttemptAt}<span>{t('webhook.deliveries.nextAttempt')}: <Timestamp value={d.nextAttemptAt} /></span>{/if}
							</p>
							{#if row.kindLabels.length}
								<ul class="flex flex-wrap gap-1" aria-label={t('webhook.deliveries.kinds')} data-testid="wh-delivery-kinds">
									{#each row.kindLabels as k (k)}<li><Badge variant="outline">{k}</Badge></li>{/each}
								</ul>
							{/if}
							{#if row.resultLabel}
								<p class="text-xs break-words {row.tone === 'destructive' ? 'text-destructive' : 'text-muted-foreground'}" data-testid="wh-delivery-result">{row.resultLabel}{#if row.code} <span class="font-mono">({row.code})</span>{/if}</p>
							{/if}
						</li>
					{/each}
				</ul>
			{/if}
		</section>
	{/if}
</div>
