<script lang="ts">
	import { api } from '#lib/api.js';
	import { releasedNote } from '#lib/autoStart.js';
	import Bot from '@lucide/svelte/icons/bot';

	/** Note on a job that the guard started on its own (from the `released` event, agents.yaml 1.2.0); nothing for manual starts. */
	let { jobID }: { jobID: string } = $props();
	let note = $state<string | null>(null);
	$effect(() => {
		const id = jobID;
		note = null;
		api.jobDetail(id).then(
			(d) => {
				if (id === jobID) note = releasedNote(d.events);
			},
			() => {
				/* the hint is optional; the list stays usable without it */
			}
		);
	});
</script>

{#if note}
	<p class="text-muted-foreground flex items-center gap-1 text-xs" data-testid="job-auto-note"><Bot class="size-3.5 shrink-0" aria-hidden="true" />{note}</p>
{/if}
