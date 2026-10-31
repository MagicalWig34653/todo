<script lang="ts">
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import LoginView from '#lib/components/LoginView.svelte';
	import Workspace from '#lib/components/Workspace.svelte';
</script>

{#if !auth.ready}
	<p class="text-muted-foreground p-6 text-sm">{t('common.loading')}</p>
{:else if auth.user}
	<Workspace />
{:else}
	<LoginView />
{/if}
