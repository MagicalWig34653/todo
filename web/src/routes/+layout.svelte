<script lang="ts">
	import favicon from '#lib/assets/favicon.svg';
	import './layout.css';
	import { onMount } from 'svelte';
	import { auth } from '#lib/auth.svelte.js';
	import { theme } from '#lib/theme.svelte.js';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	onMount(() => {
		theme.init();
		auth.restore();
	});
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>Todo</title>
</svelte:head>

{@render children()}
