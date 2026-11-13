<script lang="ts">
	import { CARD_TABS, tabAfterKey, type CardTab } from '#lib/cardTabs.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';

	/**
	 * Tab bar of the card window (ARIA tabs pattern): roving tabindex, arrows/Home/End move and activate, the bar scrolls
	 * sideways on narrow screens and keeps the selected tab in view. The panel is rendered by the parent (id `card-tabpanel`).
	 */
	let { value, onchange }: { value: CardTab; onchange: (tab: CardTab) => void } = $props();

	let list = $state<HTMLDivElement | null>(null);

	function onkeydown(e: KeyboardEvent) {
		if (e.altKey || e.ctrlKey || e.metaKey) return;
		const next = tabAfterKey(value, e.key);
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

<!-- Sticky so the tab bar stays reachable while a long panel scrolls; full width of the column through negative margins. -->
<div class="bg-popover sticky top-0 z-10 -mx-4 border-b px-4 md:-mx-8 md:px-8" data-testid="card-tabs">
	<div
		bind:this={list}
		role="tablist"
		aria-label={t('card.tabs.label')}
		aria-orientation="horizontal"
		tabindex="-1"
		class="-mx-1 flex overflow-x-auto overscroll-x-contain px-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
		{onkeydown}
	>
		{#each CARD_TABS as tab (tab)}
			{@const selected = tab === value}
			<button
				type="button"
				role="tab"
				id="card-tab-{tab}"
				aria-selected={selected}
				aria-controls="card-tabpanel"
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
			</button>
		{/each}
	</div>
</div>
