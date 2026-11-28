<script lang="ts">
	import { untrack } from 'svelte';
	import { api, type Task } from '#lib/api.js';
	import { directory } from '#lib/assignees.svelte.js';
	import { candidatesFor } from '#lib/assignment.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import SideSection from './SideSection.svelte';

	/** "Zuständig" in the card sidebar: the name or "Niemand"; a choice with edit, plain text otherwise. */
	let { task, onchanged }: { task: Task; onchanged: () => void | Promise<void> } = $props();

	const editable = $derived(directory.mayAssign(task.projectID));
	const people = $derived(candidatesFor(directory.people(task.projectID), 'task'));
	const current = $derived(task.assigneeID ?? '');
	const name = $derived(task.assigneeID ? directory.label(task.projectID, task.assigneeID, task.assigneeName) : t('assign.nobody'));
	let busy = $state(false);
	let value = $state('');
	$effect(() => {
		value = current;
	});
	$effect(() => {
		const projectID = task.projectID;
		if (editable) untrack(() => void directory.load(projectID, true));
	});

	async function save() {
		if (busy || value === current) return;
		busy = true;
		const ok = await attempt(async () => {
			await api.setTaskAssignee(task.id, value || null);
			await onchanged();
			await workspace.reloadTasks();
		});
		busy = false;
		if (!ok) {
			value = current;
			await onchanged();
		}
	}
</script>

{#if directory.supported}
	<SideSection title={t('assign.field')} testid="side-assignee">
		{#if editable}
			<Select class="w-full" bind:value aria-label={t('assign.field')} disabled={busy} onchange={save}>
				<option value="">{t('assign.nobody')}</option>
				<!-- The stored person stays selectable while the list loads, or after losing access to the project. -->
				{#if current && !people.some((p) => p.userID === current)}<option value={current}>{name}</option>{/if}
				{#each people as p (p.userID)}<option value={p.userID}>{p.displayName}</option>{/each}
			</Select>
		{:else}
			<p class="[overflow-wrap:anywhere]" data-testid="assignee-name">{name}</p>
		{/if}
	</SideSection>
{/if}
