<script lang="ts">
	import type { CommandCard } from '#lib/api.js';
	import { percentOf, progressCounter } from '#lib/commandCenter.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { formatWhen, isOverdue } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import QuestionAnswer from './QuestionAnswer.svelte';
	import ReviewDecision from './ReviewDecision.svelte';
	import Bot from '@lucide/svelte/icons/bot';
	import Layers from '@lucide/svelte/icons/layers';
	import OctagonAlert from '@lucide/svelte/icons/octagon-alert';

	interface Props {
		card: CommandCard;
		/** Shown as a badge (list view); the kanban lane already says it. */
		showLane?: boolean;
		onopen: (card: CommandCard) => void;
		onchanged: () => void | Promise<void>;
	}
	let { card, showLane = false, onopen, onchanged }: Props = $props();

	const percent = $derived(percentOf(card.progress));
	const counter = $derived(progressCounter(card.progress));
	const sourceLabel = $derived(
		counter
			? t(`cc.card.progressSource.${counter.kind}` as MessageKey, { done: counter.done, total: counter.total })
			: t(`cc.card.progressSource.${card.progress.source}` as MessageKey, { done: 0, total: 0 })
	);
	const hiddenQuestions = $derived(Math.max(0, card.openQuestionCount - card.questions.length));
	const hiddenBuilds = $derived(Math.max(0, card.buildCount - card.builds.length));
	const jobLabel = $derived(card.agent?.jobState ? t(`cc.job.${card.agent.jobState}` as MessageKey) : null);
	const who = (label: string | null | undefined) => label || t('cc.card.agentUnknown');
</script>

<article class="bg-card text-card-foreground shadow-card flex min-w-0 flex-col gap-2.5 rounded-xl border p-3" data-testid="oc-card" data-task-id={card.task.id} data-lane={card.lane}>
	<header class="flex flex-col gap-1">
		<div class="flex flex-wrap items-center gap-1.5 text-xs">
			<span class="inline-flex min-w-0 items-center gap-1.5" data-testid="oc-project">
				<span class="size-2 shrink-0 rounded-full" style:background-color={workspace.colorOf(card.project.id)} aria-hidden="true"></span>
				<span class="text-muted-foreground truncate">{card.project.name}</span>
			</span>
			{#if card.isFeature}<Badge variant="accent"><Layers aria-hidden="true" />{t('cc.card.feature')}</Badge>{/if}
			{#if showLane}<Badge data-testid="oc-lane">{t(`cc.lane.${card.lane}` as MessageKey)}</Badge>{/if}
		</div>
		<button type="button" class="text-left text-sm leading-snug font-semibold break-words hover:underline" title={t('cc.card.open')} data-testid="oc-title" onclick={() => onopen(card)}>
			{card.task.title}
		</button>
	</header>

	<div class="flex flex-col gap-1" data-testid="oc-progress">
		<div class="flex items-baseline justify-between gap-2 text-xs">
			<span class="font-medium" data-tabular>{percent} %</span>
			<span class="text-muted-foreground truncate" title={sourceLabel}>{sourceLabel}</span>
		</div>
		<div class="bg-muted h-1.5 overflow-hidden rounded-full" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent} aria-label={t('cc.card.progress', { percent })}>
			<div class={['h-full rounded-full', card.lane === 'done' ? 'bg-success' : 'bg-ui-accent']} style:width="{percent}%"></div>
		</div>
	</div>

	{#if card.agent && (card.agent.claimedLabel || card.agent.jobState)}
		<div class="flex flex-wrap items-center gap-1.5 text-xs" data-testid="oc-agent">
			<Bot class="text-muted-foreground size-3.5 shrink-0" aria-hidden="true" />
			<span class="font-medium">{who(card.agent.claimedLabel)}</span>
			{#if jobLabel}<Badge variant={card.agent.jobState === 'failed' ? 'destructive' : 'default'}>{t('cc.card.job', { state: jobLabel })}</Badge>{/if}
		</div>
		{#if card.agent.checkpointNextStep}
			<p class="text-muted-foreground text-xs break-words">{t('cc.card.nextStep', { text: card.agent.checkpointNextStep })}</p>
		{/if}
	{/if}

	{#if card.blockedReason || card.blockedBy.length > 0}
		<p class="text-warning flex items-start gap-1.5 text-xs" data-testid="oc-blocked">
			<OctagonAlert class="mt-0.5 size-3.5 shrink-0" aria-hidden="true" />
			<span class="break-words">{card.blockedReason ? t('cc.card.blocked', { reason: card.blockedReason }) : t('cc.card.blockedBy', { count: card.blockedBy.length })}</span>
		</p>
	{/if}

	{#if card.latestUpdate}
		<div class="border-l-2 pl-2 text-xs" data-testid="oc-latest">
			<p class="text-muted-foreground">
				{[card.latestUpdate.actorLabel, formatWhen(card.latestUpdate.at)].filter(Boolean).join(', ')}
			</p>
			<p class="line-clamp-3 break-words whitespace-pre-wrap">{card.latestUpdate.text}</p>
		</div>
	{/if}

	{#each card.questions as q (q.id)}
		<QuestionAnswer id={q.id} prompt={q.prompt} options={q.options} blocking={q.blocking} askedBy={q.askedByLabel ?? who(null)} onanswered={onchanged} />
	{/each}
	{#if hiddenQuestions > 0}
		<button type="button" class="text-ui-accent-ink text-left text-xs underline underline-offset-2" onclick={() => onopen(card)}>{t('cc.card.moreQuestions', { count: hiddenQuestions })}</button>
	{/if}

	{#if card.pendingReview}
		<ReviewDecision taskID={card.task.id} summary={card.pendingReview.summary} requestedBy={card.pendingReview.requestedByLabel ?? who(null)} ondecided={onchanged} />
	{/if}

	{#if card.subtasks.length > 0}
		<ul class="flex flex-col gap-0.5 text-xs" aria-label={t('cc.card.subtasks')} data-testid="oc-subtasks">
			{#each card.subtasks as s (s.id)}
				<li class="flex items-center gap-1.5">
					<span class={['size-1.5 shrink-0 rounded-full', s.status === 'done' ? 'bg-success' : 'bg-muted-foreground/50']} aria-hidden="true"></span>
					<span class={['min-w-0 flex-1 truncate', s.status === 'done' && 'text-muted-foreground line-through']}>{s.title}</span>
					<span class="text-muted-foreground" data-tabular>{s.progressPercent} %</span>
				</li>
			{/each}
		</ul>
	{/if}

	{#if card.builds.length > 0}
		<div class="flex items-center gap-1.5" aria-label={t('cc.card.builds')} data-testid="oc-builds">
			{#each card.builds as b (b.id)}
				<a href={b.previewURL} target="_blank" rel="noopener" class="bg-muted block size-14 shrink-0 overflow-hidden rounded-md border" title={t('cc.detail.buildOpen')}>
					<img src={b.previewURL} alt={t('cc.card.buildAlt', { label: b.label || b.filename })} loading="lazy" class="size-full object-cover object-top" />
				</a>
			{/each}
			{#if hiddenBuilds > 0}<span class="text-muted-foreground text-xs">{t('cc.card.buildsMore', { count: hiddenBuilds })}</span>{/if}
		</div>
	{/if}

	{#if card.nextDue}
		<p class={['text-xs', isOverdue(card.nextDue, card.lane === 'done') ? 'text-destructive' : 'text-muted-foreground']}>{t('cc.card.due', { when: formatWhen(card.nextDue) })}</p>
	{/if}
</article>
