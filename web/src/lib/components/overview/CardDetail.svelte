<script lang="ts">
	import { api, type TaskContext } from '#lib/api.js';
	import { percentOf } from '#lib/commandCenter.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import { formatWhen } from '#lib/planning.js';
	import QuestionAnswer from './QuestionAnswer.svelte';
	import ReviewDecision from './ReviewDecision.svelte';

	/** Full context of one task (progress notes, subtasks, questions, review, builds) for the detail dialog. */
	interface Props {
		taskID: string;
		/** Reload the overview after a question was answered or a review decided. */
		onchanged: () => void | Promise<void>;
	}
	let { taskID, onchanged }: Props = $props();

	let ctx = $state<TaskContext | null>(null);
	let error = $state('');
	let seq = 0;

	async function load() {
		const my = ++seq;
		try {
			const c = await api.taskContext(taskID);
			if (my === seq) {
				ctx = c;
				error = '';
			}
		} catch (e) {
			if (my === seq) error = describeError(e);
		}
	}
	$effect(() => {
		void taskID;
		ctx = null;
		load();
	});
	async function changed() {
		await load();
		await onchanged();
	}
	const open = $derived(ctx?.questions.filter((q) => q.state === 'open') ?? []);
	const answered = $derived(ctx?.questions.filter((q) => q.state === 'answered') ?? []);
</script>

<div class="flex flex-col gap-4 text-sm" data-testid="card-detail">
	{#if error}<p class="text-destructive" role="alert">{t('cc.detail.loadFailed')} {error}</p>{/if}
	{#if !ctx && !error}<p class="text-muted-foreground">{t('common.loading')}</p>{/if}
	{#if ctx}
		<p class="text-muted-foreground text-xs" data-tabular>{percentOf(ctx.progress)} %</p>
		{#if ctx.task.description}<p class="break-words whitespace-pre-wrap">{ctx.task.description}</p>{/if}

		{#if open.length > 0 || ctx.review}
			<section class="flex flex-col gap-2">
				{#each open as q (q.id)}
					<QuestionAnswer id={q.id} prompt={q.prompt} options={q.options} blocking={q.blocking} askedBy={q.askedByLabel} onanswered={changed} />
				{/each}
				{#if ctx.review && ctx.review.state === 'pending'}
					<ReviewDecision taskID={ctx.task.id} summary={ctx.review.summary} requestedBy={ctx.review.requestedByLabel} ondecided={changed} />
				{/if}
			</section>
		{/if}

		{#if ctx.builds.length > 0}
			<section>
				<h4 class="mb-1.5 font-semibold">{t('cc.detail.builds')}</h4>
				<div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
					{#each ctx.builds as b (b.id)}
						<a href={b.previewURL} target="_blank" rel="noopener" class="bg-muted block overflow-hidden rounded-lg border" title={t('cc.detail.buildOpen')}>
							<img src={b.previewURL} alt={t('cc.card.buildAlt', { label: b.label || b.filename })} loading="lazy" class="aspect-video w-full object-cover object-top" />
						</a>
					{/each}
				</div>
			</section>
		{/if}

		{#if ctx.subtasks.length > 0}
			<section>
				<h4 class="mb-1.5 font-semibold">{t('cc.detail.subtasks')}</h4>
				<ul class="flex flex-col gap-1">
					{#each ctx.subtasks as s (s.id)}
						<li class={['flex items-center gap-2', s.status === 'done' && 'text-muted-foreground line-through']}>
							<span class={['size-1.5 rounded-full', s.status === 'done' ? 'bg-success' : 'bg-muted-foreground/50']} aria-hidden="true"></span>{s.title}
						</li>
					{/each}
				</ul>
			</section>
		{/if}

		<section>
			<h4 class="mb-1.5 font-semibold">{t('cc.detail.notes')}</h4>
			{#if ctx.progressNotes.length === 0}
				<p class="text-muted-foreground">{t('cc.detail.notesEmpty')}</p>
			{:else}
				<ul class="flex flex-col gap-2" data-testid="detail-notes">
					{#each ctx.progressNotes as n (n.id)}
						<li class="border-l-2 pl-2">
							<p class="text-muted-foreground text-xs">{n.actorLabel || t('cc.update.anonymous')}, {formatWhen(n.createdAt)}{n.percent != null ? ` · ${n.percent} %` : ''}</p>
							<p class="break-words whitespace-pre-wrap">{n.note}</p>
						</li>
					{/each}
				</ul>
			{/if}
		</section>

		{#if answered.length > 0}
			<section>
				<h4 class="mb-1.5 font-semibold">{t('cc.detail.questions')}</h4>
				<ul class="flex flex-col gap-2">
					{#each answered as q (q.id)}
						<li class="border-l-2 pl-2"><p class="font-medium">{q.prompt}</p><p class="text-muted-foreground">{q.answer}</p></li>
					{/each}
				</ul>
			</section>
		{/if}
	{/if}
</div>
