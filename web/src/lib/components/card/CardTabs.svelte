<script lang="ts">
	import { CARD_TABS, tabAfterKey, type CardTab } from '#lib/cardTabs.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';
	import Hourglass from '@lucide/svelte/icons/hourglass';

	/**
	 * Tab bar of the card window (ARIA tabs pattern): roving tabindex, arrows/Home/End move and activate, the bar scrolls
	 * sideways on narrow screens and keeps the selected tab in view. The panel is rendered by the parent (id `card-tabpanel`).
	 */
	interface Props {
		value: CardTab;
		/** The tabs to show, in order (default all). */
		tabs?: readonly CardTab[];
		onchange: (tab: CardTab) => void;
		/** A tab that waits for the person: shows a marker and appends the text to the tab's spoken name. */
		hints?: Partial<Record<CardTab, string>>;
	}
	let { value, tabs = CARD_TABS, onchange, hints = {} }: Props = $props();

	let list = $state<HTMLDivElement | null>(null);

	function onkeydown(e: KeyboardEvent) {
		if (e.altKey || e.ctrlKey || e.metaKey) return;
		const next = tabAfterKey(value, e.key, tabs);
		if (!next) return;
		e.preventDefault();
		onchange(next);
		list?.querySelector<HTMLElement>(`#card-tab-${next}`)?.focus();
	}

	// Keep the selected tab fully inside the scrollable bar (deep link to a tab at the far end, arrow keys, clicks).
	$effect(() => {
		const el = list?.querySelector<HTMLElement>(`#card-tab-${value}`);
		if (!list || !el) return;
		const left = el.offsetLeft;
		const right = left + el.offsetWidth;
		if (left < list.scrollLeft) list.scrollLeft = left;
		else if (right > list.scrollLeft + list.clientWidth) list.scrollLeft = right - list.clientWidth;
	});
</script>

<!-- Sticky so the tab bar stays reachable while a long panel scrolls; full width of the column through negative margins.
     Sticky offsets count from inside the scroll container's padding: on desktop the column scrolls with `md:py-6`, so the
     negative top pins the bar to its upper edge and nothing shows through above it. On phones the scroller has no padding. -->
<div class="bg-popover sticky top-0 z-10 -mx-4 border-b px-4 md:-top-6 md:-mx-8 md:px-8" data-testid="card-tabs">
	<div
		bind:this={list}
		role="tablist"
		aria-label={t('card.tabs.label')}
		aria-orientation="horizontal"
		tabindex="-1"
		class="-mx-1 flex overflow-x-auto overscroll-x-contain px-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
		{onkeydown}
	>
		{#each tabs as tab (tab)}
			{@const selected = tab === value}
			<button
				type="button"
				role="tab"
				id="card-tab-{tab}"
				aria-selected={selected}
				aria-controls="card-tabpanel"
				aria-label={hints[tab] ? t(`card.tab.${tab}` as MessageKey) + hints[tab] : undefined}
				tabindex={selected ? 0 : -1}
				data-testid="card-tab-{tab}"
				class={[
					'focus-visible:ring-ring/60 relative inline-flex min-h-11 shrink-0 items-center rounded-t-lg px-3 text-sm font-medium whitespace-nowrap outline-none transition-colors focus-visible:ring-2 focus-visible:ring-inset',
					selected
						? 'text-foreground after:bg-ui-accent after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:rounded-full'
						: 'text-muted-foreground hover:text-foreground'
				]}
				onclick={() => onchange(tab)}
			>
				{t(`card.tab.${tab}` as MessageKey)}
				{#if hints[tab]}<span class="text-warning ml-1.5 inline-flex" data-testid="card-tab-hint-{tab}"><Hourglass class="size-3.5" aria-hidden="true" /></span>{/if}
			</button>
		{/each}
	</div>
</div>
