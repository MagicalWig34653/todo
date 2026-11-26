<script lang="ts">
	import { api, type Project } from '#lib/api.js';
	import { projectLabels } from '#lib/brainMandate.js';
	import { t } from '#lib/i18n/index.js';
	import {
		diffIDs,
		emptySelection,
		hasID,
		selectionSummaryKey,
		toggleID,
		type ProjectGroup,
		type Selection,
		type SelectionMode,
		type SelectionPreview
	} from '#lib/projectGroups.js';
	import { createLatest } from '#lib/serial.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	/**
	 * ADR 0037: choice of projects for a brain mandate or a connection: explicit projects and groups, or "all my projects
	 * except". Shows what is in effect right now (computed by the server) and, with `before`, what a save would change.
	 */
	let {
		selection = $bindable(),
		effective = $bindable(null),
		projects,
		groups,
		testid,
		perID = false,
		max = 200,
		disabled = false,
		before
	}: {
		selection: Selection;
		/** Ids in effect for the current choice; null while unknown. */
		effective?: string[] | null;
		projects: Project[];
		groups: ProjectGroup[];
		testid: string;
		/** `data-testid` of the explicit project boxes carries the project id (existing connection editor). */
		perID?: boolean;
		max?: number;
		disabled?: boolean;
		before?: readonly string[];
	} = $props();

	let query = $state('');
	let excludedQuery = $state('');
	let preview = $state<SelectionPreview | null>(null);
	let failed = $state(false);
	const latest = createLatest();

	const labels = $derived(projectLabels(projects));
	const label = (id: string) => labels.get(id.toLowerCase()) ?? id.slice(0, 8).toLowerCase();
	const list = (ids: readonly string[]) => ids.map(label).sort((a, b) => a.localeCompare(b, 'de')).join(', ');
	function matching(text: string) {
		const words = text.toLowerCase().split(/\s+/).filter(Boolean);
		return projects.filter((p) => words.every((w) => label(p.id).toLowerCase().includes(w))).sort((a, b) => label(a.id).localeCompare(label(b.id), 'de'));
	}
	const hint = $derived(selectionSummaryKey(selection));
	const allExcept = $derived(selection.mode === 'all_except');
	const diff = $derived(before && effective ? diffIDs(before, effective) : null);

	function setMode(mode: SelectionMode) {
		// Exclusions of the other mode would act invisibly, so they start empty.
		selection = { ...selection, mode, excludedProjectIDs: [], excludedGroupIDs: [] };
	}
	const flip = (field: 'projectIDs' | 'groupIDs' | 'excludedProjectIDs' | 'excludedGroupIDs', id: string) =>
		(selection = { ...selection, [field]: toggleID(selection[field], id) });

	// What the choice reaches is computed by the server (one resolution for preview and checks).
	$effect(() => {
		const wanted = $state.snapshot(selection);
		const current = latest.begin();
		effective = null;
		failed = false;
		api.previewSelection(wanted).then(
			(r) => {
				if (!current()) return;
				preview = r;
				effective = r.projectIDs;
			},
			() => {
				if (current()) failed = true;
			}
		);
	});

	const row = 'hover:bg-muted/50 flex min-h-10 cursor-pointer items-center gap-2.5 rounded-md px-2 text-sm';
	const box = 'flex max-h-64 flex-col overflow-auto rounded-lg border p-1';
	const sub = 'text-sm font-medium';
</script>

{#snippet groupList(field: 'groupIDs' | 'excludedGroupIDs', id: string)}
	<ul class={box} data-testid="{testid}-{id}-list">
		{#each groups as g (g.id)}
			<li>
				<label class={row}>
					<Checkbox checked={hasID(selection[field], g.id)} onchange={() => flip(field, g.id)} data-testid="{testid}-{id}" data-name={g.name} />
					<span class="min-w-0 break-words">{g.name} <span class="text-muted-foreground text-xs">({g.projectIDs.length === 1 ? t('projectGroups.countOne') : t('projectGroups.count', { count: g.projectIDs.length })})</span></span>
				</label>
			</li>
		{:else}
			<li class="text-muted-foreground px-2 py-2 text-sm">{t('projectGroups.selection.noGroups')}</li>
		{/each}
	</ul>
{/snippet}

<fieldset class="flex min-w-0 flex-col gap-3" {disabled} data-testid="{testid}-selection">
	<legend class={sub}>{t('projectGroups.selection.legend')}</legend>
	<div class="flex flex-col gap-1" role="radiogroup" aria-label={t('projectGroups.selection.legend')}>
		<label class={row}>
			<input type="radio" name="{testid}-mode" class="accent-ui-accent size-[18px] shrink-0" checked={!allExcept} onchange={() => setMode('selected')} data-testid="{testid}-mode-selected" />
			<span>{t('projectGroups.selection.selected')}</span>
		</label>
		<label class={row}>
			<input type="radio" name="{testid}-mode" class="accent-ui-accent size-[18px] shrink-0" checked={allExcept} onchange={() => setMode('all_except')} data-testid="{testid}-mode-all" />
			<span>{t('projectGroups.selection.allExcept')}</span>
		</label>
	</div>
	{#if hint}
		<p class="bg-warning-soft text-warning rounded-lg px-3 py-2 text-sm" data-testid="{testid}-hint">{t(hint)}</p>
	{/if}

	{#if allExcept}
		<p class={sub}>{t('projectGroups.selection.excludedGroups')}</p>
		{@render groupList('excludedGroupIDs', 'excluded-group')}
		<p class={sub}>{t('projectGroups.selection.excludedProjects')}</p>
		<Input type="search" bind:value={excludedQuery} placeholder={t('projectGroups.selection.excludedSearch')} aria-label={t('projectGroups.selection.excludedSearch')} data-testid="{testid}-excluded-search" />
		<ul class={box}>
			{#each matching(excludedQuery) as p (p.id)}
				<li>
					<label class={row}>
						<Checkbox checked={hasID(selection.excludedProjectIDs, p.id)} onchange={() => flip('excludedProjectIDs', p.id)} data-testid="{testid}-excluded-project" />
						<span class="min-w-0 break-words">{label(p.id)}</span>
					</label>
				</li>
			{:else}
				<li class="text-muted-foreground px-2 py-2 text-sm">{t('projectGroups.selection.noMatch')}</li>
			{/each}
		</ul>
		<p class="text-muted-foreground text-xs">{t('projectGroups.selection.excludeWins')}</p>
		<p class={sub}>{t('projectGroups.selection.extraProjects')}</p>
		<p class={sub}>{t('projectGroups.selection.groups')}</p>
		{@render groupList('groupIDs', 'group')}
	{:else}
		<p class={sub}>{t('projectGroups.selection.groups')}</p>
		{@render groupList('groupIDs', 'group')}
		{#if selection.excludedProjectIDs.length || selection.excludedGroupIDs.length}
			<!-- Exclusions of a saved rule act in this mode too: they must be visible and removable. -->
			<p class={sub}>{t('projectGroups.selection.excludedActive')}</p>
			<ul class={box} data-testid="{testid}-active-exclusions">
				{#each selection.excludedGroupIDs as id (id)}
					<li><label class={row}><Checkbox checked onchange={() => flip('excludedGroupIDs', id)} data-testid="{testid}-excluded-group" /><span class="min-w-0 break-words">{groups.find((g) => hasID([g.id], id))?.name ?? id.slice(0, 8).toLowerCase()}</span></label></li>
				{/each}
				{#each selection.excludedProjectIDs as id (id)}
					<li><label class={row}><Checkbox checked onchange={() => flip('excludedProjectIDs', id)} data-testid="{testid}-excluded-project" /><span class="min-w-0 break-words">{label(id)}</span></label></li>
				{/each}
			</ul>
		{/if}
		<p class={sub}>{t('projectGroups.selection.projects')}</p>
	{/if}

	<Input type="search" bind:value={query} placeholder={t('projectGroups.selection.search')} aria-label={t('projectGroups.selection.search')} data-testid="{testid}-project-search" />
	<ul class={box} data-testid="{testid}-project-list">
		{#each matching(query) as p (p.id)}
			<li>
				<label class={row}>
					<Checkbox checked={hasID(selection.projectIDs, p.id)} disabled={!hasID(selection.projectIDs, p.id) && selection.projectIDs.length >= max} onchange={() => flip('projectIDs', p.id)} data-testid={perID ? `${testid}-project-${p.id}` : `${testid}-project`} />
					<span class="min-w-0 break-words">{label(p.id)}</span>
				</label>
			</li>
		{:else}
			<li class="text-muted-foreground px-2 py-2 text-sm">{projects.length === 0 ? t('brainMandate.form.noProjects') : t('projectGroups.selection.noMatch')}</li>
		{/each}
	</ul>
	<div class="flex flex-wrap items-center justify-between gap-2">
		<p class="text-muted-foreground text-xs" aria-live="polite" data-testid="{testid}-selected-count">{t('projectGroups.selection.picked', { count: selection.projectIDs.length })}</p>
		{#if selection.projectIDs.length > 0 || selection.groupIDs.length > 0}
			<Button size="xs" variant="ghost" type="button" onclick={() => (selection = { ...emptySelection(), mode: selection.mode })} data-testid="{testid}-clear">{t('projectGroups.selection.clear')}</Button>
		{/if}
	</div>

	<div class="bg-muted/40 flex flex-col gap-1 rounded-lg border p-3 text-sm" aria-live="polite" data-testid="{testid}-effective">
		{#if failed}
			<p role="alert">{t('projectGroups.selection.failed')}</p>
		{:else if effective === null}
			<p class="text-muted-foreground">{t('projectGroups.selection.checking')}</p>
		{:else}
			<p class="font-medium" data-testid="{testid}-effective-count">{effective.length === 0 ? t('projectGroups.selection.effectiveNone') : effective.length === 1 ? t('projectGroups.selection.effectiveOne') : t('projectGroups.selection.effective', { count: effective.length })}</p>
			{#if effective.length}<p class="text-muted-foreground max-h-32 overflow-auto text-xs break-words" data-testid="{testid}-effective-list">{list(effective)}</p>{/if}
			{#if preview?.agentCreatedProjectIDs.length}
				<p class="text-xs break-words" data-testid="{testid}-agent-created">{t('projectGroups.selection.agentCreated', { projects: list(preview.agentCreatedProjectIDs) })}</p>
			{/if}
			{#if diff?.added.length}<p class="text-success text-xs break-words" data-testid="{testid}-diff-added">{t('projectGroups.selection.addedList', { projects: list(diff.added) })}</p>{/if}
			{#if diff?.removed.length}<p class="text-destructive text-xs break-words" data-testid="{testid}-diff-removed">{t('projectGroups.selection.removedList', { projects: list(diff.removed) })}</p>{/if}
		{/if}
	</div>
</fieldset>
