<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import TaskComments from '../TaskComments.svelte';

	/**
	 * "Unterhaltung" section of the card detail. Interface: the task the conversation belongs to and a change callback.
	 * For now it shows the task's comments; a chat replaces this component without touching the detail window.
	 */
	let { taskID, onchanged }: { taskID: string; onchanged?: () => unknown } = $props();
</script>

<section class="flex flex-col gap-2" aria-labelledby="conv-h-{taskID}" data-testid="card-conversation">
	<h3 id="conv-h-{taskID}" class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.conversation')}</h3>
	<TaskComments {taskID} {onchanged} />
</section>
