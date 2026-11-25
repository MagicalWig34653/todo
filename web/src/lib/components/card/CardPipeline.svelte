<script lang="ts">
	import { tick, type Component } from 'svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import CircleMinus from '@lucide/svelte/icons/circle-minus';
	import CircleX from '@lucide/svelte/icons/circle-x';
	import Hourglass from '@lucide/svelte/icons/hourglass';
	import LoaderCircle from '@lucide/svelte/icons/loader-circle';
	import MessageSquareWarning from '@lucide/svelte/icons/message-square-warning';
	import { t } from '#lib/i18n/index.js';
	import {
		PLAN_COMMENT_MAX,
		canDecide,
		eventText,
		isEmptyPipeline,
		orderedSteps,
		planStateKey,
		stepNameKey,
		stepStateKey,
		type PipelineController,
		type PipelineStepState,
		type PipelineView,
		type PlanDecision,
		type PlanState
	} from '#lib/pipeline.js';
	import { Badge, type BadgeVariant } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import Timestamp from '../Timestamp.svelte';
	import CardTabEmpty from './CardTabEmpty.svelte';
	import Markdown from './Markdown.svelte';

	/**
	 * "Pipeline" tab: the six steps with their state, the plan with its decision and a compact history. Agent texts are
	 * shown as text or through the safe Markdown subset. `canEdit` only hides the decision; the server checks the right.
	 */
	interface Props {
		view: PipelineView;
		controller: PipelineController;
		canEdit: boolean;
		ondecided: () => void | Promise<void>;
	}
	let { view, controller, canEdit, ondecided }: Props = $props();

	const data = $derived(view.data);
	const plan = $derived(data?.plan ?? null);

	const stepLook: Record<PipelineStepState, { icon: Component<{ class?: string; 'aria-hidden'?: 'true' }>; color: string; badge: BadgeVariant }> = {
		pending: { icon: Circle, color: 'text-muted-foreground', badge: 'default' },
		running: { icon: LoaderCircle, color: 'text-ui-accent', badge: 'accent' },
		waiting: { icon: Hourglass, color: 'text-warning', badge: 'warning' },
		changes_requested: { icon: MessageSquareWarning, color: 'text-warning', badge: 'warning' },
		done: { icon: CircleCheck, color: 'text-success', badge: 'success' },
		failed: { icon: CircleX, color: 'text-destructive', badge: 'destructive' },
		skipped: { icon: CircleMinus, color: 'text-muted-foreground', badge: 'outline' }
	};
	const planBadge: Record<PlanState, BadgeVariant> = { proposed: 'warning', approved: 'success', changes_requested: 'warning' };

	let decisionArea = $state<HTMLDivElement | null>(null);
	let feedback = $state<HTMLParagraphElement | null>(null);
	let confirmButton = $state<HTMLElement | null>(null);

	/** Without a decision: the confirmation of the one offered for a new plan version. */
	async function decide(decision?: PlanDecision) {
		const area = decisionArea;
		const outcome = await (decision ? controller.decide(decision, canEdit) : controller.confirm(canEdit));
		if (outcome === 'ignored') return;
		await tick();
		if (outcome === 'unread') {
			// Focus on the message, not on the confirmation: pressing Enter twice must not send.
			feedback?.focus();
			confirmButton?.scrollIntoView({ block: 'nearest' });
		} else if (outcome === 'invalid') area?.querySelector('textarea')?.focus();
		// The buttons are gone after a decision: keep the focus inside the window, on the message that says what happened.
		else if (!area?.isConnected) feedback?.focus();
		if (outcome === 'done') await ondecided();
	}

	const heading = 'text-muted-foreground text-xs font-semibold tracking-wide uppercase';
	const prose = '[overflow-wrap:anywhere] whitespace-pre-wrap';
</script>

<div class="flex min-w-0 flex-col gap-5" data-testid="card-pipeline">
	{#if view.status === 'loading'}
		<p class="text-muted-foreground min-h-16 text-xs" role="status">{t('pipeline.loading')}</p>
	{:else if view.status === 'failed'}
		<div class="flex flex-wrap items-center gap-2" role="alert" data-testid="pipeline-error">
			<span>{t('pipeline.loadFailed')}</span>
			<Button size="sm" variant="outline" onclick={() => void controller.retry()}>{t('common.retry')}</Button>
		</div>
	{:else if !data || isEmptyPipeline(data)}
		<CardTabEmpty title={t('card.tab.pipeline.emptyTitle')} text={t('card.tab.pipeline.emptyText')} />
	{:else}
		<section class="flex flex-col gap-1.5">
			<h3 class={heading}>{t('pipeline.steps')}</h3>
			<ol class="flex flex-col divide-y rounded-xl border" aria-label={t('pipeline.steps')}>
				{#each orderedSteps(data) as s (s.step)}
					{@const look = stepLook[s.state] ?? stepLook.pending}
					<li class="flex min-w-0 gap-3 px-3 py-2.5" data-testid="pipeline-step" data-step={s.step} data-state={s.state}>
						<look.icon class="mt-0.5 size-4 shrink-0 {look.color}" aria-hidden="true" />
						<div class="flex min-w-0 flex-1 flex-col gap-0.5">
							<div class="flex flex-wrap items-center justify-between gap-x-2 gap-y-1">
								<span class="font-medium">{t(stepNameKey(s.step))}</span>
								<Badge variant={look.badge} data-testid="pipeline-step-state">{t(stepStateKey(s.state))}</Badge>
							</div>
							{#if s.note}<p class={prose}>{s.note}</p>{/if}
							{#if s.actorLabel || s.updatedAt}
								<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-tabular>{s.actorLabel ?? ''}{#if s.actorLabel && s.updatedAt}{' · '}{/if}<Timestamp value={s.updatedAt} /></p>
							{/if}
						</div>
					</li>
				{/each}
			</ol>
		</section>

		{#if plan}
			<section class="flex min-w-0 flex-col gap-2" aria-labelledby="card-plan-title" data-testid="pipeline-plan">
				<div class="flex flex-wrap items-center gap-2">
					<h3 class={heading} id="card-plan-title">{t('pipeline.plan')}</h3>
					<Badge variant={planBadge[plan.state] ?? 'default'} data-testid="pipeline-plan-state">{t(planStateKey(plan.state))}</Badge>
				</div>
				<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-tabular>
					{t('pipeline.version', { version: plan.version })}{plan.authorLabel ? ` · ${t('pipeline.by', { who: plan.authorLabel })}` : ''}{#if plan.writtenAt}{' · '}{t('pipeline.written')}{' '}<Timestamp value={plan.writtenAt} />{/if}
				</p>
				<div class="bg-card rounded-xl border p-3" data-testid="pipeline-plan-body">
					<Markdown text={plan.body} ordered />
				</div>

				{#if plan.state !== 'proposed'}
					<div class="flex flex-col gap-1" data-testid="pipeline-plan-decided">
						<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-tabular>
							{t(plan.state === 'approved' ? 'pipeline.approvedBy' : 'pipeline.changesBy', { who: plan.decidedByLabel || t('cc.update.anonymous') })}{#if plan.decidedAt}{' · '}<Timestamp value={plan.decidedAt} />{/if}
						</p>
						{#if plan.decisionComment}<p class="border-l-2 pl-2 {prose}">{plan.decisionComment}</p>{/if}
					</div>
				{/if}

				{#if canDecide(data, canEdit)}
					<div class="flex flex-col gap-2" bind:this={decisionArea} data-testid="pipeline-decision">
						<label class="font-medium" for="card-plan-comment">{t('pipeline.comment')}</label>
						<Textarea
							id="card-plan-comment"
							rows={3}
							maxlength={PLAN_COMMENT_MAX}
							value={view.comment}
							oninput={(e) => controller.type(e.currentTarget.value)}
							aria-invalid={view.problem ? 'true' : undefined}
							aria-describedby={view.problem ? 'card-plan-problem card-plan-comment-hint' : 'card-plan-comment-hint'}
						/>
						<p class="text-muted-foreground text-xs" id="card-plan-comment-hint">{t('pipeline.commentHint')}</p>
						{#if view.problem}
							<p class="text-destructive text-xs font-medium" role="alert" id="card-plan-problem">{t(view.problem === 'comment_required' ? 'pipeline.error.commentRequired' : 'pipeline.error.invalidComment')}</p>
						{/if}
						<!-- aria-disabled instead of disabled: the focus stays on the button while sending; the controller ignores repeats. -->
						<div class="flex flex-wrap gap-2">
							<Button class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={view.busy !== null} onclick={() => decide('approve')}>{view.busy === 'approve' ? t('pipeline.sending') : t('pipeline.approve')}</Button>
							<Button variant="outline" class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={view.busy !== null} onclick={() => decide('request_changes')}>{view.busy === 'request_changes' ? t('pipeline.sending') : t('pipeline.changes')}</Button>
						</div>
					</div>
				{:else if plan.state === 'proposed'}
					<p class="text-muted-foreground text-xs" data-testid="pipeline-read-only">{t('pipeline.readOnly')}</p>
				{/if}
			</section>
		{/if}

		<!-- Always present, so screen readers announce what appears in it. -->
		<p
			bind:this={feedback}
			role="status"
			aria-live="polite"
			tabindex="-1"
			class={['focus-visible:ring-ring/60 -mt-3 rounded-lg font-medium [overflow-wrap:anywhere] outline-none empty:-mt-5 focus-visible:ring-2', view.feedback?.tone === 'error' ? 'text-destructive' : view.feedback?.tone === 'success' ? 'text-success' : 'text-foreground']}
			data-testid="pipeline-feedback"
		>{view.feedback ? t(view.feedback.key, view.feedback.params) : ''}</p>

		<!-- Below the message, so nothing moves under the pointer; the second click of a double click is ignored. -->
		{#if view.confirm && plan && canDecide(data, canEdit)}
			<div class="-mt-3 flex" bind:this={confirmButton}>
				<Button class="h-auto min-h-9 whitespace-normal max-sm:w-full aria-disabled:opacity-60" aria-disabled={view.busy !== null} data-testid="pipeline-confirm" onclick={(e: MouseEvent) => { if (e.detail <= 1) void decide(); }}>
					{view.busy ? t('pipeline.sending') : t(view.confirm === 'approve' ? 'pipeline.confirm.approve' : 'pipeline.confirm.changes', { version: plan.version })}
				</Button>
			</div>
		{/if}

		{#if data.events.length > 0}
			<details class="min-w-0" data-testid="pipeline-history">
				<summary class="text-muted-foreground hover:text-foreground focus-visible:ring-ring/60 min-h-9 cursor-pointer rounded-md py-1.5 text-xs font-semibold tracking-wide uppercase outline-none select-none focus-visible:ring-2">{t('pipeline.history', { count: data.events.length })}</summary>
				<ol class="mt-1 flex flex-col gap-2 border-l pl-3">
					{#each data.events as e (e.id)}
						<li class="min-w-0" data-testid="pipeline-event">
							<p class="[overflow-wrap:anywhere]">{eventText(e)}</p>
							{#if e.note}<p class="text-muted-foreground {prose}">{e.note}</p>{/if}
							<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-tabular>{e.actorLabel || t('cc.update.anonymous')}{#if e.createdAt}{' · '}<Timestamp value={e.createdAt} />{/if}</p>
						</li>
					{/each}
				</ol>
			</details>
		{/if}
	{/if}
</div>
