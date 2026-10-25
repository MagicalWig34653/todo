<script lang="ts">
	import { onMount } from 'svelte';
	import { Button } from '#lib/components/ui/button/index.js';

	let status = $state<'checking' | 'ok' | 'down'>('checking');

	onMount(async () => {
		try {
			const res = await fetch('/health/ready');
			status = res.ok ? 'ok' : 'down';
		} catch {
			status = 'down';
		}
	});
</script>

<main>
	<h1>Todo</h1>
	<p data-testid="backend-status">
		{#if status === 'checking'}Verbindung wird geprüft …{:else if status === 'ok'}Backend erreichbar{:else}Backend nicht erreichbar{/if}
	</p>
	<Button onclick={() => location.reload()}>Erneut prüfen</Button>
</main>
