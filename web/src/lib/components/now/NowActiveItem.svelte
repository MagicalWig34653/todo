<script lang="ts">
	import type { NowActive } from '#lib/api.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { dueInfo, lifeSignText, percentOf, sinceText } from '#lib/now.js';
	import { previewText } from '#lib/previewText.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import Terminal from '@lucide/svelte/icons/terminal';
	import User from '@lucide/svelte/icons/user';
	import ProjectMark from './ProjectMark.svelte';

	/** A card or session of the block "Jetzt": a card in the running grid, a compact muted row without a life sign. */
	let { item, ref, testid, compact = false }: { item: NowActive; ref: Date; testid: string; compact?: boolean } = $props();

	const pct = $derived(item.kind === 'task' ? percentOf(item) : null);
	const due = $derived(item.kind === 'task' ? dueInfo(item.dueAt, ref) : null);
	const since = $derived(sinceText(item, ref));
	const text = $derived(previewText(item.text ?? ''));
</script>

<li
	class={['flex min-w-0 flex-col', compact ? 'gap-1 py-2.5' : 'bg-card shadow-card gap-2 rounded-xl border p-3.5']}
	data-testid={testid}
	data-kind={item.kind}
>
	<div class="text-muted-foreground flex min-w-0 items-center gap-1.5 text-xs">
		<ProjectMark id={item.projectID} />
		<span class="min-w-0 truncate">{item.projectName}</span>
		{#if item.kind === 'session'}<Badge variant="outline" class="ml-auto"><Terminal aria-hidden="true" />{t('now.block.session')}</Badge>{/if}
	</div>
	<h4 class={['font-semibold [overflow-wrap:anywhere]', compact ? 'text-sm' : 'text-base leading-snug']}>
		{#if item.kind === 'task' && item.taskID}
			{@const id = item.taskID}
			<button type="button" class="focus-visible:ring-ring/50 max-menu:min-h-10 w-full rounded text-left outline-none hover:underline focus-visible:ring-2" onclick={() => cardDetail.open({ type: 'task', id })}>
				<span class="line-clamp-3">{item.title}</span>
			</button>
		{:else}
			<span class="line-clamp-3">{item.title}</span>
		{/if}
	</h4>
	{#if text}
		<p class={['text-[13px] [overflow-wrap:anywhere]', compact ? 'text-muted-foreground line-clamp-2' : 'line-clamp-3']} data-testid="now-card-text">{text}</p>
	{/if}
	{#if pct !== null}
		<div class={['flex items-center gap-2', !compact && 'mt-auto pt-0.5']}>
			<div class="bg-muted h-2 min-w-0 flex-1 overflow-hidden rounded-full" role="progressbar" aria-valuenow={pct} aria-valuemin="0" aria-valuemax="100" aria-label={t('now.progress', { percent: pct })}>
				<div class={['h-full rounded-full', compact ? 'bg-muted-foreground/50' : 'bg-ui-accent']} style:width="{pct}%"></div>
			</div>
			<span class="text-xs font-semibold tabular-nums" aria-hidden="true">{t('now.percent', { percent: pct })}</span>
		</div>
	{/if}
	<p class={['text-muted-foreground flex flex-wrap items-center gap-x-2.5 gap-y-1 text-xs', !compact && pct === null && 'mt-auto']} data-testid="{testid}-meta">
		{#if item.worker}<span class="inline-flex max-w-full min-w-0 items-center gap-1"><User class="size-3 shrink-0" aria-hidden="true" /><span class="truncate">{item.worker}</span></span>{/if}
		{#if since}<span>{since}</span>{/if}
		<span>{lifeSignText(item, ref)}</span>
		{#if due}
			<span
				class={['inline-flex items-center gap-1 rounded-full border px-2 py-0.5 font-medium', due.overdue ? 'border-red-700/40 bg-red-700/10 font-semibold text-red-700 dark:border-red-300/40 dark:bg-red-400/15 dark:text-red-300' : 'text-foreground']}
				data-testid="{testid}-due"
				data-overdue={due.overdue}
			>
				{#if due.overdue}<TriangleAlert class="size-3 shrink-0" aria-hidden="true" />{:else}<CalendarClock class="size-3 shrink-0" aria-hidden="true" />{/if}
				{due.text}
			</span>
		{/if}
	</p>
</li>
