<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { api, ApiError, type OAuthGrant, type Project } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import {
		MAX_PROJECTS,
		auditCardParam,
		isGroupChange,
		auditKindKey,
		diffMandate,
		eligibleGrants,
		mandateErrorKey,
		mandateFor,
		mandateStatus,
		prefillProjects,
		projectLabels,
		resolveScope,
		type BrainAuditItem,
		type BrainMandate,
		isTakeover,
		takeoverWithoutProject,
		listedMandates
	} from '#lib/brainMandate.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { connectionName } from '#lib/oauth.js';
	import { formatWhen } from '#lib/planning.js';
	import { createLatest } from '#lib/serial.js';
	import {
		describeRule,
		emptySelection,
		namesSomething,
		pruneSelection,
		sameSelection,
		selectionFrom,
		type ProjectGroup,
		type Selection
	} from '#lib/projectGroups.js';
	import ProjectSelectionPicker from '../ProjectSelectionPicker.svelte';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Explainer from '../app/Explainer.svelte';

	/**
	 * Settings page "Brain-Vollmacht" (ADR 0032 and addendum): every connection of the person can hold its own mandate with its own
	 * project list; the list shows them all, each can be changed or revoked on its own.
	 */
	let { onopen }: { onopen: (id: string) => void } = $props();

	const AUDIT_PREVIEW = 5;
	const latest = createLatest();

	let loaded = $state(false);
	let loadError = $state<string | null>(null);
	let mandates = $state<BrainMandate[]>([]);
	let grants = $state<OAuthGrant[]>([]);
	let projects = $state<Project[]>([]);
	let audit = $state<BrainAuditItem[]>([]);

	// Form: nothing is preselected unless the chosen connection already holds an active mandate (then it is the starting point of the change).
	let grantID = $state('');
	let selection = $state<Selection>(emptySelection());
	/** What the chosen projects, groups and rules reach right now (computed by the server); null while unknown. */
	let effective = $state<string[] | null>(null);
	let groups = $state<ProjectGroup[]>([]);
	let confirming = $state(false);
	/** Connection whose revocation waits for confirmation. */
	let revokeFor = $state<string | null>(null);
	let showAllAudit = $state(false);
	let busy = $state(false);
	let message = $state('');
	let error = $state<string | null>(null);
	let inFlight = false;

	let listEl = $state<HTMLElement | null>(null);
	let formHeading = $state<HTMLElement | null>(null);
	let saveButton = $state<HTMLButtonElement | null>(null);
	let confirmBox = $state<HTMLElement | null>(null);

	const labels = $derived(projectLabels(projects));
	const eligible = $derived(eligibleGrants(grants));
	const activeIDs = $derived(new Set(mandates.filter((m) => mandateStatus(m) === 'active').map((m) => m.grantID.toLowerCase())));
	const chosenMandate = $derived(grantID ? mandateFor(mandates, grantID) : undefined);
	/** The stored choice of a mandate as form state: explicitly named projects the person can still read, plus its rule. */
	function storedSelection(m: BrainMandate): Selection {
		return { ...selectionFrom([], m.selection), projectIDs: prefillProjects(m, projects) };
	}
	const next = $derived({ grantID, projectIDs: effective ?? [] });
	const problem = $derived(
		!grantID ? 'grant_required' : !namesSomething(selection) ? 'projects_required' : selection.projectIDs.length > MAX_PROJECTS ? 'too_many' : null
	);
	const active = $derived(chosenMandate && mandateStatus(chosenMandate) === 'active' ? chosenMandate : undefined);
	// `first` saves at once; `replace` shows before and after (rights may be taken away or given).
	const kind = $derived(
		problem ? null : !active ? 'first' : sameSelection(storedSelection(active), selection) ? 'unchanged' : 'replace'
	);
	const diff = $derived(kind === 'replace' && active && effective ? diffMandate(active, next, projects) : null);
	const chosenName = $derived(nameOfGrant(grantID));
	const changing = $derived(!!chosenMandate && mandateStatus(chosenMandate) === 'active');
	const shownAudit = $derived(showAllAudit ? audit : audit.slice(0, AUDIT_PREVIEW));
	const listed = $derived(listedMandates(mandates));

	function nameOfGrant(id: string | null | undefined, fallback?: string | null): string {
		const g = id ? grants.find((x) => x.id.toLowerCase() === id.toLowerCase()) : undefined;
		return g ? connectionName(g) : fallback?.trim() || t('brainMandate.unknownConnection');
	}
	function projectName(id: string): string {
		return labels.get(id.toLowerCase()) ?? t('brainMandate.project.inaccessible', { id: id.slice(0, 8).toLowerCase() });
	}
	const listOf = (ids: string[]) => ids.map((id) => projectName(id)).join(', ');
	const lastUsed = (g: OAuthGrant) => (g.last_used_at ? t('brainMandate.form.lastUsed', { when: formatWhen(g.last_used_at) }) : t('brainMandate.form.neverUsed'));

	const groupName = (id: string) => groups.find((g) => g.id.toLowerCase() === id.toLowerCase())?.name ?? t('projectGroups.unknownGroup');
	/** Chooses a connection for the form: its own active mandate (if any) is the starting point, otherwise nothing is selected. */
	function pick(id: string) {
		grantID = id;
		const m = mandateFor(mandates, id);
		selection = m && mandateStatus(m) === 'active' ? storedSelection(m) : emptySelection();
		confirming = false;
	}
	function resetForm() {
		pick('');
	}
	/** After a reload that changed lists (a connection or project vanished): keep the person's choices where they still exist. */
	function sanitizeForm() {
		selection = pruneSelection(selection, projects.map((p) => p.id), groups.map((g) => g.id));
		if (!eligible.some((g) => g.id === grantID)) grantID = '';
		confirming = false;
		if (revokeFor && !mandateFor(mandates, revokeFor)) revokeFor = null;
	}
	async function load(keepForm = false) {
		const current = latest.begin();
		const [m, g, p, a, pg] = await Promise.all([api.listBrainMandates(), api.listOAuthGrants(), api.listProjects(), api.listBrainAudit(), api.listProjectGroups()]);
		if (!current()) return;
		mandates = m;
		grants = g;
		projects = p;
		audit = a;
		groups = pg;
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

	/** "Projekte ändern" / "Erneut erteilen" on a list entry: that connection goes into the form. */
	async function edit(id: string) {
		message = '';
		error = null;
		revokeFor = null;
		pick(id);
		await tick();
		formHeading?.focus();
		formHeading?.scrollIntoView({ block: 'start' });
	}
	async function submit(e: SubmitEvent) {
		e.preventDefault();
		if (busy || !kind || effective === null) return;
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
			const saved = await api.putBrainMandateSelection(grantID, $state.snapshot(selection));
			const name = nameOfGrant(saved.grantID, saved.grantName);
			message = t(k === 'replace' ? 'brainMandate.form.savedChange' : 'brainMandate.form.saved', { name });
			revokeFor = null;
			await Promise.all([
				api.listBrainMandates().then((m) => (mandates = m)),
				api.listOAuthGrants().then((g) => (grants = g)),
				api.listBrainAudit().then((a) => (audit = a))
			]).catch(() => undefined);
			resetForm();
			await tick();
			listEl?.focus();
		} catch (e) {
			await failure(e);
		} finally {
			inFlight = false;
			busy = false;
		}
	}
	const itemOf = (id: string) => [...(listEl?.querySelectorAll<HTMLElement>('[data-testid="bm-mandate"]') ?? [])].find((n) => n.dataset.grantId === id.toLowerCase());
	async function askRevoke(id: string) {
		revokeFor = id.toLowerCase();
		message = '';
		error = null;
		await tick();
		itemOf(id)?.querySelector<HTMLElement>('[data-testid="bm-revoke-confirm"]')?.focus();
	}
	async function cancelRevoke(id: string) {
		revokeFor = null;
		await tick();
		itemOf(id)?.querySelector<HTMLElement>('[data-testid="bm-revoke"]')?.focus();
	}
	async function revoke(id: string) {
		if (inFlight) return;
		inFlight = true;
		busy = true;
		error = null;
		const name = nameOfGrant(id, mandateFor(mandates, id)?.grantName);
		try {
			await api.revokeBrainMandate(id);
			revokeFor = null;
			mandates = await api.listBrainMandates();
			message = t('brainMandate.revoke.done', { name });
			// The revoked connection in the form starts empty again; a connection the person is editing elsewhere stays as it is.
			if (grantID.toLowerCase() === id.toLowerCase()) pick(grantID);
			await tick();
			listEl?.focus();
		} catch (e) {
			revokeFor = null;
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
		<Explainer class="text-foreground" text="{t('brainMandate.intro.lead')} {t('brainMandate.intro.allows', { name: auth.user?.displayName ?? '…' })} {t('brainMandate.intro.limits')}" />
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
		<section class={card} aria-labelledby="bm-list-title" data-testid="bm-list" data-count={listed.length} tabindex="-1" bind:this={listEl}>
			<h3 id="bm-list-title" class={heading} data-testid="bm-list-title">{t('brainMandate.list.title')}</h3>
			{#if listed.length === 0}
				<div class="text-muted-foreground flex flex-col items-center gap-1 rounded-xl border border-dashed px-4 py-8 text-center text-sm" data-testid="bm-empty">
					<p class="text-foreground font-medium">{t('brainMandate.current.empty.title')}</p>
					<p>{t('brainMandate.current.empty.text')}</p>
				</div>
			{:else}
				<ul class="flex flex-col gap-3">
					{#each listed as m (m.grantID)}
						{@const st = mandateStatus(m)}
						{@const name = nameOfGrant(m.grantID, m.grantName)}
						{@const scope = resolveScope(m.projectIDs, projects)}
						{@const rule = describeRule(m.selection, groupName, projectName)}
						<li class="flex flex-col gap-3 rounded-lg border p-3 sm:p-4" class:opacity-80={st !== 'active'} data-testid="bm-mandate" data-grant-id={m.grantID.toLowerCase()} data-status={st}>
							<div class="flex flex-wrap items-center gap-x-3 gap-y-1">
								<h4 class="min-w-0 text-sm font-semibold break-words" data-testid="bm-grant-name">{name}</h4>
								<Badge variant={st === 'active' ? 'success' : st === 'revoked' ? 'outline' : 'warning'} data-testid="bm-status">{st === 'active' ? t('brainMandate.status.active') : st === 'revoked' ? t('brainMandate.status.revoked') : st === 'recoverable' ? t('brainMandate.status.recoverable') : t('brainMandate.status.grantRevoked')}</Badge>
							</div>
							{#if st === 'grant_revoked'}
								<p class="bg-warning-soft text-warning rounded-lg px-3 py-2 text-sm" data-testid="bm-void">{t('brainMandate.status.grantRevoked.text', { name })}</p>
							{/if}
							{#if st === 'recoverable'}
								<p class="bg-warning-soft text-warning rounded-lg px-3 py-2 text-sm" data-testid="bm-recoverable">{t('brainMandate.status.recoverable.text', { name })}</p>
							{/if}
							{#if m.takenOver}
								<p class="bg-success-soft text-success rounded-lg px-3 py-2 text-sm break-words" data-testid="bm-taken-over">{t('brainMandate.current.takenOver', { name: m.takenOver.fromName, when: formatWhen(m.takenOver.at) })}</p>
							{/if}
							{#if st === 'revoked' && m.revokedAt}
								<p class={muted} data-testid="bm-was-revoked">{t('brainMandate.current.wasRevoked', { name, when: formatWhen(m.revokedAt) })}</p>
							{/if}
							<dl class="grid grid-cols-1 gap-x-4 gap-y-2 text-sm sm:grid-cols-[11rem_minmax(0,1fr)]">
								<dt class="text-muted-foreground">{t('brainMandate.current.projects')}</dt>
								<dd>
									{#if rule}<p class="mb-1 font-medium break-words" data-testid="bm-rule">{t(rule.key, { groups: rule.groups, excluded: rule.excluded })}</p>{/if}
									<ul class="flex max-h-48 flex-col gap-1 overflow-auto" data-testid="bm-scope">
										{#each scope as p (p.id)}
											<li class={p.accessible ? '' : 'text-muted-foreground italic'} data-accessible={p.accessible} data-testid="bm-scope-project">
												{p.accessible ? p.label : t('brainMandate.project.inaccessible', { id: p.label })}
											</li>
										{/each}
									</ul>
									{#if st === 'active'}<p class="text-muted-foreground mt-1 text-xs">{t('brainMandate.current.noInherit')}</p>{/if}
								</dd>
								<dt class="text-muted-foreground">{t('brainMandate.current.granted')}</dt>
								<dd data-testid="bm-granted">{formatWhen(m.createdAt)}</dd>
								{#if m.updatedAt !== m.createdAt}
									<dt class="text-muted-foreground">{t('brainMandate.current.updated')}</dt>
									<dd data-testid="bm-updated">{formatWhen(m.updatedAt)}</dd>
								{/if}
								<dt class="text-muted-foreground">{t('brainMandate.current.lastUsed')}</dt>
								<dd data-testid="bm-used">{m.lastUsedAt ? formatWhen(m.lastUsedAt) : t('brainMandate.current.neverUsed')}</dd>
							</dl>
							{#if revokeFor === m.grantID.toLowerCase()}
								<div class="border-destructive/40 bg-destructive/5 flex flex-col gap-2 rounded-lg border p-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring/50" role="alertdialog" aria-labelledby="bm-revoke-title-{m.grantID}" tabindex="-1" onkeydown={(e) => onEscape(e, () => cancelRevoke(m.grantID))} data-testid="bm-revoke-confirm">
									<p id="bm-revoke-title-{m.grantID}" class="font-semibold">{t('brainMandate.revoke.title', { name })}</p>
									<p>{t('brainMandate.revoke.text')}</p>
									<div class="flex flex-wrap gap-2">
										<Button size="sm" variant="ghost" type="button" onclick={() => cancelRevoke(m.grantID)} disabled={busy} data-testid="bm-revoke-cancel">{t('common.cancel')}</Button>
										<Button size="sm" variant="destructive" type="button" onclick={() => revoke(m.grantID)} disabled={busy} data-testid="bm-revoke-go">{t('brainMandate.revoke.go')}</Button>
									</div>
								</div>
							{:else}
								<div class="flex flex-wrap gap-2">
									{#if st === 'recoverable'}
										<Button size="sm" variant="destructive" type="button" onclick={() => askRevoke(m.grantID)} disabled={busy} aria-label={t('brainMandate.revoke.buttonFor', { name })} data-testid="bm-revoke">{t('brainMandate.revoke.button')}</Button>
									{:else if st === 'active'}
										<Button size="sm" variant="outline" type="button" onclick={() => edit(m.grantID)} disabled={busy} aria-label={t('brainMandate.current.editFor', { name })} data-testid="bm-edit">{t('brainMandate.current.edit')}</Button>
										<Button size="sm" variant="destructive" type="button" onclick={() => askRevoke(m.grantID)} disabled={busy} aria-label={t('brainMandate.revoke.buttonFor', { name })} data-testid="bm-revoke">{t('brainMandate.revoke.button')}</Button>
									{:else if eligible.some((g) => g.id.toLowerCase() === m.grantID.toLowerCase())}
										<Button size="sm" variant="outline" type="button" onclick={() => edit(m.grantID)} disabled={busy} aria-label={t('brainMandate.current.regrantFor', { name })} data-testid="bm-regrant">{t('brainMandate.current.regrant')}</Button>
									{/if}
								</div>
							{/if}
						</li>
					{/each}
				</ul>
			{/if}
		</section>

		<section class={card} aria-labelledby="bm-form-title" data-testid="bm-form-card">
			<h3 id="bm-form-title" class={heading} tabindex="-1" bind:this={formHeading} data-testid="bm-form-title">{changing ? t('brainMandate.form.titleChange', { name: chosenName }) : t('brainMandate.form.titleGrant')}</h3>
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
								<input type="radio" name="bm-grant" class="accent-ui-accent mt-0.5 size-[18px] shrink-0" value={g.id} checked={grantID === g.id} onchange={() => pick(g.id)} />
								<span class="flex min-w-0 flex-1 flex-col text-sm">
									<span class="font-medium break-words">{connectionName(g)}{#if activeIDs.has(g.id.toLowerCase())} <Badge variant="accent" class="ml-1 align-middle">{t('brainMandate.form.holder')}</Badge>{/if}</span>
									<span class="text-muted-foreground text-xs break-words">{#if g.client_name && g.client_name !== connectionName(g)}{g.client_name} · {/if}{lastUsed(g)}</span>
								</span>
							</label>
						{/each}
					</div>
				</fieldset>

				<div class="flex min-w-0 flex-col gap-2">
					<p class="text-sm font-medium">{t('brainMandate.form.projects')}</p>
					<p class="text-muted-foreground text-xs">{t('brainMandate.form.projectsHint')}</p>
					<!-- A new connection starts with empty search fields. -->
					{#key grantID}
						<ProjectSelectionPicker bind:selection bind:effective {projects} {groups} testid="bm" max={MAX_PROJECTS} disabled={busy || confirming} />
					{/key}
				</div>

				{#if confirming && diff && chosenMandate}
					<div class="border-warning/50 bg-warning-soft/60 flex flex-col gap-3 rounded-lg border p-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring/50" role="alertdialog" aria-labelledby="bm-confirm-title" tabindex="-1" bind:this={confirmBox} onkeydown={(e) => onEscape(e, cancelConfirm)} data-testid="bm-confirm">
						<h4 id="bm-confirm-title" class="font-semibold">{t('brainMandate.confirm.titleScope', { name: chosenName })}</h4>
						<div class="grid gap-2 sm:grid-cols-2">
							<div class="bg-card rounded-lg border p-3" data-testid="bm-diff-before">
								<p class="text-muted-foreground text-xs font-semibold uppercase">{t('brainMandate.confirm.before')}</p>
								<p class="font-medium break-words">{t(chosenMandate.projectIDs.length === 1 ? 'brainMandate.confirm.lineOne' : 'brainMandate.confirm.lineMany', { name: chosenName, count: chosenMandate.projectIDs.length })}</p>
								<p class="text-muted-foreground mt-1 text-xs break-words">{listOf(chosenMandate.projectIDs)}</p>
							</div>
							<div class="bg-card rounded-lg border p-3" data-testid="bm-diff-after">
								<p class="text-muted-foreground text-xs font-semibold uppercase">{t('brainMandate.confirm.after')}</p>
								<p class="font-medium break-words">{t(next.projectIDs.length === 1 ? 'brainMandate.confirm.lineOne' : 'brainMandate.confirm.lineMany', { name: chosenName, count: next.projectIDs.length })}</p>
								<p class="text-muted-foreground mt-1 text-xs break-words">{listOf(next.projectIDs)}</p>
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
						{#if diff.removed.length}
							<p class="font-medium" data-testid="bm-diff-warning">{t('brainMandate.confirm.lostScope', { name: chosenName })}</p>
						{/if}
						<p class={muted} data-testid="bm-diff-others">{t('brainMandate.confirm.othersStay')}</p>
						<div class="flex flex-wrap gap-2">
							<Button size="sm" variant="ghost" type="button" onclick={cancelConfirm} disabled={busy} data-testid="bm-confirm-cancel">{t('common.cancel')}</Button>
							<Button size="sm" type="button" onclick={save} disabled={busy} data-testid="bm-confirm-go">{busy ? t('brainMandate.form.saving') : t('brainMandate.confirm.goScope')}</Button>
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
								{t(next.projectIDs.length === 1 ? 'brainMandate.form.summaryOne' : 'brainMandate.form.summaryMany', { name: chosenName, count: next.projectIDs.length, projects: listOf(next.projectIDs) })}
							</p>
						{/if}
						<div>
							<Button type="submit" bind:ref={saveButton} disabled={busy || !!problem || kind === 'unchanged' || effective === null} aria-describedby="bm-hint" data-testid="bm-save">
								{busy ? t('brainMandate.form.saving') : kind === 'replace' ? t('brainMandate.form.saveReview') : t('brainMandate.form.saveGrant')}
							</Button>
						</div>
					</div>
				{/if}
			</form>
		</section>

		{#if audit.length > 0 || mandates.length > 0}
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
							{@const via = nameOfGrant(a.grantID, mandateFor(mandates, a.grantID)?.grantName)}
							<li class="flex flex-col gap-1 rounded-lg border p-3 text-sm" data-testid="bm-audit-item" data-kind={a.kind}>
								<div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
									<strong>{t(auditKindKey(a.kind))}</strong>
									<span class="text-muted-foreground text-xs">{formatWhen(a.createdAt)}</span>
									<span class="text-muted-foreground text-xs" data-testid="bm-audit-via">{t('brainMandate.audit.via', { name: via })}</span>
								</div>
								<p class="text-muted-foreground text-xs break-words">{#if !takeoverWithoutProject(a)}{projectName(a.projectID)}{#if !a.taskID && !isGroupChange(a.kind)}{' · '}{/if}{/if}{#if !a.taskID && !isGroupChange(a.kind)}<span data-testid="bm-audit-target">{t(isTakeover(a.kind) ? 'brainMandate.audit.from' : 'brainMandate.audit.target', { name: nameOfGrant(a.subjectID) })}</span>{/if}</p>
								{#if isTakeover(a.kind) || isGroupChange(a.kind)}
									<p class="break-words">{a.quote}</p>
								{:else}
									<blockquote class="border-l-2 pl-2 break-words whitespace-pre-wrap" aria-label={t('brainMandate.audit.quote')}>{a.quote}</blockquote>
								{/if}
								{#if a.note}<p class="text-muted-foreground text-xs break-words whitespace-pre-wrap"><span class="font-medium">{t('brainMandate.audit.note')}:</span> {a.note}</p>{/if}
								{#if a.taskID}
									{@const taskID = a.taskID}
									<a class="text-ui-accent-ink w-fit text-xs underline underline-offset-2" href="?card={auditCardParam(taskID)}" aria-label={t('brainMandate.audit.cardLabel', { kind: t(auditKindKey(a.kind)), project: projectName(a.projectID) })} onclick={(ev) => openCard(ev, taskID)} data-testid="bm-audit-card">{t('brainMandate.audit.card')}</a>
								{/if}
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
