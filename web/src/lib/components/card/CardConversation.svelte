<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import TaskComments from '../TaskComments.svelte';

	/**
	 * "Unterhaltung" section of the card detail. Interface: the task the conversation belongs to, a change callback and
	 * a callback after a file was attached. For now it shows the task's comments; a chat replaces this component
	 * without touching the detail window.
	 */
	let { taskID, onchanged, onattached }: { taskID: string; onchanged?: () => unknown; onattached?: () => unknown } = $props();
</script>

<section class="flex flex-col gap-2" aria-label={t('card.conversation')} data-testid="card-conversation">
	<TaskComments {taskID} {onchanged} {onattached} chat />
</section>
