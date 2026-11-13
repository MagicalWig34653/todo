<script lang="ts">
	import { relativeWhen } from '#lib/cardRef.js';
	import type { Report } from '#lib/cardTabs.js';
	import { t } from '#lib/i18n/index.js';
	import { formatWhen } from '#lib/planning.js';
	import CardTabEmpty from './CardTabEmpty.svelte';
	import Markdown from './Markdown.svelte';

	/** "Bericht" tab: completion summary, progress notes, questions with answers and the review decision of one card. */
	let { report }: { report: Report } = $props();

	const when = (iso?: string | null) => [relativeWhen(iso), formatWhen(iso)].filter(Boolean).join(' · ');
	const heading = 'text-muted-foreground text-xs font-semibold tracking-wide uppercase';
	const review = $derived(report.review);
</script>

{#if report.isEmpty}
	<CardTabEmpty title={t('card.report.empty')} text={t('card.report.emptyText')} />
{:else}
	{#if report.completion}
		<section class="bg-success-soft flex flex-col gap-2 rounded-xl border p-3" data-testid="report-completion">
			<h3 class="font-semibold">{t('card.report.completion')}</h3>
			<p class="text-muted-foreground text-xs" data-tabular>
				{[review?.requestedByLabel, when(report.completion.decidedAt ?? review?.createdAt)].filter(Boolean).join(' · ')}{report.completion.lastPercent != null ? ` · ${t('card.report.completionPercent', { percent: report.completion.lastPercent })}` : ''}
			</p>
			<Markdown text={report.completion.summary} />
		</section>
	{/if}

	{#if report.notes.length > 0}
		<section class="flex flex-col gap-1.5">
			<h3 class={heading}>{t('cc.detail.notes')}</h3>
			<ol class="flex flex-col gap-3 border-l pl-4" data-testid="report-notes">
				{#each report.notes as n (n.id)}
					<li class="relative">
						<span class="bg-ui-accent absolute top-1.5 -left-[1.28rem] size-2 rounded-full" aria-hidden="true"></span>
						<p class="text-muted-foreground text-xs" data-tabular>{n.actorLabel || t('cc.update.anonymous')} · {when(n.createdAt)}{n.percent != null ? ` · ${n.percent} %` : ''}</p>
						<p class="[overflow-wrap:anywhere] whitespace-pre-wrap">{n.note}</p>
					</li>
				{/each}
			</ol>
		</section>
	{/if}

	{#if report.questions.length > 0}
		<section class="flex flex-col gap-1.5">
			<h3 class={heading}>{t('card.report.questions')}</h3>
			<ul class="flex flex-col gap-3" data-testid="report-questions">
				{#each report.questions as q (q.id)}
					<li class="flex flex-col gap-0.5 border-l-2 pl-3">
						<p class="text-muted-foreground text-xs" data-tabular>{[q.askedByLabel, when(q.createdAt)].filter(Boolean).join(' · ')}</p>
						<p class="font-medium [overflow-wrap:anywhere] whitespace-pre-wrap">{q.prompt}</p>
						{#if q.state === 'answered'}
							<p class="text-muted-foreground text-xs" data-tabular>{t('card.report.answeredBy', { when: when(q.answeredAt) })}</p>
							<p class="[overflow-wrap:anywhere] whitespace-pre-wrap">{q.answer}</p>
						{:else if q.state === 'withdrawn'}
							<p class="text-muted-foreground">{t('card.report.questionWithdrawn')}</p>
						{:else}
							<p class="text-muted-foreground">{t('card.report.questionOpen')}</p>
						{/if}
					</li>
				{/each}
			</ul>
		</section>
	{/if}

	{#if review}
		<section class="flex flex-col gap-1.5" data-testid="report-review">
			<h3 class={heading}>{t('card.report.review')}</h3>
			<div class="flex flex-col gap-1.5 rounded-xl border p-3">
				{#if review.state === 'pending'}
					<p class="text-muted-foreground">{t('card.report.reviewPending')}</p>
				{:else}
					<p class="font-medium">{t(review.state === 'accepted' ? 'card.review.accepted' : review.state === 'changes_requested' ? 'card.review.changes' : 'card.review.withdrawn')}</p>
					<p class="text-muted-foreground text-xs" data-tabular>{[review.requestedByLabel, when(review.decidedAt ?? review.createdAt)].filter(Boolean).join(' · ')}</p>
					{#if review.decisionNote}<p class="border-l-2 pl-2 [overflow-wrap:anywhere] whitespace-pre-wrap">{review.decisionNote}</p>{/if}
				{/if}
				{#if !report.completion}<Markdown text={review.summary} />{/if}
			</div>
		</section>
	{/if}
{/if}
