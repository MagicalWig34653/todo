<script lang="ts">
	import type { NowActive, NowBlock } from '#lib/api.js';
	import { relativeWhen } from '#lib/cardRef.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { uniqueKeys } from '#lib/keys.js';
	import { nowTiles, type NowTileID } from '#lib/now.js';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import Moon from '@lucide/svelte/icons/moon';
	import Coffee from '@lucide/svelte/icons/coffee';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import NowTiles from './NowTiles.svelte';
	import NowActiveItem from './NowActiveItem.svelte';
	import NowWaitingList from './NowWaitingList.svelte';
	import ProjectMark from './ProjectMark.svelte';

	/** `ref` follows the server clock (ages and due dates), `now` the device clock like the rest of the app. */
	let { block: b, ref, now }: { block: NowBlock; ref: Date; now: Date } = $props();

	const activeKey = (item: NowActive) => `${item.kind}:${item.taskID ?? item.projectID + item.title}`;
	const heading = 'focus-visible:ring-ring/50 mb-2 flex scroll-mt-16 flex-wrap items-baseline gap-x-2 rounded text-base font-semibold outline-none focus-visible:ring-2';
	let root = $state<HTMLElement>();
	/** The list shows five at most; the tile counts all cards of the window, so the difference is said here. */
	const doneHint = $derived(
		b.counts.recentlyDone > b.recentlyDone.length
			? `${t('now.block.doneHint')} · ${t('now.block.doneShown', { shown: b.recentlyDone.length, count: b.counts.recentlyDone })}`
			: t('now.block.doneHint')
	);

	/** A tile moves focus and view to its section; "Ohne Lebenszeichen" opens first. */
	function jump(id: NowTileID) {
		const target = root?.querySelector<HTMLElement>(`[data-jump="${id}"]`);
		if (!target) return;
		const details = target.closest('details');
		if (details) details.open = true;
		target.focus({ preventScroll: true });
		const calm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
		(details ?? target).scrollIntoView({ block: 'start', behavior: calm ? 'auto' : 'smooth' });
	}
</script>

<div class="mb-8 flex flex-col gap-6" data-testid="now-block" bind:this={root}>
	<NowTiles tiles={nowTiles(b)} onpick={jump} />

	<section aria-labelledby="nb-running" data-testid="now-running">
		<h3 id="nb-running" class={heading} tabindex="-1" data-jump="running">
			{t('now.block.running')}{#if b.counts.running > 0}<span class="text-muted-foreground text-sm font-normal">({b.counts.running})</span>{/if}
		</h3>
		{#if b.running.length === 0}
			<div class="text-muted-foreground flex items-center gap-3 rounded-xl border border-dashed px-4 py-4">
				<Coffee class="size-5 shrink-0" aria-hidden="true" />
				<p class="text-sm" data-testid="now-running-empty">{t('now.block.runningEmpty')}</p>
			</div>
		{:else}
			<ul class="grid grid-cols-1 gap-3 @xl:grid-cols-2">
				{#each uniqueKeys(b.running, activeKey) as { item, key } (key)}<NowActiveItem {item} {ref} testid="now-running-item" />{/each}
			</ul>
		{/if}
	</section>

	{#if b.counts.waiting > 0 || b.waiting.length > 0}
		<section aria-labelledby="nb-waiting" data-testid="now-waiting">
			<h3 id="nb-waiting" class={heading} tabindex="-1" data-jump="waiting">
				{t('now.block.waiting')}<span class="text-muted-foreground text-sm font-normal">({b.counts.waiting})</span>
			</h3>
			<NowWaitingList items={b.waiting} total={b.counts.waiting} {now} />
		</section>
	{/if}

	{#if b.counts.recentlyDone > 0 || b.recentlyDone.length > 0}
		<section aria-labelledby="nb-done" data-testid="now-done">
			<h3 id="nb-done" class={heading} tabindex="-1" data-jump="done">
				{t('now.block.done')}<span class="text-muted-foreground text-[13px] font-normal">{doneHint}</span>
			</h3>
			<ul class="bg-card shadow-card divide-y rounded-xl border px-3">
				{#each uniqueKeys(b.recentlyDone, (d) => d.taskID) as { item: d, key } (key)}
					<li class="flex gap-2.5 py-2 text-sm" data-testid="now-done-item">
						<CircleCheck class="text-success mt-0.5 size-4 shrink-0 max-menu:mt-3" aria-hidden="true" />
						<div class="flex min-w-0 flex-1 flex-col @lg:flex-row @lg:items-baseline @lg:justify-between @lg:gap-3">
							<button type="button" class="focus-visible:ring-ring/50 max-menu:min-h-10 min-w-0 rounded text-left outline-none hover:underline focus-visible:ring-2 [overflow-wrap:anywhere]" onclick={() => cardDetail.open({ type: 'task', id: d.taskID })}>{d.title}</button>
							<span class="text-muted-foreground flex shrink-0 flex-wrap items-center gap-x-1 text-xs"><ProjectMark id={d.projectID} />{d.projectName} · {t('now.block.doneAgo', { time: relativeWhen(d.doneAt, now) })}</span>
						</div>
					</li>
				{/each}
			</ul>
		</section>
	{/if}

	{#if b.counts.silent > 0 || b.silent.length > 0}
		<details class="group bg-muted/40 rounded-xl border border-dashed scroll-mt-16" data-testid="now-silent">
			<summary data-jump="silent" class="focus-visible:ring-ring/50 flex min-h-11 cursor-pointer items-center gap-2 rounded-xl px-3 py-2.5 outline-none focus-visible:ring-2 [&::-webkit-details-marker]:hidden">
				<ChevronRight class="text-muted-foreground size-4 shrink-0 group-open:rotate-90" aria-hidden="true" />
				<Moon class="text-muted-foreground size-4 shrink-0" aria-hidden="true" />
				<h3 class="text-base font-semibold">{t('now.block.silent', { count: b.counts.silent })}</h3>
			</summary>
			<div class="px-3 pb-2">
				<p class="text-muted-foreground mb-1 text-[13px]">{t('now.block.silentHint')}</p>
				<ul class="divide-y">
					{#each uniqueKeys(b.silent, activeKey) as { item, key } (key)}<NowActiveItem {item} {ref} testid="now-silent-item" compact />{/each}
				</ul>
			</div>
		</details>
	{/if}
</div>
