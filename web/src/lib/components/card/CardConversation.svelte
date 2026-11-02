<script lang="ts">
	import type { CommentThread } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import TaskComments from '../TaskComments.svelte';

	/**
	 * Conversation of a card, a small chat: people and agents write messages into one history. `thread` selects whose
	 * chat it is: the task's own (default), or the chat of one question or review of the task. Interface: the task, an
	 * optional thread, a change callback and a callback after a file was attached.
	 */
	let {
		taskID,
		thread = 'task',
		title,
		onchanged,
		onattached
	}: { taskID: string; thread?: CommentThread; title?: string; onchanged?: () => unknown; onattached?: () => unknown } = $props();
	const kind = $derived(thread === 'task' ? 'task' : 'questionID' in thread ? 'question' : 'review');
</script>

<section class="flex flex-col gap-2" aria-label={title ?? t('card.conversation')} data-testid="card-conversation" data-thread={kind}>
	{#if title}<h3 class="text-muted-foreground text-xs font-medium">{title}</h3>{/if}
	<TaskComments {taskID} {thread} {onchanged} {onattached} chat />
</section>
