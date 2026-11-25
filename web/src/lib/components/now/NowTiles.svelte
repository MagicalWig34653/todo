<script lang="ts">
	import type { MessageKey } from '#lib/i18n/index.js';
	import { t } from '#lib/i18n/index.js';
	import type { NowTileID } from '#lib/now.js';
	import Hourglass from '@lucide/svelte/icons/hourglass';
	import Activity from '@lucide/svelte/icons/activity';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import Moon from '@lucide/svelte/icons/moon';

	/** Four numbers on top; a tile with a number leads to its section, a tile with zero is calm and not clickable. */
	let { tiles, onpick }: { tiles: { id: NowTileID; count: number }[]; onpick: (id: NowTileID) => void } = $props();

	const look = {
		waiting: { label: 'now.block.waiting', icon: Hourglass, box: 'bg-warning-soft border-warning/40', ink: 'text-warning' },
		running: { label: 'now.block.running', icon: Activity, box: 'bg-ui-accent-soft border-ui-accent/40', ink: 'text-ui-accent-ink' },
		done: { label: 'now.block.done', icon: CircleCheck, box: 'bg-success-soft border-success/40', ink: 'text-success' },
		silent: { label: 'now.tile.silent', icon: Moon, box: 'bg-muted border-border', ink: 'text-muted-foreground' }
	} as const satisfies Record<NowTileID, { label: MessageKey; icon: unknown; box: string; ink: string }>;
	const base = 'flex h-full w-full flex-col items-start gap-1 rounded-xl border px-3 py-2.5 text-left';
</script>

{#snippet inner(id: NowTileID, count: number)}
	{@const l = look[id]}
	{@const Icon = l.icon}
	<span class="flex w-full items-center justify-between gap-2">
		<span class={['text-3xl leading-none font-semibold tabular-nums', count > 0 ? l.ink : 'text-muted-foreground']} data-testid="now-tile-count">{count}</span>
		<span class={['flex items-center gap-1.5', count > 0 ? l.ink : 'text-muted-foreground']}>
			{#if id === 'running' && count > 0}<span class="bg-ui-accent size-2 rounded-full motion-safe:animate-pulse" aria-hidden="true" data-testid="now-tile-pulse"></span>{/if}
			<Icon class="size-4" aria-hidden="true" />
		</span>
	</span>
	<span class={['text-xs leading-tight font-medium [overflow-wrap:anywhere] hyphens-auto @xl:text-[13px]', count > 0 ? 'text-foreground' : 'text-muted-foreground']}>{t(l.label)}</span>
{/snippet}

<ul class="grid grid-cols-2 gap-2 @md:grid-cols-4 @xl:gap-3" aria-label={t('now.tiles')} data-testid="now-tiles">
	{#each tiles as tile (tile.id)}
		<li data-testid="now-tile" data-tile={tile.id}>
			{#if tile.count > 0}
				<button
					type="button"
					class={[base, look[tile.id].box, 'shadow-card cursor-pointer transition-[filter] hover:brightness-95 dark:hover:brightness-125']}
					aria-label={t('now.tile.label', { label: t(look[tile.id].label), count: tile.count })}
					onclick={() => onpick(tile.id)}>{@render inner(tile.id, tile.count)}</button>
			{:else}
				<div class={[base, 'bg-card border-dashed']}>{@render inner(tile.id, tile.count)}</div>
			{/if}
		</li>
	{/each}
</ul>
