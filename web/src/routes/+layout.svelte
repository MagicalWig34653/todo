<script lang="ts">
	import favicon from '#lib/assets/favicon.svg';
	import './layout.css';
	import { onMount } from 'svelte';
	import { auth } from '#lib/auth.svelte.js';
	import { theme } from '#lib/theme.svelte.js';
	import { oauthNextTarget } from '#lib/routing.js';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	$effect(() => {
		const id = auth.user?.id;
		if (id) void theme.reconcile(id);
		else theme.detach();
	});

	// Sent here by the OAuth authorization page while logged out: once signed in, go back (full navigation, the page is server-rendered).
	$effect(() => {
		if (!auth.ready || !auth.user) return;
		const target = oauthNextTarget(location.search);
		try {
			if (!target) return sessionStorage.removeItem('oauthNext');
			// Loop guard: never bounce more than once per target within a tab.
			if (sessionStorage.getItem('oauthNext') === target) return;
			sessionStorage.setItem('oauthNext', target);
		} catch {
			/* storage blocked: still go back once */
		}
		if (target) location.replace(target);
	});

	onMount(() => {
		theme.init();
		auth.restore();
	});
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>Todolino</title>
</svelte:head>

{@render children()}
