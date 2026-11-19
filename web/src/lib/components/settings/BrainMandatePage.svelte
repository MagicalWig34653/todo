<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { api, ApiError, type OAuthGrant, type Project } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import {
		MAX_PROJECTS,
		auditCardParam,
		auditKindKey,
		diffMandate,
		eligibleGrants,
		filterProjects,
		mandateErrorKey,
		mandateStatus,
		prefillForm,
		projectLabels,
		resolveScope,
		saveKind,
		selectionProblem,
		toggleProject,
		type BrainAuditItem,
		type BrainMandate
	} from '#lib/brainMandate.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { connectionName } from '#lib/oauth.js';
	import { formatWhen } from '#lib/planning.js';
	import { createLatest } from '#lib/serial.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	/** Settings page "Brain-Vollmacht" (ADR 0032): one connection of the person may decide reviews and questions on their behalf. */
	let { onopen }: { onopen: (id: string) => void } = $props();

	const AUDIT_PREVIEW = 5;
	const latest = createLatest();

	let loaded = $state(false);
	let loadError = $state<string | null>(null);
	let mandate = $state<BrainMandate | null>(null);
	let grants = $state<OAuthGrant[]>([]);
	let projects = $state<Project[]>([]);
	let audit = $state<BrainAuditItem[]>([]);

	// Form: nothing is preselected unless an active mandate exists (then it is the starting point of the change).
	let grantID = $state('');
	let selected = $state<Set<string>>(new Set());
	let query = $state('');
	let confirming = $state(false);
	let revokeAsk = $state(false);
	let showAllAudit = $state(false);
	let busy = $state(false);
	let message = $state('');
	let error = $state<string | null>(null);
	let inFlight = false;

	let currentHeading = $state<HTMLElement | null>(null);
	let saveButton = $state<HTMLButtonElement | null>(null);
	let confirmBox = $state<HTMLElement | null>(null);
	let revokeButton = $state<HTMLButtonElement | null>(null);
	let revokeBox = $state<HTMLElement | null>(null);

	const labels = $derived(projectLabels(projects));
	const eligible = $derived(eligibleGrants(grants));
	const status = $derived(mandate ? mandateStatus(mandate) : null);
	const scope = $derived(mandate ? resolveScope(mandate.projectIDs, projects) : []);
	const holderID = $derived(status === 'active' && mandate ? mandate.grantID.toLowerCase() : '');
	const visibleProjects = $derived(filterProjects(projects, query));
	const next = $derived({ grantID, projectIDs: [...selected] });
	const problem = $derived(selectionProblem(grantID, selected));
	const kind = $derived(problem ? null : saveKind(mandate, next));
	const diff = $derived(kind === 'replace' && mandate ? diffMandate(mandate, next, projects) : null);
	const chosenName = $derived(nameOfGrant(grantID));
	const shownAudit = $derived(showAllAudit ? audit : audit.slice(0, AUDIT_PREVIEW));

	function nameOfGrant(id: string | null | undefined, fallback?: string | null): string {
		const g = id ? grants.find((x) => x.id.toLowerCase() === id.toLowerCase()) : undefined;
		return g ? connectionName(g) : fallback?.trim() || t('brainMandate.unknownConnection');
	}
	const currentName = $derived(mandate ? nameOfGrant(mandate.grantID, mandate.grantName) : '');
	function projectName(id: string): string {
		return labels.get(id.toLowerCase()) ?? t('brainMandate.project.inaccessible', { id: id.slice(0, 8).toLowerCase() });
	}
	const listOf = (ids: string[]) => ids.map((id) => projectName(id)).join(', ');
	const lastUsed = (g: OAuthGrant) => (g.last_used_at ? t('brainMandate.form.lastUsed', { when: formatWhen(g.last_used_at) }) : t('brainMandate.form.neverUsed'));

	function resetForm() {
		const start = prefillForm(mandate, grants, projects);
		grantID = start.grantID;
		selected = new Set(start.projectIDs);
		query = '';
		confirming = false;
	}
	/** After a reload that changed lists (a connection or project vanished): keep the person's choices where they still exist. */
	function sanitizeForm() {
		const ids = new Set(projects.map((p) => p.id));
		selected = new Set([...selected].filter((id) => ids.has(id)));
		if (!eligible.some((g) => g.id === grantID)) grantID = '';
		confirming = false;
	}
	async function load(keepForm = false) {
		const current = latest.begin();
		const [m, g, p, a] = await Promise.all([api.getBrainMandate(), api.listOAuthGrants(), api.listProjects(), api.listBrainAudit()]);
		if (!current()) return;
		mandate = m;
		grants = g;
		projects = p;
		audit = a;
		if (keepForm) sanitizeForm();
		else resetForm();
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

	async function failure(e: unknown) {
		confirming = false;
		if (e instanceof ApiError && e.isUnauthorized) {
			error = t('brainMandate.error.session');
			auth.user = null;
			return;
		}
		const key = mandateErrorKey(e);
		error = key ? t(key) : describeError(e);
		// A vanished connection or project: show the current lists so the next choice is made on what exists.
		if (e instanceof ApiError && (e.status === 404 || e.status === 409)) await load(true).catch(() => undefined);
	}

	function toggle(id: string) {
		selected = toggleProject(selected, id);
	}
	async function submit(e: SubmitEvent) {
		e.preventDefault();
		if (busy || !kind) return;
		message = '';
		error = null;
		if (kind === 'replace' && !confirming) {
			confirming = true;
			await tick();
			confirmBox?.focus();
			return;
		}
		await save();
	}
	async function cancelConfirm() {
		confirming = false;
		await tick();
		saveButton?.focus();
	}
	async function save() {
		const k = kind;
		if (inFlight || !k || k === 'unchanged') return;
		inFlight = true;
		busy = true;
		error = null;
		message = '';
		try {
			const saved = await api.putBrainMandate(grantID, [...selected]);
			mandate = saved;
			const name = nameOfGrant(saved.grantID, saved.grantName);
			message = t(k === 'replace' ? 'brainMandate.form.savedChange' : 'brainMandate.form.saved', { name });
			revokeAsk = false;
			await Promise.all([api.listOAuthGrants().then((g) => (grants = g)), api.listBrainAudit().then((a) => (audit = a))]).catch(() => undefined);
			resetForm();
			await tick();
			currentHeading?.focus();
		} catch (e) {
			await failure(e);
		} finally {
			inFlight = false;
			busy = false;
		}
	}
	async function askRevoke() {
		revokeAsk = true;
		message = '';
		error = null;
		await tick();
		revokeBox?.focus();
	}
	async function cancelRevoke() {
		revokeAsk = false;
		await tick();
		revokeButton?.focus();
	}
	async function revoke() {
		if (inFlight) return;
		inFlight = true;
		busy = true;
		error = null;
		try {
			await api.revokeBrainMandate();
			revokeAsk = false;
			mandate = (await api.getBrainMandate()) ?? null;
			message = t('brainMandate.revoke.done');
			resetForm();
			await tick();
			currentHeading?.focus();
		} catch (e) {
			revokeAsk = false;
			await failure(e);
		} finally {
			inFlight = false;
			busy = false;
		}
	}
	function openCard(ev: MouseEvent, taskID: string) {
		if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.button !== 0) return;
		ev.preventDefault();
		cardDetail.open({ type: 'task', id: taskID });
	}
	function onEscape(ev: KeyboardEvent, action: () => void) {
		if (ev.key !== 'Escape') return;
		ev.stopPropagation();
		action();
	}

	const card = 'bg-card flex flex-col gap-3 rounded-xl border p-4 shadow-card sm:p-5';
	const heading = 'text-base font-semibold';
	const muted = 'text-muted-foreground text-sm';
</script>

<div class="flex max-w-3xl flex-col gap-4" data-testid="brain-mandate">
	<section class={card} data-testid="bm-intro">
		<p class="text-sm">{t('brainMandate.intro.allows', { name: auth.user?.displayName ?? '…' })}</p>
		<p class="text-sm">{t('brainMandate.intro.limits')}</p>
	</section>

	<div role="status" aria-live="polite" class={message ? 'bg-success-soft text-success rounded-lg px-3 py-2 text-sm' : 'sr-only'} data-testid="bm-message">{message}</div>
	{#if error}
		<p class="bg-destructive/10 text-destructive rounded-lg px-3 py-2 text-sm" role="alert" data-testid="bm-error">{error}</p>
	{/if}

	{#if !loaded}
		<p class={muted} role="status">{t('common.loading')}</p>
	{:else if loadError}
		<div class={card} data-testid="bm-load-error">
			<p class="text-sm" role="alert">{t('brainMandate.loadFailed')} {loadError}</p>
			<div><Button size="sm" variant="outline" onclick={init}>{t('brainMandate.retry')}</Button></div>
		</div>
	{:else}
		<section class={card} aria-labelledby="bm-current-title" data-testid="bm-current" data-status={status ?? 'none'}>
			<h3 id="bm-current-title" class={heading} tabindex="-1" bind:this={currentHeading} data-testid="bm-current-title">{t('brainMandate.current.title')}</h3>
			{#if !mandate || status === 'revoked'}
				<div class="text-muted-foreground flex flex-col items-center gap-1 rounded-xl border border-dashed px-4 py-8 text-center text-sm" data-testid="bm-empty">
					<p class="text-foreground font-medium">{t('brainMandate.current.empty.title')}</p>
					<p>{t('brainMandate.current.empty.text')}</p>
					{#if mandate?.revokedAt}
						<p data-testid="bm-was-revoked">{t('brainMandate.current.wasRevoked', { name: currentName, when: formatWhen(mandate.revokedAt) })}</p>
					{/if}
				</div>
			{:else}
				{#if status === 'grant_revoked'}
					<p class="bg-warning-soft text-warning rounded-lg px-3 py-2 text-sm" data-testid="bm-void">{t('brainMandate.status.grantRevoked.text', { name: currentName })}</p>
				{/if}
				<dl class="grid grid-cols-1 gap-x-4 gap-y-2.5 text-sm sm:grid-cols-[11rem_minmax(0,1fr)]">
					<dt class="text-muted-foreground">{t('brainMandate.current.connection')}</dt>
					<dd class="font-medium break-words" data-testid="bm-grant-name">{currentName}</dd>
					<dt class="text-muted-foreground">{t('brainMandate.current.status')}</dt>
					<dd>
						<Badge variant={status === 'active' ? 'success' : 'warning'} data-testid="bm-status">{status === 'active' ? t('brainMandate.status.active') : t('brainMandate.status.grantRevoked')}</Badge>
					</dd>
					<dt class="text-muted-foreground">{t('brainMandate.current.projects')}</dt>
					<dd>
						<ul class="flex flex-col gap-1" data-testid="bm-scope">
							{#each scope as p (p.id)}
								<li class={p.accessible ? '' : 'text-muted-foreground italic'} data-accessible={p.accessible} data-testid="bm-scope-project">
									{p.accessible ? p.label : t('brainMandate.project.inaccessible', { id: p.label })}
								</li>
							{/each}
						</ul>
						<p class="text-muted-foreground mt-1 text-xs">{t('brainMandate.current.noInherit')}</p>
					</dd>
					<dt class="text-muted-foreground">{t('brainMandate.current.granted')}</dt>
					<dd data-testid="bm-granted">{formatWhen(mandate.createdAt)}</dd>
					{#if mandate.updatedAt !== mandate.createdAt}
						<dt class="text-muted-foreground">{t('brainMandate.current.updated')}</dt>
						<dd data-testid="bm-updated">{formatWhen(mandate.updatedAt)}</dd>
					{/if}
					<dt class="text-muted-foreground">{t('brainMandate.current.lastUsed')}</dt>
					<dd data-testid="bm-used">{mandate.lastUsedAt ? formatWhen(mandate.lastUsedAt) : t('brainMandate.current.neverUsed')}</dd>
				</dl>
				{#if revokeAsk}
					<div class="border-destructive/40 bg-destructive/5 flex flex-col gap-2 rounded-lg border p-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring/50" role="alertdialog" aria-labelledby="bm-revoke-title" tabindex="-1" bind:this={revokeBox} onkeydown={(e) => onEscape(e, cancelRevoke)} data-testid="bm-revoke-confirm">
						<p id="bm-revoke-title" class="font-semibold">{t('brainMandate.revoke.title')}</p>
						<p>{t('brainMandate.revoke.text')}</p>
						<div class="flex flex-wrap gap-2">
							<Button size="sm" variant="ghost" type="button" onclick={cancelRevoke} disabled={busy} data-testid="bm-revoke-cancel">{t('common.cancel')}</Button>
							<Button size="sm" variant="destructive" type="button" onclick={revoke} disabled={busy} data-testid="bm-revoke-go">{t('brainMandate.revoke.go')}</Button>
						</div>
					</div>
				{:else}
					<div>
						<Button size="sm" variant="destructive" type="button" bind:ref={revokeButton} onclick={askRevoke} disabled={busy} data-testid="bm-revoke">{t('brainMandate.revoke.button')}</Button>
					</div>
				{/if}
			{/if}
		</section>

		<section class={card} aria-labelledby="bm-form-title" data-testid="bm-form-card">
			<h3 id="bm-form-title" class={heading}>{status === 'active' ? t('brainMandate.form.titleChange') : t('brainMandate.form.titleGrant')}</h3>
			<form class="flex flex-col gap-4" onsubmit={submit} data-testid="bm-form" novalidate>
				<fieldset class="flex min-w-0 flex-col gap-2" disabled={busy || confirming}>
					<legend class="text-sm font-medium">{t('brainMandate.form.connection')}</legend>
					<p class="text-muted-foreground text-xs">{t('brainMandate.form.connectionHint')}</p>
					{#if eligible.length === 0}
						<p class="bg-muted/60 rounded-lg px-3 py-2 text-sm" data-testid="bm-no-grants">
							{t('brainMandate.form.connectionNone')}
							<a href="/settings/mcp" class="text-ui-accent-ink underline underline-offset-2" onclick={(e) => { e.preventDefault(); onopen('mcp'); }}>{t('brainMandate.form.connectionSetup')}</a>
						</p>
					{/if}
					<div class="flex flex-col gap-2" role="radiogroup" aria-label={t('brainMandate.form.connection')} data-testid="bm-grants">
						{#each eligible as g (g.id)}
							<label class="hover:bg-muted/50 has-[:checked]:border-ui-accent has-[:checked]:bg-ui-accent-soft has-[:focus-visible]:ring-ring/50 flex min-h-12 cursor-pointer items-start gap-3 rounded-lg border p-3 has-[:focus-visible]:ring-2" data-testid="bm-grant-option" data-grant-id={g.id}>
								<input type="radio" name="bm-grant" class="accent-ui-accent mt-0.5 size-[18px] shrink-0" value={g.id} checked={grantID === g.id} onchange={() => (grantID = g.id)} />
								<span class="flex min-w-0 flex-1 flex-col text-sm">
									<span class="font-medium break-words">{connectionName(g)}{#if g.id.toLowerCase() === holderID} <Badge variant="accent" class="ml-1 align-middle">{t('brainMandate.form.holder')}</Badge>{/if}</span>
									<span class="text-muted-foreground text-xs break-words">{#if g.client_name && g.client_name !== connectionName(g)}{g.client_name} · {/if}{lastUsed(g)}</span>
								</span>
							</label>
						{/each}
					</div>
				</fieldset>

				<fieldset class="flex min-w-0 flex-col gap-2" disabled={busy || confirming}>
					<legend class="text-sm font-medium">{t('brainMandate.form.projects')}</legend>
					<p class="text-muted-foreground text-xs">{t('brainMandate.form.projectsHint')}</p>
					<Input type="search" bind:value={query} placeholder={t('brainMandate.form.search')} aria-label={t('brainMandate.form.search')} data-testid="bm-project-search" />
					<ul class="flex max-h-64 flex-col overflow-auto rounded-lg border p-1" data-testid="bm-project-list">
						{#each visibleProjects as p (p.id)}
							<li>
								<label class="hover:bg-muted/50 flex min-h-10 cursor-pointer items-center gap-2.5 rounded-md px-2 text-sm">
									<Checkbox checked={selected.has(p.id)} disabled={!selected.has(p.id) && selected.size >= MAX_PROJECTS} onchange={() => toggle(p.id)} data-testid="bm-project" />
									<span class="min-w-0 break-words">{labels.get(p.id.toLowerCase()) ?? p.name}</span>
								</label>
							</li>
						{:else}
							<li class="text-muted-foreground px-2 py-2 text-sm">{projects.length === 0 ? t('brainMandate.form.noProjects') : t('brainMandate.form.noMatch')}</li>
						{/each}
					</ul>
					<div class="flex flex-wrap items-center justify-between gap-2">
						<p class="text-muted-foreground text-xs" aria-live="polite" data-testid="bm-selected-count">{t('brainMandate.form.count', { count: selected.size, max: MAX_PROJECTS })}</p>
						{#if selected.size > 0}
							<Button size="xs" variant="ghost" type="button" onclick={() => (selected = new Set())} data-testid="bm-clear">{t('brainMandate.form.clear')}</Button>
						{/if}
					</div>
				</fieldset>

				{#if confirming && diff && mandate}
					{@const connectionChanged = diff.grantChanged}
					<div class="border-warning/50 bg-warning-soft/60 flex flex-col gap-3 rounded-lg border p-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring/50" role="alertdialog" aria-labelledby="bm-confirm-title" tabindex="-1" bind:this={confirmBox} onkeydown={(e) => onEscape(e, cancelConfirm)} data-testid="bm-confirm">
						<h4 id="bm-confirm-title" class="font-semibold">{connectionChanged ? t('brainMandate.confirm.titleConnection') : t('brainMandate.confirm.titleScope')}</h4>
						<div class="grid gap-2 sm:grid-cols-2">
							<div class="bg-card rounded-lg border p-3" data-testid="bm-diff-before">
								<p class="text-muted-foreground text-xs font-semibold uppercase">{t('brainMandate.confirm.before')}</p>
								<p class="font-medium break-words">{t(mandate.projectIDs.length === 1 ? 'brainMandate.confirm.lineOne' : 'brainMandate.confirm.lineMany', { name: currentName, count: mandate.projectIDs.length })}</p>
								<p class="text-muted-foreground mt-1 text-xs break-words">{listOf(mandate.projectIDs)}</p>
							</div>
							<div class="bg-card rounded-lg border p-3" data-testid="bm-diff-after">
								<p class="text-muted-foreground text-xs font-semibold uppercase">{t('brainMandate.confirm.after')}</p>
								<p class="font-medium break-words">{t(selected.size === 1 ? 'brainMandate.confirm.lineOne' : 'brainMandate.confirm.lineMany', { name: chosenName, count: selected.size })}</p>
								<p class="text-muted-foreground mt-1 text-xs break-words">{listOf([...selected])}</p>
							</div>
						</div>
						<dl class="grid grid-cols-1 gap-x-3 gap-y-1 sm:grid-cols-[8rem_minmax(0,1fr)]">
							<dt class="text-success font-medium">{t('brainMandate.confirm.added')}</dt>
							<dd data-testid="bm-diff-added">{#if diff.added.length}{diff.added.map((p) => `+ ${p.accessible ? p.label : t('brainMandate.project.inaccessible', { id: p.label })}`).join(', ')}{:else}{t('brainMandate.confirm.nothing')}{/if}</dd>
							<dt class="text-destructive font-medium">{t('brainMandate.confirm.removed')}</dt>
							<dd data-testid="bm-diff-removed">{#if diff.removed.length}{diff.removed.map((p) => `− ${p.accessible ? p.label : t('brainMandate.project.inaccessible', { id: p.label })}`).join(', ')}{:else}{t('brainMandate.confirm.nothing')}{/if}</dd>
							<dt class="text-muted-foreground font-medium">{t('brainMandate.confirm.kept')}</dt>
							<dd data-testid="bm-diff-kept">{diff.kept.length ? diff.kept.map((p) => p.label).join(', ') : t('brainMandate.confirm.nothing')}</dd>
						</dl>
						{#if connectionChanged}
							<p class="font-medium" data-testid="bm-diff-warning">{t('brainMandate.confirm.lostConnection', { name: currentName })}</p>
						{:else if diff.removed.length}
							<p class="font-medium" data-testid="bm-diff-warning">{t('brainMandate.confirm.lostScope', { name: currentName })}</p>
						{/if}
						<div class="flex flex-wrap gap-2">
							<Button size="sm" variant="ghost" type="button" onclick={cancelConfirm} disabled={busy} data-testid="bm-confirm-cancel">{t('common.cancel')}</Button>
							<Button size="sm" type="button" onclick={save} disabled={busy} data-testid="bm-confirm-go">{busy ? t('brainMandate.form.saving') : connectionChanged ? t('brainMandate.confirm.goConnection') : t('brainMandate.confirm.goScope')}</Button>
						</div>
					</div>
				{:else}
					<div class="flex flex-col gap-2">
						{#if problem}
							<p class={muted} id="bm-hint" data-testid="bm-problem">
								{problem === 'grant_required' ? t('brainMandate.form.problem.grant') : problem === 'projects_required' ? t('brainMandate.form.problem.projects') : t('brainMandate.form.problem.tooMany', { max: MAX_PROJECTS })}
							</p>
						{:else if kind === 'unchanged'}
							<p class={muted} id="bm-hint" data-testid="bm-unchanged">{t('brainMandate.form.unchanged')}</p>
						{:else}
							<p class={muted} id="bm-hint" data-testid="bm-summary">
								{t(selected.size === 1 ? 'brainMandate.form.summaryOne' : 'brainMandate.form.summaryMany', { name: chosenName, count: selected.size, projects: listOf([...selected]) })}
							</p>
						{/if}
						<div>
							<Button type="submit" bind:ref={saveButton} disabled={busy || !!problem || kind === 'unchanged'} aria-describedby="bm-hint" data-testid="bm-save">
								{busy ? t('brainMandate.form.saving') : kind === 'replace' ? t('brainMandate.form.saveReview') : t('brainMandate.form.saveGrant')}
							</Button>
						</div>
					</div>
				{/if}
			</form>
		</section>

		{#if audit.length > 0 || mandate}
			<section class={card} aria-labelledby="bm-audit-title" data-testid="bm-audit">
				<div>
					<h3 id="bm-audit-title" class={heading}>{t('brainMandate.audit.title')}</h3>
					<p class="text-muted-foreground mt-1 text-xs">{t('brainMandate.audit.intro')}</p>
				</div>
				{#if audit.length === 0}
					<p class={muted} data-testid="bm-audit-empty">{t('brainMandate.audit.empty')}</p>
				{:else}
					<ul class="flex flex-col gap-2">
						{#each shownAudit as a (a.id)}
							{@const via = mandate && a.grantID.toLowerCase() !== mandate.grantID.toLowerCase() ? nameOfGrant(a.grantID) : null}
							<li class="flex flex-col gap-1 rounded-lg border p-3 text-sm" data-testid="bm-audit-item" data-kind={a.kind}>
								<div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
									<strong>{t(auditKindKey(a.kind))}</strong>
									<span class="text-muted-foreground text-xs">{formatWhen(a.createdAt)}</span>
									{#if via}<span class="text-muted-foreground text-xs">{t('brainMandate.audit.via', { name: via })}</span>{/if}
								</div>
								<p class="text-muted-foreground text-xs break-words">{projectName(a.projectID)}</p>
								<blockquote class="border-l-2 pl-2 break-words whitespace-pre-wrap" aria-label={t('brainMandate.audit.quote')}>{a.quote}</blockquote>
								{#if a.note}<p class="text-muted-foreground text-xs break-words whitespace-pre-wrap"><span class="font-medium">{t('brainMandate.audit.note')}:</span> {a.note}</p>{/if}
								<a class="text-ui-accent-ink w-fit text-xs underline underline-offset-2" href="?card={auditCardParam(a.taskID)}" aria-label={t('brainMandate.audit.cardLabel', { kind: t(auditKindKey(a.kind)), project: projectName(a.projectID) })} onclick={(ev) => openCard(ev, a.taskID)} data-testid="bm-audit-card">{t('brainMandate.audit.card')}</a>
							</li>
						{/each}
					</ul>
					{#if audit.length > AUDIT_PREVIEW}
						<div>
							<Button size="sm" variant="outline" type="button" onclick={() => (showAllAudit = !showAllAudit)} aria-expanded={showAllAudit} data-testid="bm-audit-more">
								{showAllAudit ? t('brainMandate.audit.less') : t('brainMandate.audit.more', { count: audit.length - AUDIT_PREVIEW })}
							</Button>
						</div>
					{/if}
				{/if}
			</section>
		{/if}
	{/if}
</div>
