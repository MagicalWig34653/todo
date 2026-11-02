<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { can, roleOf } from '#lib/access.js';
	import { api, ApiError, type Attachment, type Question, type TaskContext } from '#lib/api.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { galleryOf, projectChain, relativeWhen, type CardRef } from '#lib/cardRef.js';
	import { percentOf } from '#lib/commandCenter.js';
	import { describeError } from '#lib/errors.js';
	import type { ActionRequest, ForYouConfirmation } from '#lib/forYou.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Check from '@lucide/svelte/icons/check';
	import Link2 from '@lucide/svelte/icons/link-2';
	import SquareArrowOutUpRight from '@lucide/svelte/icons/square-arrow-out-up-right';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import MenuItem from '../app/MenuItem.svelte';
	import ConfirmationCard from '../overview/ConfirmationCard.svelte';
	import QuestionAnswer from '../overview/QuestionAnswer.svelte';
	import ReviewDecision from '../overview/ReviewDecision.svelte';
	import TaskActivity from '../TaskActivity.svelte';
	import TaskAttachments from '../TaskAttachments.svelte';
	import TaskCriteria from '../TaskCriteria.svelte';
	import TaskDependencies from '../TaskDependencies.svelte';
	import TaskLabels from '../TaskLabels.svelte';
	import TaskPlanning from '../TaskPlanning.svelte';
	import CardConversation from './CardConversation.svelte';
	import CardHeader from './CardHeader.svelte';
	import CardSubtasks from './CardSubtasks.svelte';
	import ImageGallery from './ImageGallery.svelte';
	import InlineEdit from './InlineEdit.svelte';
	import Markdown from './Markdown.svelte';
	import SideSection from './SideSection.svelte';
	import TaskMilestone from './TaskMilestone.svelte';

	/**
	 * Content of the large card detail window for one card (task, question, review, confirmation): top bar, main column
	 * (title, description, subtasks, conversation, actions) and properties sidebar. On narrow screens the sidebar sits below
	 * the main column. Loads what is needed, refreshes live without touching drafts and shows a skeleton / error state.
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
	/** Bumped after every change so activity and attachments reload. */
	let rev = $state(0);
	let pickLabel = $state(false);
	let pickDependency = $state(false);
	let pickMilestone = $state(false);
	let confirmDelete = $state(false);
	let copied = $state(false);

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
		confirmDelete = false;
		pickLabel = pickDependency = pickMilestone = false;
		untrack(() => void load());
	});
	onMount(() => startLiveRefresh(() => load()));

	async function changed() {
		rev++;
		await load();
		await onchanged?.();
	}

	const ctx = $derived(data?.ctx ?? null);
	const task = $derived(ctx?.task ?? null);
	const request = $derived(decided ?? data?.request ?? null);
	const projectID = $derived(task?.projectID ?? ctx?.projectID ?? null);
	const project = $derived(projectID ? workspace.projects.find((p) => p.id === projectID) : null);
	const canEdit = $derived(project ? can(roleOf(project), 'addTask') : false);
	const management = $derived(projectID ? workspace.modeOf(projectID) === 'management' : false);
	const isTask = $derived(card.type === 'task');
	const openQuestions = $derived(ctx?.questions.filter((q) => q.state === 'open') ?? []);
	const answeredQuestions = $derived(ctx?.questions.filter((q) => q.state === 'answered') ?? []);
	const review = $derived(ctx?.review ?? null);
	const images = $derived(ctx ? galleryOf(ctx.builds, data?.attachments ?? [], api.attachmentPreviewURL) : []);
	const pathLabel = $derived(projectChain(workspace.projects, projectID, 2).map((p) => p.name).join(' / '));

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

	let statusBusy = $state(false);
	async function toggleDone() {
		if (!task || statusBusy || !canEdit) return;
		statusBusy = true;
		try {
			await attempt(async () => {
				await api.updateTask(task, { status: task.status === 'done' ? 'open' : 'done' });
				await changed();
				await workspace.reloadTasks();
			}, async () => { await changed(); });
		} finally {
			statusBusy = false;
		}
	}
	async function copyLink(close: () => void) {
		try {
			await navigator.clipboard.writeText(location.href);
			copied = true;
		} catch {
			copied = false;
		}
		setTimeout(() => {
			copied = false;
			close();
		}, 900);
	}
	async function deleteTask() {
		if (!task) return;
		const id = task.id;
		const ok = await attempt(async () => {
			await api.deleteTask(id);
			await workspace.reloadTasks();
		});
		if (ok) {
			confirmDelete = false;
			cardDetail.close();
			await onchanged?.();
		}
	}
</script>

<div class="flex min-h-0 min-w-0 flex-1 flex-col text-sm" data-testid="card-detail" data-card-type={card.type}>
	<CardHeader
		projectID={projectID}
		crumb={!isTask && task ? { label: task.title, onclick: () => onopentask(task.projectID, task.id) } : null}
		{onopenproject}
	>
		{#snippet menu(close)}
			<MenuItem testid="card-copy-link" onclick={() => copyLink(close)}><Link2 class="size-4" aria-hidden="true" />{copied ? t('card.linkCopied') : t('card.copyLink')}</MenuItem>
			{#if task}
				<MenuItem testid="card-menu-open-task" onclick={() => { close(); onopentask(task.projectID, task.id); }}><SquareArrowOutUpRight class="size-4" aria-hidden="true" />{t('card.openTask')}</MenuItem>
			{/if}
			{#if projectID}
				<MenuItem onclick={() => { close(); onopenproject(projectID); }}>{t('card.openProject')}</MenuItem>
			{/if}
			{#if task && isTask && canEdit}
				<MenuItem testid="card-menu-delete" danger onclick={() => { close(); confirmDelete = true; }}><Trash2 class="size-4" aria-hidden="true" />{t('card.deleteTask')}</MenuItem>
			{/if}
		{/snippet}
	</CardHeader>

	{#if error}
		<div class="flex flex-col items-start gap-3 p-5" role="alert" data-testid="card-error">
			<p class="text-destructive font-medium">{error.missing ? t('card.missing') : t('card.loadFailed')}</p>
			{#if !error.missing}<p class="text-muted-foreground">{error.text}</p>{/if}
			{#if !error.missing}<Button variant="outline" onclick={() => { error = null; void load(); }}>{t('common.retry')}</Button>{/if}
		</div>
	{:else if !data}
		<div class="flex h-72 flex-col gap-3 p-5 motion-safe:animate-pulse" role="status" aria-label={t('common.loading')} data-testid="card-skeleton">
			<div class="bg-muted h-6 w-1/3 rounded-lg"></div>
			<div class="bg-muted h-4 w-2/3 rounded-lg"></div>
			<div class="bg-muted h-32 w-full rounded-xl"></div>
			<div class="bg-muted h-4 w-1/2 rounded-lg"></div>
		</div>
	{:else}
		<div class="min-h-0 flex-1 overflow-y-auto overscroll-contain md:grid md:grid-cols-[minmax(0,1fr)_minmax(260px,300px)] md:overflow-hidden lg:grid-cols-[minmax(0,1fr)_320px]" data-testid="card-scroll">
			<!-- Main column -->
			<div class="flex min-w-0 flex-col gap-5 px-4 py-5 md:overflow-y-auto md:overscroll-contain md:px-8 md:py-6" data-testid="card-main">
				{#if confirmDelete && task}
					<div class="border-destructive/30 bg-destructive/5 flex flex-wrap items-center justify-between gap-2 rounded-xl border p-3" role="alert" data-testid="card-delete-confirm">
						<p class="min-w-0 font-medium [overflow-wrap:anywhere]">{t('card.deleteConfirm', { title: task.title })}</p>
						<span class="flex gap-2">
							<Button size="sm" variant="destructive" data-testid="card-delete-yes" onclick={deleteTask}>{t('common.delete')}</Button>
							<Button size="sm" variant="ghost" onclick={() => (confirmDelete = false)}>{t('common.cancel')}</Button>
						</span>
					</div>
				{/if}

				{#if task && isTask}
					<div class="flex items-start gap-3" data-testid="card-title-row">
						<button
							type="button"
							role="checkbox"
							aria-checked={task.status === 'done'}
							aria-label={task.status === 'done' ? t('tasks.reopen') : t('tasks.done')}
							disabled={statusBusy || !canEdit}
							data-testid="card-done"
							class={['hit-area relative mt-2 inline-flex size-6 shrink-0 items-center justify-center rounded-full border-2 transition-colors disabled:opacity-60', task.status === 'done' ? 'bg-success border-success text-white' : 'border-muted-foreground/60 hover:border-foreground']}
							onclick={toggleDone}
						>
							{#if task.status === 'done'}<Check class="size-3.5" aria-hidden="true" />{/if}
						</button>
						<div class="min-w-0 flex-1"><InlineEdit {task} field="title" editable={canEdit} onchanged={changed} /></div>
					</div>
				{:else}
					<div class="flex min-w-0 flex-col gap-1.5">
						<h2 class="text-2xl leading-tight font-semibold tracking-tight [overflow-wrap:anywhere] md:text-[1.7rem]" data-testid="card-title-static">{task?.title ?? request?.summary ?? title}</h2>
					</div>
				{/if}

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
							<CardConversation taskID={task.id} thread={{ questionID: data.question.id }} title={t('card.chat.question')} onchanged={() => onchanged?.()} onattached={changed} />
						</section>
					{/if}

					{#if openQuestions.length > 0 || (review && review.state === 'pending')}
						<section class="flex flex-col gap-3" data-testid="card-decide">
							{#each openQuestions as q (q.id)}
								<QuestionAnswer id={q.id} prompt={q.prompt} options={q.options} blocking={q.blocking} askedBy={q.askedByLabel} size="default" onanswered={changed} />
								<CardConversation taskID={task.id} thread={{ questionID: q.id }} title={t('card.chat.question')} onchanged={() => onchanged?.()} onattached={changed} />
							{/each}
							{#if review && review.state === 'pending'}
								<ReviewDecision taskID={task.id} summary={review.summary} requestedBy={review.requestedByLabel} markdown ondecided={changed} />
								<CardConversation taskID={task.id} thread={{ reviewID: review.id }} title={t('card.chat.review')} onchanged={() => onchanged?.()} onattached={changed} />
							{/if}
						</section>
					{/if}

					{#if review && review.state !== 'pending'}
						<section class="flex flex-col gap-2 rounded-xl border p-3" data-testid="card-review-result">
							<h3 class="font-semibold">{t(review.state === 'accepted' ? 'card.review.accepted' : review.state === 'changes_requested' ? 'card.review.changes' : 'card.review.withdrawn')}</h3>
							<p class="text-muted-foreground text-xs">{[review.requestedByLabel, when(review.decidedAt ?? review.createdAt)].filter(Boolean).join(' · ')}</p>
							<Markdown text={review.summary} />
							{#if review.decisionNote}<p class="border-l-2 pl-2 [overflow-wrap:anywhere] whitespace-pre-wrap" data-testid="review-note-shown">{review.decisionNote}</p>{/if}
							<CardConversation taskID={task.id} thread={{ reviewID: review.id }} title={t('card.chat.review')} onchanged={() => onchanged?.()} onattached={changed} />
						</section>
					{/if}

					{#if isTask}
						<InlineEdit {task} field="description" editable={canEdit} onchanged={changed} />
					{:else if task.description}
						<section class="flex flex-col gap-1.5">
							<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.description')}</h3>
							<div data-testid="card-description"><Markdown text={task.description} /></div>
						</section>
					{/if}

					{#if images.length > 0}
						<section class="flex flex-col gap-1.5">
							<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.images')}</h3>
							<ImageGallery {images} />
						</section>
					{/if}

					{#if isTask}
						<CardSubtasks {task} subtasks={ctx.subtasks} canAdd={canEdit && !ctx.workflow.parentTaskID} onchanged={changed} />
					{:else if ctx.subtasks.length > 0}
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

					{#if isTask && management}
						<section class="flex flex-col gap-1.5" aria-label={t('card.criteria')} data-testid="card-criteria">
							<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.criteria')}</h3>
							<TaskCriteria taskID={task.id} />
						</section>
					{/if}

					{#if isTask}
						<section class="flex flex-col gap-1.5" aria-label={t('card.attachments')} data-testid="card-attachments">
							<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.attachments')}</h3>
							{#key rev}<TaskAttachments taskID={task.id} onchanged={changed} />{/key}
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

					<div class="border-t pt-5">
						<CardConversation taskID={task.id} onchanged={() => onchanged?.()} onattached={changed} />
					</div>

					{#if isTask && management}
						<section class="flex flex-col gap-1.5" aria-label={t('card.activity')} data-testid="card-activity">
							<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('card.activity')}</h3>
							<TaskActivity taskID={task.id} refreshKey={rev} />
						</section>
					{/if}
				{/if}
			</div>

			<!-- Properties sidebar -->
			<aside class="bg-muted/50 flex min-w-0 flex-col border-t px-4 py-2 md:overflow-y-auto md:overscroll-contain md:border-t-0 md:border-l md:px-5" aria-label={t('card.sidebar')} data-testid="card-side">
				{#if isTask && task}
					<SideSection title={t('card.side.project')} testid="side-project">
						{#if projectID}
							<button type="button" class="hover:bg-muted -mx-1.5 flex min-h-8 min-w-0 items-center gap-2 rounded-lg px-1.5 text-left" data-testid="side-project-link" aria-label={t('card.side.openProject', { name: pathLabel || (project?.name ?? '') })} onclick={() => onopenproject(projectID)}>
								<span class="shrink-0 font-semibold" style:color={workspace.colorOf(projectID)} aria-hidden="true">#</span>
								<span class="min-w-0 [overflow-wrap:anywhere]">{pathLabel || project?.name || t('card.project')}</span>
							</button>
						{/if}
					</SideSection>
					<TaskPlanning taskID={task.id} side onsaved={changed}>
						{#snippet between()}
							<SideSection title={t('card.side.labels')} addLabel={t('card.side.labelsAdd')} onadd={() => (pickLabel = !pickLabel)} active={pickLabel} testid="side-labels">
								<TaskLabels taskID={task.id} compact showPicker={pickLabel} />
							</SideSection>
						{/snippet}
					</TaskPlanning>
					{#if management}
						<SideSection title={t('card.side.dependencies')} addLabel={t('card.side.dependenciesAdd')} onadd={() => (pickDependency = !pickDependency)} active={pickDependency} testid="side-dependencies">
							<TaskDependencies {task} compact adding={pickDependency} onchanged={changed} />
						</SideSection>
						<SideSection title={t('card.side.milestone')} addLabel={t('card.side.milestoneAdd')} onadd={() => (pickMilestone = !pickMilestone)} active={pickMilestone} testid="side-milestone">
							<TaskMilestone taskID={task.id} projectID={task.projectID} adding={pickMilestone} onchanged={changed} />
						</SideSection>
					{/if}
				{/if}

				<SideSection title={t('card.side.meta')} testid="side-meta">
					<dl class="grid grid-cols-[auto_1fr] items-center gap-x-4 gap-y-1.5">
						<dt class="text-muted-foreground">{t('card.side.type')}</dt>
						<dd><Badge variant="accent" data-testid="card-type">{typeLabel}</Badge></dd>
						{#if task}
							<dt class="text-muted-foreground">{t('card.side.status')}</dt>
							<dd data-testid="card-status">{t(`status.${task.status}` as MessageKey)}</dd>
						{/if}
						{#if who}
							<dt class="text-muted-foreground">{t('card.side.who')}</dt>
							<dd class="[overflow-wrap:anywhere]" data-testid="card-who">{who}</dd>
						{/if}
						{#if at}
							<dt class="text-muted-foreground">{t('card.side.time')}</dt>
							<dd data-tabular data-testid="card-time">{when(at)}</dd>
						{/if}
					</dl>
					{#if ctx}
						<div class="flex items-center gap-2" data-testid="card-progress">
							<div class="bg-muted h-1.5 flex-1 overflow-hidden rounded-full" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent} aria-label={t('cc.card.progress', { percent })}>
								<div class="bg-ui-accent h-full rounded-full" style:width="{percent}%"></div>
							</div>
							<span class="text-xs font-medium" data-tabular>{percent} %</span>
						</div>
					{/if}
				</SideSection>

				{#if !isTask && projectID}
					<SideSection title={t('card.side.project')} testid="side-project">
						<button type="button" class="hover:bg-muted -mx-1.5 flex min-h-8 min-w-0 items-center gap-2 rounded-lg px-1.5 text-left" data-testid="side-project-link" onclick={() => onopenproject(projectID)}>
							<span class="shrink-0 font-semibold" style:color={workspace.colorOf(projectID)} aria-hidden="true">#</span>
							<span class="min-w-0 [overflow-wrap:anywhere]">{pathLabel || project?.name || t('card.project')}</span>
						</button>
					</SideSection>
					{#if images.length > 0}
						<SideSection title={t('card.side.attachments')} testid="side-attachments">
							<ul class="flex flex-wrap gap-2">
								{#each images as img (img.id)}
									<li><a href={img.url} target="_blank" rel="noopener" class="block"><img src={img.url} alt={img.label} class="size-14 rounded-lg border object-cover" loading="lazy" /></a></li>
								{/each}
							</ul>
						</SideSection>
					{/if}
				{/if}

				{#if task}
					<div class="py-3">
						<Button variant="outline" size="sm" class="w-full" data-testid="card-open-task" onclick={() => onopentask(task.projectID, task.id)}>{t('card.openTask')}</Button>
					</div>
				{/if}
			</aside>
		</div>
	{/if}
</div>
