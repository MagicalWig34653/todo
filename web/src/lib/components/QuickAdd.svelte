<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { buildTree, flatten } from '#lib/projectTree.js';
	import { fromLocalInput } from '#lib/planning.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import Dialog from './app/Dialog.svelte';

	let { currentProjectID }: { currentProjectID: string | null } = $props();

	let title = $state('');
	let description = $state('');
	let due = $state('');
	let projectID = $state('');
	let busy = $state(false);

	const options = $derived(flatten(buildTree(workspace.projects)));

	// Each time the dialog opens: reset the form and preselect the current project (else "Eingang", else the first one).
	$effect(() => {
		if (!ui.quickAdd) return;
		title = '';
		description = '';
		due = '';
		const inbox = workspace.projects.find((p) => p.name === 'Eingang');
		projectID = currentProjectID ?? inbox?.id ?? workspace.projects[0]?.id ?? '';
	});

	async function submit(e: Event) {
		e.preventDefault();
		const name = title.trim();
		if (!name || !projectID || busy) return;
		busy = true;
		const ok = await attempt(async () => {
			const task = await api.createTask(projectID, name, description.trim() ? { description: description.trim() } : {});
			const dueAt = fromLocalInput(due);
			if (dueAt) await api.putPlanning(task.id, { dueAt, plannedAt: null, priority: 0, recurrence: null, reminders: [] });
		});
		busy = false;
		if (ok) {
			ui.quickAdd = false;
			ui.changeTick++;
			attempt(() => workspace.reloadTasks());
		}
	}
</script>

<Dialog bind:open={ui.quickAdd} title={t('quickAdd.title')} testid="quick-add">
	{#if workspace.projects.length === 0}
		<p class="text-muted-foreground text-sm">{t('quickAdd.noProject')}</p>
	{:else}
		<form class="flex flex-col gap-3" onsubmit={submit}>
			<Input data-autofocus bind:value={title} placeholder={t('quickAdd.titlePlaceholder')} aria-label={t('tasks.titleLabel')} class="h-10 text-base" />
			<Textarea bind:value={description} placeholder={t('tasks.descriptionPlaceholder')} aria-label={t('tasks.description')} rows={2} />
			<div class="grid gap-2 sm:grid-cols-2">
				<label class="flex flex-col gap-1 text-xs font-medium">
					{t('search.project')}
					<Select bind:value={projectID}>
						{#each options as o (o.project.id)}<option value={o.project.id}>{'  '.repeat(o.depth)}{o.project.name}</option>{/each}
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">
					{t('planning.due')}
					<Input type="datetime-local" bind:value={due} />
				</label>
			</div>
			<div class="flex justify-end gap-2">
				<Button type="button" variant="ghost" onclick={() => (ui.quickAdd = false)}>{t('common.cancel')}</Button>
				<Button type="submit" disabled={!title.trim() || busy}>{t('quickAdd.submit')}</Button>
			</div>
		</form>
	{/if}
</Dialog>
