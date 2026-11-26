<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { api, ApiError, type Project } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { projectLabels } from '#lib/brainMandate.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { groupNameProblem, hasID, toggleID, type ProjectGroup, type SelectionChange } from '#lib/projectGroups.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	/**
	 * Settings page "Projektgruppen" (ADR 0037). Every change of members and every delete is shown first with what it does to
	 * mandates and connections (the server computes it with `dryRun`, the same code that saves).
	 */
	let loaded = $state(false);
	let groups = $state<ProjectGroup[]>([]);
	let projects = $state<Project[]>([]);
	let message = $state('');
	let error = $state<string | null>(null);
	let busy = $state(false);

	let newName = $state('');
	/** Group in the editor; its draft name and members. */
	let editing = $state<string | null>(null);
	let name = $state('');
	let members = $state<string[]>([]);
	let query = $state('');
	/** What the pending change would do; shown before it is saved. */
	let pending = $state<{ kind: 'save' | 'delete'; changes: SelectionChange[] } | null>(null);
	let confirmBox = $state<HTMLElement | null>(null);
	let listEl = $state<HTMLElement | null>(null);

	const labels = $derived(projectLabels(projects));
	const label = (id: string) => labels.get(id.toLowerCase()) ?? id.slice(0, 8).toLowerCase();
	const names = (ids: string[]) => ids.map(label).join(', ');
	const visible = $derived.by(() => {
		const words = query.toLowerCase().split(/\s+/).filter(Boolean);
		return projects.filter((p) => words.every((w) => label(p.id).toLowerCase().includes(w))).sort((a, b) => label(a.id).localeCompare(label(b.id), 'de'));
	});

	async function load() {
		const [g, p] = await Promise.all([api.listProjectGroups(), api.listProjects()]);
		groups = g;
		projects = p;
	}
	async function init() {
		error = null;
		try {
			await load();
		} catch (e) {
			if (e instanceof ApiError && e.isUnauthorized) auth.user = null;
			error = describeError(e);
		} finally {
			loaded = true;
		}
	}
	onMount(() => {
		void init();
	});

	/** One request at a time; errors are shown, a vanished group or project reloads the lists. */
	async function run(action: () => Promise<void>) {
		if (busy) return;
		busy = true;
		error = null;
		message = '';
		try {
			await action();
		} catch (e) {
			pending = null;
			if (e instanceof ApiError && e.isUnauthorized) auth.user = null;
			error = e instanceof ApiError && e.reason === 'name_taken' ? t('projectGroups.error.taken') : describeError(e);
			if (e instanceof ApiError && e.status === 404) await load().catch(() => undefined);
		} finally {
			busy = false;
		}
	}
	function create(ev: SubmitEvent) {
		ev.preventDefault();
		const problem = groupNameProblem(newName, groups);
		if (problem) {
			error = t(problem);
			return;
		}
		void run(async () => {
			const { group } = await api.createProjectGroup(newName.trim(), []);
			newName = '';
			await load();
			message = t('projectGroups.created', { name: group.name });
			edit(group);
		});
	}
	function edit(g: ProjectGroup) {
		editing = g.id;
		name = g.name;
		members = [...g.projectIDs];
		query = '';
		pending = null;
	}
	function close() {
		editing = null;
		pending = null;
	}
	function toggle(id: string) {
		members = toggleID(members, id);
		pending = null;
	}
	function review(ev: SubmitEvent, g: ProjectGroup) {
		ev.preventDefault();
		const problem = groupNameProblem(name, groups, g.id);
		if (problem) {
			error = t(problem);
			return;
		}
		void run(async () => {
			const { changes } = await api.updateProjectGroup(g.id, { name: name.trim(), projectIDs: members }, true);
			// Nothing changes for any mandate or connection: save right away.
			if (changes.length === 0) await store(g);
			else {
				pending = { kind: 'save', changes };
				await tick();
				confirmBox?.focus();
			}
		});
	}
	async function store(g: ProjectGroup) {
		await api.updateProjectGroup(g.id, { name: name.trim(), projectIDs: members });
		close();
		await load();
		message = t('projectGroups.saved');
		await tick();
		listEl?.focus();
	}
	function askDelete(g: ProjectGroup) {
		void run(async () => {
			const { changes } = await api.deleteProjectGroup(g.id, true);
			editing = g.id;
			name = g.name;
			members = [...g.projectIDs];
			pending = { kind: 'delete', changes };
			await tick();
			confirmBox?.focus();
		});
	}
	function confirm(g: ProjectGroup) {
		const kind = pending?.kind;
		void run(async () => {
			if (kind === 'delete') {
				await api.deleteProjectGroup(g.id);
				close();
				await load();
				message = t('projectGroups.deleted');
				await tick();
				listEl?.focus();
			} else await store(g);
		});
	}

	const card = 'bg-card flex flex-col gap-3 rounded-xl border p-4 shadow-card sm:p-5';
</script>

<div class="flex max-w-3xl flex-col gap-4" data-testid="project-groups">
	<section class={card}>
		<p class="text-sm">{t('projectGroups.intro')}</p>
		<form class="flex flex-wrap items-end gap-2" onsubmit={create} novalidate>
			<label class="flex min-w-0 flex-1 basis-48 flex-col gap-1 text-sm font-medium">
				{t('projectGroups.new')}
				<Input bind:value={newName} maxlength={80} placeholder={t('projectGroups.name')} autocomplete="off" data-testid="pg-new-name" />
			</label>
			<Button type="submit" disabled={busy || !newName.trim()} data-testid="pg-create">{t('projectGroups.create')}</Button>
		</form>
	</section>

	<div role="status" aria-live="polite" class={message ? 'bg-success-soft text-success rounded-lg px-3 py-2 text-sm' : 'sr-only'} data-testid="pg-message">{message}</div>
	{#if error}<p class="bg-destructive/10 text-destructive rounded-lg px-3 py-2 text-sm" role="alert" data-testid="pg-error">{error}</p>{/if}

	{#if !loaded}
		<p class="text-muted-foreground text-sm" role="status">{t('common.loading')}</p>
	{:else}
		<ul class="flex flex-col gap-3" tabindex="-1" bind:this={listEl} data-testid="pg-list">
			{#each groups as g (g.id)}
				<li class={card} data-testid="pg-group" data-name={g.name}>
					<div class="flex flex-wrap items-center gap-x-3 gap-y-2">
						<h3 class="min-w-0 flex-1 text-sm font-semibold break-words">{g.name} <span class="text-muted-foreground text-xs font-normal">({g.projectIDs.length === 1 ? t('projectGroups.countOne') : t('projectGroups.count', { count: g.projectIDs.length })})</span></h3>
						{#if editing !== g.id}
							<Button size="sm" variant="outline" disabled={busy} onclick={() => edit(g)} data-testid="pg-edit">{t('projectGroups.edit')}</Button>
							<Button size="sm" variant="destructive" disabled={busy} onclick={() => askDelete(g)} data-testid="pg-delete">{t('projectGroups.delete')}</Button>
						{/if}
					</div>
					{#if editing !== g.id && g.projectIDs.length}
						<p class="text-muted-foreground text-xs break-words" data-testid="pg-members">{names(g.projectIDs)}</p>
					{/if}
					{#if editing === g.id}
						{#if pending?.kind !== 'delete'}
							<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
							<form class="flex flex-col gap-3" onsubmit={(e) => review(e, g)} onkeydown={(e) => e.key === 'Escape' && close()} novalidate>
								<label class="flex flex-col gap-1 text-sm font-medium">
									{t('projectGroups.name')}
									<Input bind:value={name} maxlength={80} autocomplete="off" data-testid="pg-name" />
								</label>
								<fieldset class="flex min-w-0 flex-col gap-2" disabled={busy || !!pending}>
									<legend class="text-sm font-medium">{t('projectGroups.members')}</legend>
									<Input type="search" bind:value={query} placeholder={t('projectGroups.selection.search')} aria-label={t('projectGroups.selection.search')} data-testid="pg-project-search" />
									<ul class="flex max-h-64 flex-col overflow-auto rounded-lg border p-1">
										{#each visible as p (p.id)}
											<li>
												<label class="hover:bg-muted/50 flex min-h-10 cursor-pointer items-center gap-2.5 rounded-md px-2 text-sm">
													<Checkbox checked={hasID(members, p.id)} onchange={() => toggle(p.id)} data-testid="pg-project" />
													<span class="min-w-0 break-words">{label(p.id)}</span>
												</label>
											</li>
										{:else}
											<li class="text-muted-foreground px-2 py-2 text-sm">{t('projectGroups.selection.noMatch')}</li>
										{/each}
									</ul>
								</fieldset>
								{#if !pending}
									<div class="flex flex-wrap gap-2">
										<Button size="sm" type="submit" disabled={busy} data-testid="pg-save">{t('projectGroups.save')}</Button>
										<Button size="sm" variant="ghost" type="button" disabled={busy} onclick={close}>{t('projectGroups.cancel')}</Button>
									</div>
								{/if}
							</form>
						{/if}
						{#if pending}
							<div class="border-warning/50 bg-warning-soft/60 flex flex-col gap-2 rounded-lg border p-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring/50" role="alertdialog" aria-labelledby="pg-impact-{g.id}" tabindex="-1" bind:this={confirmBox} onkeydown={(e) => e.key === 'Escape' && (pending?.kind === 'delete' ? close() : (pending = null))} data-testid="pg-impact">
								<h4 id="pg-impact-{g.id}" class="font-semibold">{pending.kind === 'delete' ? `${t('projectGroups.delete')}: ${g.name}` : t('projectGroups.impact.title')}</h4>
								{#if pending.kind === 'delete'}<p>{t('projectGroups.deleteHint')}</p>{/if}
								{#if pending.changes.length === 0}
									<p>{t('projectGroups.impact.none')}</p>
								{:else}
									<ul class="flex flex-col gap-2">
										{#each pending.changes as c (c.kind + c.grantID)}
											<li class="bg-card rounded-lg border p-2" data-testid="pg-change" data-kind={c.kind}>
												<p class="font-medium break-words">{t(c.kind === 'mandate' ? 'projectGroups.impact.mandate' : 'projectGroups.impact.connection', { name: c.name })}</p>
												{#if c.added.length}<p class="text-success text-xs break-words">+ {t('projectGroups.impact.added', { projects: names(c.added) })}</p>{/if}
												{#if c.removed.length}<p class="text-destructive text-xs break-words">− {t('projectGroups.impact.removed', { projects: names(c.removed) })}</p>{/if}
											</li>
										{/each}
									</ul>
								{/if}
								<div class="flex flex-wrap gap-2">
									<Button size="sm" variant="ghost" type="button" disabled={busy} onclick={() => (pending?.kind === 'delete' ? close() : (pending = null))} data-testid="pg-cancel">{t('projectGroups.cancel')}</Button>
									<Button size="sm" variant={pending.kind === 'delete' ? 'destructive' : 'default'} type="button" disabled={busy} onclick={() => confirm(g)} data-testid="pg-confirm">{pending.kind === 'delete' ? t('projectGroups.delete') : t('projectGroups.confirm')}</Button>
								</div>
							</div>
						{/if}
					{/if}
				</li>
			{:else}
				<li class="text-muted-foreground rounded-xl border border-dashed px-4 py-8 text-center text-sm" data-testid="pg-empty">{t('projectGroups.empty')}</li>
			{/each}
		</ul>
	{/if}
</div>
