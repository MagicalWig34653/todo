<script lang="ts">
	import { workspace } from '#lib/workspace.svelte.js';

	/** The "#" in the project colour, as in the sidebar and the card head. Decoration: the project name stands beside it. */
	let { id }: { id: string } = $props();
</script>

<span class="shrink-0 font-semibold" style:color={workspace.colorOf(id)} aria-hidden="true" data-testid="now-project-mark">#</span>
