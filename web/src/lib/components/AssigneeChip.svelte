<script lang="ts">
	import { directory } from '#lib/assignees.svelte.js';
	import type { Task } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import UserRound from '@lucide/svelte/icons/user-round';
	import Avatar from './app/Avatar.svelte';

	/**
	 * Small mark of the responsible person on a card in a list or on a board: initials with the name as label; a neutral
	 * person sign "Zugewiesen" when this account cannot know the name (readers). Nothing without an assignee.
	 */
	let { task }: { task: Pick<Task, 'projectID' | 'assigneeID' | 'assigneeName'> } = $props();

	$effect(() => {
		if (task.assigneeID) void directory.load(task.projectID);
	});
	const name = $derived(directory.nameOf(task.projectID, task.assigneeID, task.assigneeName));
	const label = $derived(name ? t('assign.chip', { name }) : t('assign.chipUnknown'));
</script>

{#if task.assigneeID}
	<span class="ml-0.5 inline-flex shrink-0 items-center align-middle" role="img" aria-label={label} title={label} data-testid="assignee-chip">
		{#if name}
			<Avatar {name} size="sm" class="size-5 ring-0" />
		{:else}
			<span class="bg-muted text-muted-foreground inline-flex size-5 items-center justify-center rounded-full"><UserRound class="size-3" aria-hidden="true" /></span>
		{/if}
	</span>
{/if}
