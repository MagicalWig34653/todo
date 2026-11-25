<script lang="ts">
	import type { NowWaiting } from '#lib/api.js';
	import { relativeWhen } from '#lib/cardRef.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { uniqueKeys } from '#lib/keys.js';
	import { NOW_WAITING_FIRST, notListed, waitingCard } from '#lib/now.js';
	import { previewText } from '#lib/previewText.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import MessageCircleQuestion from '@lucide/svelte/icons/message-circle-question-mark';
	import ClipboardCheck from '@lucide/svelte/icons/clipboard-check';
	import ProjectMark from './ProjectMark.svelte';

	/** Entry of the block, or of a project section (there the project is already named by the row around it). */
	type Entry = Omit<NowWaiting, 'projectName'> & { projectName?: string };
	/** One connected list of open questions and pending reviews: five first, all on demand. `total` counts what the server knows. */
	let { items, total = items.length, now }: { items: Entry[]; total?: number; now: Date } = $props();

	let all = $state(false);
	const shown = $derived(all ? items : items.slice(0, NOW_WAITING_FIRST));
	const missing = $derived(notListed(total, items.length));
</script>

{#if items.length > 0}
	<ul class="bg-card shadow-card border-l-warning divide-y overflow-hidden rounded-xl border border-l-4">
		{#each uniqueKeys(shown, (w) => w.kind + w.id) as { item: w, key } (key)}
			<li class="flex flex-col gap-2 px-3 py-2.5 @lg:flex-row @lg:items-center @lg:gap-3" data-testid="now-waiting-item" data-kind={w.kind}>
				<div class="flex min-w-0 flex-1 gap-2.5">
					<span class="bg-warning-soft text-warning mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full">
						{#if w.kind === 'review'}<ClipboardCheck class="size-4" aria-hidden="true" />{:else}<MessageCircleQuestion class="size-4" aria-hidden="true" />{/if}
					</span>
					<div class="min-w-0 flex-1">
						<p class="text-warning text-xs font-semibold">{w.kind === 'review' ? t('now.review') : t('now.question')}</p>
						<p class="line-clamp-2 text-sm [overflow-wrap:anywhere]" data-testid="now-waiting-text">{previewText(w.text)}</p>
						<p class="text-muted-foreground mt-0.5 flex flex-wrap items-center gap-x-2 text-xs">
							{#if w.projectName}<span class="inline-flex max-w-full min-w-0 items-center gap-1"><ProjectMark id={w.projectID} /><span class="truncate">{w.projectName}</span></span>{/if}
							<span class="line-clamp-1 min-w-0 [overflow-wrap:anywhere]">{w.taskTitle}</span>
							<time datetime={new Date(w.createdAt).toISOString()} title={w.createdAt}>{relativeWhen(w.createdAt, now)}</time>
						</p>
					</div>
				</div>
				<Button size="sm" class="max-menu:h-10 max-menu:px-4 ml-9.5 self-start @lg:ml-0 @lg:self-center" variant={w.kind === 'review' ? 'outline' : 'default'} onclick={() => cardDetail.open(waitingCard(w))}>{w.kind === 'review' ? t('now.look') : t('now.answer')}</Button>
			</li>
		{/each}
	</ul>
{/if}
{#if items.length > NOW_WAITING_FIRST}
	<Button variant="ghost" size="sm" class="max-menu:h-10 mt-1.5 w-full" aria-expanded={all} data-testid="now-waiting-toggle" onclick={() => (all = !all)}>
		{all ? t('now.waiting.less') : t(missing > 0 ? 'now.waiting.allLoaded' : 'now.waiting.all', { count: items.length })}
	</Button>
{/if}
{#if missing > 0}
	<p class="text-muted-foreground mt-1 text-[13px]" data-testid="now-waiting-more">{missing === 1 ? t('now.waiting.moreOne') : t('now.waiting.more', { count: missing })}</p>
{/if}
