<script lang="ts">
	import type { Snippet } from 'svelte';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { projectChain } from '#lib/cardRef.js';
	import { t } from '#lib/i18n/index.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import ChevronUp from '@lucide/svelte/icons/chevron-up';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import X from '@lucide/svelte/icons/x';
	import Popover from '../app/Popover.svelte';

	/**
	 * Top bar of the card detail window: breadcrumb (project path, clickable) on the left; previous/next card of the list,
	 * the "..." menu and close on the right. Rendered in every state of the window (loading, error, invalid).
	 */
	let {
		projectID = null,
		crumb = null,
		onopenproject,
		menu
	}: {
		projectID?: string | null;
		/** Extra last breadcrumb entry (the task of a question/review card). */
		crumb?: { label: string; onclick: () => void } | null;
		onopenproject?: (projectID: string) => void;
		menu?: Snippet<[() => void]>;
	} = $props();

	const chain = $derived(projectChain(workspace.projects, projectID, 2));
	const nav = $derived(cardDetail.neighbors);
	const btn = 'text-muted-foreground hover:bg-muted hover:text-foreground hit-area relative inline-flex size-8 shrink-0 items-center justify-center rounded-lg disabled:pointer-events-none disabled:opacity-35';

	/** J/K and the arrow keys step through the list while focus is on the header (not inside a field). */
	function onkeydown(e: KeyboardEvent) {
		if ((e.target as HTMLElement).closest('input,textarea,select,[contenteditable]')) return;
		if (e.key === 'ArrowUp' || e.key === 'k') (e.preventDefault(), cardDetail.step(-1));
		else if (e.key === 'ArrowDown' || e.key === 'j') (e.preventDefault(), cardDetail.step(1));
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<header class="flex min-h-12 shrink-0 items-center justify-between gap-2 border-b px-3 py-1.5 md:px-5" data-testid="card-header" {onkeydown}>
	<nav class="flex min-w-0 flex-1 items-center gap-1 text-sm" aria-label={t('card.breadcrumb')} data-testid="card-breadcrumb">
		{#each chain as p, i (p.id)}
			{#if i > 0}<span class="text-muted-foreground" aria-hidden="true">/</span>{/if}
			<button
				type="button"
				class="text-muted-foreground hover:text-foreground inline-flex min-h-8 min-w-0 items-center gap-1.5 rounded-md px-1.5 font-medium"
				data-testid={i === chain.length - 1 ? 'card-project' : 'card-parent-project'}
				onclick={() => onopenproject?.(p.id)}
			>
				<span class="shrink-0 font-semibold" style:color={workspace.colorOf(p.id)} aria-hidden="true">#</span><span class="truncate">{p.name}</span>
			</button>
		{/each}
		{#if crumb}
			{#if chain.length > 0}<span class="text-muted-foreground" aria-hidden="true">/</span>{/if}
			<button type="button" class="text-muted-foreground hover:text-foreground inline-flex min-h-8 min-w-0 items-center rounded-md px-1.5 font-medium" data-testid="card-crumb-task" onclick={crumb.onclick}>
				<span class="truncate">{crumb.label}</span>
			</button>
		{/if}
	</nav>
	<div class="flex shrink-0 items-center gap-0.5">
		<button type="button" class={btn} aria-label={t('card.prev')} title={t('card.prev')} disabled={!nav.prev} data-testid="card-prev" onclick={() => cardDetail.step(-1)}>
			<ChevronUp class="size-5" aria-hidden="true" />
		</button>
		<button type="button" class={btn} aria-label={t('card.next')} title={t('card.next')} disabled={!nav.next} data-testid="card-next" onclick={() => cardDetail.step(1)}>
			<ChevronDown class="size-5" aria-hidden="true" />
		</button>
		{#if menu}
			<Popover label={t('card.more')} align="end" class={btn} testid="card-more">
				{#snippet trigger()}<Ellipsis class="size-5" aria-hidden="true" />{/snippet}
				{#snippet children(close)}{@render menu(close)}{/snippet}
			</Popover>
		{/if}
		<button type="button" class={btn} aria-label={t('common.close')} title={t('common.close')} data-testid="card-close" onclick={() => cardDetail.close()}>
			<X class="size-5" aria-hidden="true" />
		</button>
	</div>
</header>
