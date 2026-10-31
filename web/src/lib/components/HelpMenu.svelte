<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { DOCS_URL, HELP_PAGES, ISSUES_URL } from '#lib/helpNav.js';
	import Popover from './app/Popover.svelte';
	import MenuItem from './app/MenuItem.svelte';
	import BookOpen from '@lucide/svelte/icons/book-open';
	import CircleHelp from '@lucide/svelte/icons/circle-help';
	import ExternalLink from '@lucide/svelte/icons/external-link';

	/** Help menu (top right): the five help pages plus documentation and issue tracker as external links. */
	let { onpage, onall }: { onpage: (id: string) => void; onall: () => void } = $props();
	let open = $state(false);
	const link = 'flex min-h-9 w-full items-center gap-2 rounded-lg px-2.5 text-left text-sm transition-colors hover:bg-muted';
</script>

<Popover label={t('helpmenu.label')} align="end" bind:open testid="help-menu" class="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex size-8 items-center justify-center rounded-lg" panelClass="w-64">
	{#snippet trigger()}<CircleHelp class="size-[18px]" aria-hidden="true" />{/snippet}
	{#snippet children(close)}
		{#each HELP_PAGES as p (p.id)}
			<MenuItem testid="help-item-{p.id}" onclick={() => { onpage(p.id); close(); }}>{t(p.label)}</MenuItem>
		{/each}
		<MenuItem testid="help-item-all" onclick={() => { onall(); close(); }}><BookOpen class="size-4" aria-hidden="true" />{t('helpmenu.all')}</MenuItem>
		<div class="bg-border my-1 h-px" role="separator"></div>
		<a class={link} href={DOCS_URL} target="_blank" rel="noopener noreferrer">{t('helpmenu.docs')}<ExternalLink class="text-muted-foreground ml-auto size-3.5" aria-hidden="true" /></a>
		<a class={link} href={ISSUES_URL} target="_blank" rel="noopener noreferrer">{t('helpmenu.report')}<ExternalLink class="text-muted-foreground ml-auto size-3.5" aria-hidden="true" /></a>
	{/snippet}
</Popover>
