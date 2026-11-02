<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { api, ApiError, type Attachment, type Question, type TaskContext } from '#lib/api.js';
	import { galleryOf, relativeWhen, type CardRef } from '#lib/cardRef.js';
	import { percentOf } from '#lib/commandCenter.js';
	import { describeError } from '#lib/errors.js';
	import type { ActionRequest, ForYouConfirmation } from '#lib/forYou.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ConfirmationCard from '../overview/ConfirmationCard.svelte';
	import QuestionAnswer from '../overview/QuestionAnswer.svelte';
	import ReviewDecision from '../overview/ReviewDecision.svelte';
	import TaskDetail from '../TaskDetail.svelte';
	import CardConversation from './CardConversation.svelte';
	import ImageGallery from './ImageGallery.svelte';
	import Markdown from './Markdown.svelte';

	/**
	 * Content of the large card detail window for one card (task, question, review, confirmation).
	 * Loads what is needed (task context, attachments), refreshes live without touching drafts and shows a skeleton / error state.
	 */
	interface Props {
		card: CardRef;
		/** Window title: the task title, or the summary of a confirmation. */
		title: string;
		onopentask: (projectID: string, taskID: string) => void;
		onopenproject: (projectID: string) => void;
		/** The data changed (answered, decided, edited): lists behind the window reload. */
		onchanged?: () => void | Promise<void>;
	}
	let { card, title = $bindable(''), onopentask, onopenproject, onchanged }: Props = $props();

	interface Loaded {
		ctx: TaskContext | null;
		question: Question | null;
		request: ActionRequest | null;
		attachments: Attachment[];
	}
	let data = $state<Loaded | null>(null);
	let error = $state<{ text: string; missing: boolean } | null>(null);
	let decided = $state<ActionRequest | null>(null);
	let seq = 0;

	async function fetchAll(c: CardRef): Promise<Loaded> {
		if (c.type === 'confirmation') return { ctx: null, question: null, request: await api.actionRequest(c.id), attachments: [] };
		let taskID = c.id;
		let question: Question | null = null;
		if (c.type === 'question') {
			question = await api.question(c.id);
			taskID = question.taskID;
		}
		const [ctx, attachments] = await Promise.all([api.taskContext(taskID), api.listAttachments(taskID).catch(() => [] as Attachment[])]);
		if (question) question = ctx.questions.find((q) => q.id === question!.id) ?? question;
		return { ctx, question, request: null, attachments };
	}
	async function load() {
		const my = ++seq;
		const c = card;
		try {
			const next = await fetchAll(c);
			if (my !== seq) return;
			// Assign only on a real change: an identical live refresh must not re-render fields people are typing into.
			if (JSON.stringify(next) !== JSON.stringify(untrack(() => data))) data = next;
			error = null;
		} catch (e) {
			if (my !== seq) return;
			if (untrack(() => data) === null) error = { text: describeError(e), missing: e instanceof ApiError && (e.status === 404 || e.status === 403) };
		}
	}
	$effect(() => {
		void card.type;
		void card.id;
		data = null;
		error = null;
		decided = null;
		untrack(() => void load());
	});
	onMount(() => startLiveRefresh(() => load()));

	async function changed() {
		await load();
		await onchanged?.();
	}

	const ctx = $derived(data?.ctx ?? null);
	const task = $derived(ctx?.task ?? null);
	const request = $derived(decided ?? data?.request ?? null);
	const projectID = $derived(task?.projectID ?? ctx?.projectID ?? null);
	const project = $derived(projectID ? workspace.projects.find((p) => p.id === projectID) : null);
	const openQuestions = $derived(ctx?.questions.filter((q) => q.state === 'open') ?? []);
	const answeredQuestions = $derived(ctx?.questions.filter((q) => q.state === 'answered') ?? []);
	const review = $derived(ctx?.review ?? null);
	const images = $derived(ctx ? galleryOf(ctx.builds, data?.attachments ?? [], api.attachmentPreviewURL) : []);

	$effect(() => {
		const next = task?.title ?? request?.summary ?? '';
		if (next && next !== title) title = next;
	});

	const confirmation = $derived<ForYouConfirmation | null>(
		request ? { id: request.id, tool: request.tool, summary: request.summary, impact: request.impact, agentLabel: request.agentLabel, createdAt: request.createdAt, expiresAt: request.expiresAt, confirmPath: '', rejectPath: '' } : null
	);
	const typeLabel = $derived(
		card.type === 'question' ? t('card.type.question') : card.type === 'review' ? t('card.type.review') : card.type === 'confirmation' ? t('card.type.confirmation') : ctx?.workflow.isFeature ? t('card.type.feature') : t('card.type.task')
	);
	const who = $derived(
		card.type === 'question'
			? data?.question?.askedByLabel
			: card.type === 'review'
				? review?.requestedByLabel
				: card.type === 'confirmation'
					? request?.agentLabel
					: ctx?.workflow.claimedLabel
	);
	const at = $derived(
		card.type === 'question'
			? data?.question?.createdAt
			: card.type === 'review'
				? review?.createdAt
				: card.type === 'confirmation'
					? request?.createdAt
					: ctx?.progressNotes[0]?.createdAt
	);
	const percent = $derived(ctx ? percentOf(ctx.progress) : 0);
	const impact = $derived(request?.impact ?? null);
	const when = (iso?: string | null) => [relativeWhen(iso), formatWhen(iso)].filter(Boolean).join(' · ');
</script>

<div class="flex min-w-0 flex-col gap-5 text-sm" data-testid="card-detail" data-card-type={card.type}>
	{#if error}
		<div class="flex flex-col items-start gap-3" role="alert" data-testid="card-error">
			<p class="text-destructive font-medium">{error.missing ? t('card.missing') : t('card.loadFailed')}</p>
			{#if !error.missing}<p class="text-muted-foreground">{error.text}</p>{/if}
			{#if !error.missing}<Button variant="outline" onclick={() => { error = null; void load(); }}>{t('common.retry')}</Button>{/if}
		</div>
	{:else if !data}
		<div class="flex h-72 flex-col gap-3 motion-safe:animate-pulse" role="status" aria-label={t('common.loading')} data-testid="card-skeleton">
			<div class="bg-muted h-6 w-1/3 rounded-lg"></div>
			<div class="bg-muted h-4 w-2/3 rounded-lg"></div>
			<div class="bg-muted h-32 w-full rounded-xl"></div>
			<div class="bg-muted h-4 w-1/2 rounded-lg"></div>
		</div>
	{:else}
		<header class="flex min-w-0 flex-col gap-2" data-testid="card-header">
			<div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-xs">
				<Badge variant="accent" data-testid="card-type">{typeLabel}</Badge>
				{#if task}<span class="text-muted-foreground" data-testid="card-status">{t(`status.${task.status}` as MessageKey)}</span>{/if}
				{#if projectID}
					<button type="button" class="text-muted-foreground hover:text-foreground inline-flex min-h-8 items-center gap-1.5 underline-offset-2 hover:underline" data-testid="card-project" onclick={() => onopenproject(projectID)}>
						<span class="size-2 shrink-0 rounded-full" style:background-color={workspace.colorOf(projectID)} aria-hidden="true"></span>{project?.name ?? t('card.project')}
					</button>
				{/if}
				{#if who}<span class="text-muted-foreground" data-testid="card-who">{who}</span>{/if}
				{#if at}<span class="text-muted-foreground" data-tabular data-testid="card-time">{when(at)}</span>{/if}
			</div>
			{#if ctx}
				<div class="flex items-center gap-2" data-testid="card-progress">
					<div class="bg-muted h-1.5 flex-1 overflow-hidden rounded-full" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent} aria-label={t('cc.card.progress', { percent })}>
						<div class="bg-ui-accent h-full rounded-full" style:width="{percent}%"></div>
					</div>
					<span class="text-xs font-medium" data-tabular>{percent} %</span>
				</div>
			{/if}
		</header>

		{#if card.type === 'confirmation' && confirmation && request}
			<section class="flex flex-col gap-3" data-testid="card-confirmation">
				<ConfirmationCard item={confirmation} outcome={request.state === 'pending' ? null : request} ondecided={(_, result) => { decided = result; void onchanged?.(); }} />
				{#if impact}
					<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm" data-testid="confirm-scope">
						<dt class="text-muted-foreground">{t('card.impact.target')}</dt><dd class="[overflow-wrap:anywhere]">{impact.targetName}</dd>
						{#if impact.targetType === 'project'}
							<dt class="text-muted-foreground">{t('card.impact.subprojects')}</dt><dd data-tabular>{impact.subprojects}</dd>
						{/if}
						<dt class="text-muted-foreground">{t('card.impact.tasks')}</dt><dd data-tabular>{impact.tasks}</dd>
						{#if impact.newOwnerName}<dt class="text-muted-foreground">{t('card.impact.newOwner')}</dt><dd>{impact.newOwnerName}</dd>{/if}
						<dt class="text-muted-foreground">{t('card.impact.expires')}</dt><dd>{formatWhen(request.expiresAt)}</dd>
					</dl>
				{/if}
			</section>
		{/if}

		{#if ctx && task}
			{#if card.type === 'question' && data.question && data.question.state !== 'open'}
				<section class="bg-muted/40 flex flex-col gap-2 rounded-xl border p-3" data-testid="card-answer">
					<p class="font-medium [overflow-wrap:anywhere] whitespace-pre-wrap" data-testid="question-prompt">{data.question.prompt}</p>
					{#if data.question.state === 'answered'}
						<p class="text-muted-foreground text-xs">{t('card.answered', { when: when(data.question.answeredAt) })}</p>
						<p class="[overflow-wrap:anywhere] whitespace-pre-wrap" data-testid="question-answered">{data.question.answer}</p>
					{:else}
						<p class="text-muted-foreground">{t('card.withdrawn')}</p>
					{/if}
				</section>
			{/if}

			{#if openQuestions.length > 0 || (review && review.state === 'pending')}
				<section class="flex flex-col gap-3" data-testid="card-decide">
					{#each openQuestions as q (q.id)}
						<QuestionAnswer id={q.id} prompt={q.prompt} options={q.options} blocking={q.blocking} askedBy={q.askedByLabel} size="default" onanswered={changed} />
					{/each}
					{#if review && review.state === 'pending'}
						<ReviewDecision taskID={task.id} summary={review.summary} requestedBy={review.requestedByLabel} markdown ondecided={changed} />
					{/if}
				</section>
			{/if}

			{#if review && review.state !== 'pending'}
				<section class="flex flex-col gap-2 rounded-xl border p-3" data-testid="card-review-result">
					<h3 class="font-semibold">{t(review.state === 'accepted' ? 'card.review.accepted' : review.state === 'changes_requested' ? 'card.review.changes' : 'card.review.withdrawn')}</h3>
					<p class="text-muted-foreground text-xs">{[review.requestedByLabel, when(review.decidedAt ?? review.createdAt)].filter(Boolean).join(' · ')}</p>
					<Markdown text={review.summary} />
					{#if review.decisionNote}<p class="border-l-2 pl-2 [overflow-wrap:anywhere] whitespace-pre-wrap" data-testid="review-note-shown">{review.decisionNote}</p>{/if}
				</section>
			{/if}

			{#if task.description}
				<section class="flex flex-col gap-1.5">
					<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.description')}</h3>
					<p class="[overflow-wrap:anywhere] whitespace-pre-wrap" data-testid="card-description">{task.description}</p>
				</section>
			{/if}

			{#if images.length > 0}
				<section class="flex flex-col gap-1.5">
					<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.images')}</h3>
					<ImageGallery {images} />
				</section>
			{/if}

			<section class="flex flex-col gap-1.5">
				<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('cc.detail.notes')}</h3>
				{#if ctx.progressNotes.length === 0}
					<p class="text-muted-foreground">{t('cc.detail.notesEmpty')}</p>
				{:else}
					<ol class="flex flex-col gap-3 border-l pl-4" data-testid="detail-notes">
						{#each ctx.progressNotes as n (n.id)}
							<li class="relative">
								<span class="bg-ui-accent absolute top-1.5 -left-[1.28rem] size-2 rounded-full" aria-hidden="true"></span>
								<p class="text-muted-foreground text-xs" data-tabular>{n.actorLabel || t('cc.update.anonymous')} · {when(n.createdAt)}{n.percent != null ? ` · ${n.percent} %` : ''}</p>
								<p class="[overflow-wrap:anywhere] whitespace-pre-wrap">{n.note}</p>
							</li>
						{/each}
					</ol>
				{/if}
			</section>

			{#if answeredQuestions.length > 0 && card.type !== 'question'}
				<section class="flex flex-col gap-1.5">
					<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('cc.detail.questions')}</h3>
					<ul class="flex flex-col gap-2">
						{#each answeredQuestions as q (q.id)}
							<li class="border-l-2 pl-2"><p class="font-medium [overflow-wrap:anywhere] whitespace-pre-wrap">{q.prompt}</p><p class="text-muted-foreground [overflow-wrap:anywhere] whitespace-pre-wrap">{q.answer}</p></li>
						{/each}
					</ul>
				</section>
			{/if}

			{#if ctx.subtasks.length > 0}
				<section class="flex flex-col gap-1.5">
					<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('cc.detail.subtasks')}</h3>
					<ul class="flex flex-col gap-1">
						{#each ctx.subtasks as s (s.id)}
							<li class={['flex items-center gap-2', s.status === 'done' && 'text-muted-foreground line-through']}>
								<span class={['size-1.5 shrink-0 rounded-full', s.status === 'done' ? 'bg-success' : 'bg-muted-foreground/50']} aria-hidden="true"></span>{s.title}
							</li>
						{/each}
					</ul>
				</section>
			{/if}

			<div>
				<Button variant="outline" data-testid="card-open-task" onclick={() => onopentask(task.projectID, task.id)}>{t('card.openTask')}</Button>
			</div>

			<section class="flex flex-col gap-2" aria-label={t('card.details')}>
				<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.details')}</h3>
				<TaskDetail {task} standalone comments={false} onplanned={changed} />
			</section>

			<CardConversation taskID={task.id} onchanged={() => onchanged?.()} />
		{/if}
	{/if}
</div>
