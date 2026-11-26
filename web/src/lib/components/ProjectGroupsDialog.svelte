<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/api.js';
	import { projectLabels } from '#lib/brainMandate.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { diffIDs, type ProjectGroup, type SelectionChange } from '#lib/projectGroups.js';
	import { createLatest } from '#lib/serial.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ProjectGroupChecks from './ProjectGroupChecks.svelte';

	/** Project settings "Projektgruppen" (ADR 0037): the person's groups of one project, with what saving changes. */
	let { projectID, onclose }: { projectID: string; onclose: () => void } = $props();

	let groups = $state<ProjectGroup[]>([]);
	let stored = $state<string[] | null>(null);
	let selected = $state<string[]>([]);
	let changes = $state<SelectionChange[] | null>(null);
	let error = $state<string | null>(null);
	let busy = $state(false);
	const latest = createLatest();

	const labels = $derived(projectLabels(workspace.projects));
	const names = (ids: string[]) => ids.map((id) => labels.get(id.toLowerCase()) ?? id.slice(0, 8).toLowerCase()).join(', ');
	const dirty = $derived.by(() => {
		if (!stored) return false;
		const d = diffIDs(stored, selected);
		return d.added.length > 0 || d.removed.length > 0;
	});

	onMount(() => {
		Promise.all([api.listProjectGroups(), api.groupsOfProject(projectID)]).then(
			([g, ids]) => {
				groups = g;
				selected = [...ids];
				stored = ids;
			},
			(e) => (error = describeError(e))
		);
	});

	// What saving would change for mandates and connections, computed by the server without saving.
	$effect(() => {
		const wanted = $state.snapshot(selected);
		const needed = dirty;
		const current = latest.begin();
		changes = null;
		if (!needed) return;
		api.setGroupsOfProject(projectID, wanted, true).then(
			(r) => {
				if (current()) changes = r.changes;
			},
			(e) => {
				if (current()) error = describeError(e);
			}
		);
	});

	async function save(ev: SubmitEvent) {
		ev.preventDefault();
		if (busy || !dirty || !changes) return;
		busy = true;
		error = null;
		try {
			await api.setGroupsOfProject(projectID, $state.snapshot(selected));
			onclose();
		} catch (e) {
			error = describeError(e);
		} finally {
			busy = false;
		}
	}
</script>

<form class="flex flex-col gap-3" onsubmit={save} data-testid="project-groups-form">
	{#if error}<p class="text-destructive text-sm" role="alert">{error}</p>{/if}
	{#if stored === null}
		{#if !error}<p class="text-muted-foreground text-sm" role="status">{t('common.loading')}</p>{/if}
	{:else}
		<ProjectGroupChecks {groups} bind:selected disabled={busy} testid="project-groups-checks" />
		<div aria-live="polite" class="text-sm" data-testid="project-groups-impact">
			{#if dirty && changes}
				<p class="font-medium">{changes.length ? t('projectGroups.impact.title') : t('projectGroups.impact.none')}</p>
				<ul class="flex flex-col gap-1">
					{#each changes as c (c.kind + c.grantID)}
						<li class="text-xs break-words">
							{t(c.kind === 'mandate' ? 'projectGroups.impact.mandate' : 'projectGroups.impact.connection', { name: c.name })}:
							{#if c.added.length}<span class="text-success">{t('projectGroups.impact.added', { projects: names(c.added) })}</span>{/if}
							{#if c.removed.length}<span class="text-destructive">{t('projectGroups.impact.removed', { projects: names(c.removed) })}</span>{/if}
						</li>
					{/each}
				</ul>
			{/if}
		</div>
	{/if}
	<div class="flex justify-end gap-2">
		<Button type="button" variant="ghost" onclick={onclose}>{t('common.cancel')}</Button>
		<Button type="submit" disabled={busy || !dirty || !changes} data-testid="project-groups-save">{t('account.oauth.editProjects.save')}</Button>
	</div>
</form>
