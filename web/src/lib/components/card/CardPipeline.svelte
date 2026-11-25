<script lang="ts">
	import { tick, type Component } from 'svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import CircleMinus from '@lucide/svelte/icons/circle-minus';
	import CircleX from '@lucide/svelte/icons/circle-x';
	import Hourglass from '@lucide/svelte/icons/hourglass';
	import LoaderCircle from '@lucide/svelte/icons/loader-circle';
	import MessageSquareWarning from '@lucide/svelte/icons/message-square-warning';
	import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
	import { t } from '#lib/i18n/index.js';
	import {
		PLAN_COMMENT_MAX,
		canDecide,
		effortKey,
		eventActor,
		eventText,
		isEmptyPipeline,
		offSteps,
		orderedSteps,
		planStateKey,
		retryOffer,
		roleLine,
		stepCounts,
		stepNameKey,
		stepOn,
		stepStateKey,
		type PipelineController,
		type PipelineStepName,
		type PipelineStepState,
		type PipelineView,
		type PlanDecision,
		type PlanState
	} from '#lib/pipeline.js';
	import { executionSection, liveStep, retryHintKey } from '#lib/pipelineExecution.js';
	import { Badge, type BadgeVariant } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import Timestamp from '../Timestamp.svelte';
	import CardExecution from './CardExecution.svelte';
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
		/** The person may start the execution on a runner (project owner). */
		mayStart: boolean;
		reviewPending: boolean;
		onreview: () => void;
		ondecided: () => void | Promise<void>;
	}
	let { view, controller, canEdit, mayStart, reviewPending, onreview, ondecided }: Props = $props();

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

	/** The retry button disappears with the new state: the focus then moves to the message that says what happened. */
	async function retryStep(step: PipelineStepName) {
		const outcome = await controller.retryStep(step, canEdit);
		if (outcome === 'ignored') return;
		await tick();
		if (outcome === 'done' || document.activeElement === document.body || !document.activeElement?.isConnected) feedback?.focus();
		if (outcome === 'done') await ondecided();
	}
	const counts = $derived(stepCounts(data));
	const execution = $derived(executionSection(data, view.bindings, mayStart));
	const live = $derived(liveStep(data));
	const retryHint = $derived(retryHintKey(data, mayStart));
	/** The messages of the execution have their own place, in the section "Ausführung". */
	const message = $derived(view.feedback && view.feedback.scope !== 'execution' ? view.feedback : null);
	const liveLook = { running: 'text-ui-accent-ink', waiting: 'text-muted-foreground', warning: 'text-warning' } as const;
	const off = $derived(offSteps(data));

	const heading = 'text-muted-foreground text-xs font-semibold tracking-wide uppercase';
	const prose = '[overflow-wrap:anywhere] whitespace-pre-wrap';
</script>

<div class="flex min-w-0 flex-col gap-5" data-testid="card-pipeline">
	<!-- Outside the branches below: the first start must not rebuild the section (focus, announced message). -->
	{#if view.status === 'ready' && execution.show}
		<CardExecution {view} {controller} {mayStart} {reviewPending} {onreview} onchanged={ondecided} />
	{/if}
	{#if view.status === 'loading'}
		<p class="text-muted-foreground min-h-16 text-xs" role="status">{t('pipeline.loading')}</p>
	{:else if view.status === 'failed'}
		<div class="flex flex-wrap items-center gap-2" role="alert" data-testid="pipeline-error">
			<span>{t('pipeline.loadFailed')}</span>
			<Button size="sm" variant="outline" onclick={() => void controller.retry()}>{t('common.retry')}</Button>
		</div>
	{:else if !data || isEmptyPipeline(data)}
		<CardTabEmpty title={t('card.tab.pipeline.emptyTitle')} text={t('card.tab.pipeline.emptyText')} />
		{#if off.length > 0}
			<p class="text-muted-foreground -mt-2 text-xs" data-testid="pipeline-off-hint">{t('pipeline.offHint', { steps: off.map((s) => t(stepNameKey(s))).join(', ') })}</p>
		{/if}
	{:else}
		<section class="flex flex-col gap-1.5">
			<div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5">
				<h3 class={heading}>{t('pipeline.steps')}</h3>
				<p class="text-muted-foreground text-xs" data-tabular data-testid="pipeline-step-count">
					{t('pipeline.stepCount', { done: counts.done, total: counts.total })}{#if counts.off > 0}{', '}{t('pipeline.stepCount.off', { count: counts.off })}{/if}
				</p>
			</div>
			<ol class="flex flex-col divide-y rounded-xl border" aria-label={t('pipeline.steps')}>
				{#each orderedSteps(data) as s (s.step)}
					{@const on = stepOn(s)}
					{@const look = on ? (stepLook[s.state] ?? stepLook.pending) : stepLook.skipped}
					{@const role = roleLine(s)}
					{@const offer = retryOffer(data, s.step, canEdit)}
					{@const now = live?.step === s.step ? live : null}
					<li class={['flex min-w-0 gap-3 px-3 py-2.5', !on && 'text-muted-foreground']} data-testid="pipeline-step" data-step={s.step} data-state={s.state} data-enabled={on ? 'true' : 'false'} data-live={now ? now.tone : undefined} aria-current={now ? 'step' : undefined}>
						{#if now?.tone === 'running'}
							<LoaderCircle class="text-ui-accent mt-0.5 size-4 shrink-0 motion-safe:animate-spin" aria-hidden="true" />
						{:else if now}
							<Hourglass class="mt-0.5 size-4 shrink-0 {liveLook[now.tone]}" aria-hidden="true" />
						{:else}
							<look.icon class="mt-0.5 size-4 shrink-0 {look.color}" aria-hidden="true" />
						{/if}
						<div class="flex min-w-0 flex-1 flex-col gap-0.5">
							<div class="flex flex-wrap items-center justify-between gap-x-2 gap-y-1">
								<span class="font-medium">{t(stepNameKey(s.step))}</span>
								<Badge variant={look.badge} data-testid="pipeline-step-state">{on ? t(stepStateKey(s.state)) : t('pipeline.step.off')}</Badge>
							</div>
							{#if now}
								<p class="font-medium [overflow-wrap:anywhere] whitespace-pre-wrap {liveLook[now.tone]}" data-testid="pipeline-step-live">{t(now.key)}{#if now.progress}{': '}{now.progress}{/if}</p>
							{/if}
							{#if role}
								<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-testid="pipeline-step-role">{t('pipeline.roleLine', { model: role.model ?? t('pipeline.modelDefault'), effort: t(effortKey(role.effort)) })}</p>
							{/if}
							{#if on && s.note}<p class={prose}>{s.note}</p>{/if}
							{#if on && (s.actorLabel || s.updatedAt)}
								<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-tabular>{s.actorLabel ?? ''}{#if s.actorLabel && s.updatedAt}{' · '}{/if}<Timestamp value={s.updatedAt} /></p>
							{/if}
							{#if offer.kind === 'ready'}
								<div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1.5">
									<!-- aria-disabled instead of disabled: the focus stays on the button while sending; the controller ignores repeats. -->
									<Button size="sm" variant="outline" class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={view.retrying !== null} onclick={() => retryStep(s.step)}>
										<RotateCcw aria-hidden="true" />{view.retrying === s.step ? t('pipeline.retry.sending') : t('pipeline.retry')}
									</Button>
									<span class="text-muted-foreground text-xs" data-testid="pipeline-step-round" data-tabular>{t('pipeline.retry.round', { round: offer.round, max: offer.max })}</span>
								</div>
								{#if retryHint}<p class="text-muted-foreground text-xs" data-testid="pipeline-step-retry-hint">{t(retryHint)}</p>{/if}
							{:else if offer.kind === 'exhausted'}
								<div class="mt-1 flex flex-col gap-1.5">
									<div class="flex">
										<Button size="sm" variant="outline" class="max-sm:w-full" disabled aria-describedby="pipeline-exhausted-{s.step}"><RotateCcw aria-hidden="true" />{t('pipeline.retry')}</Button>
									</div>
									<p class="text-muted-foreground text-xs" id="pipeline-exhausted-{s.step}" data-testid="pipeline-step-exhausted">{offer.max === 0 ? t('pipeline.retry.disabled') : t('pipeline.retry.exhausted', { max: offer.max })}</p>
								</div>
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
							{#if plan.state === 'approved' && plan.decidedByType === 'system'}{t('pipeline.approvedAuto')}{:else}{t(plan.state === 'approved' ? 'pipeline.approvedBy' : 'pipeline.changesBy', { who: plan.decidedByLabel || t('cc.update.anonymous') })}{/if}{#if plan.decidedAt}{' · '}<Timestamp value={plan.decidedAt} />{/if}
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
			class={['focus-visible:ring-ring/60 -mt-3 rounded-lg font-medium [overflow-wrap:anywhere] outline-none empty:-mt-5 focus-visible:ring-2', message?.tone === 'error' ? 'text-destructive' : message?.tone === 'success' ? 'text-success' : 'text-foreground']}
			data-testid="pipeline-feedback"
		>{message ? t(message.key, message.params) : ''}</p>

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
							<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-tabular>{eventActor(e)}{#if e.createdAt}{' · '}<Timestamp value={e.createdAt} />{/if}</p>
						</li>
					{/each}
				</ol>
			</details>
		{/if}
	{/if}
</div>
