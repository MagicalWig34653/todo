<script lang="ts">
	import { tick } from 'svelte';
	import Hourglass from '@lucide/svelte/icons/hourglass';
	import Play from '@lucide/svelte/icons/play';
	import Square from '@lucide/svelte/icons/square';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import { t } from '#lib/i18n/index.js';
	import { stepNameKey, type ActOutcome, type PipelineController, type PipelineView } from '#lib/pipeline.js';
	import { executionSection, executionStateKey, isActiveExecution, isBudgetHold, jobStateKey, nothingToRun, pauseReasonKey, type ExecutionAction, type ExecutionState } from '#lib/pipelineExecution.js';
	import { Badge, type BadgeVariant } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Select } from '#lib/components/ui/select/index.js';

	/**
	 * Section "Ausführung" of the Pipeline tab (card F5DD1C00): the state of the execution on a runner and, for the person who may
	 * start (`mayStart`), start, continue and stop. The buttons are only hidden; the server checks the right. Device, folder and
	 * progress texts come from the runner and are shown as plain text.
	 */
	interface Props {
		view: PipelineView;
		controller: PipelineController;
		mayStart: boolean;
		/** The card has a review that waits for a decision. */
		reviewPending: boolean;
		onreview: () => void;
		onchanged: () => void | Promise<void>;
	}
	let { view, controller, mayStart, reviewPending, onreview, onchanged }: Props = $props();

	const data = $derived(view.data);
	const execution = $derived(data?.execution ?? null);
	const section = $derived(executionSection(data, view.bindings, mayStart));
	const active = $derived(isActiveExecution(execution));
	const stepName = $derived(execution?.step ? t(stepNameKey(execution.step)) : null);
	const rounds = $derived(data?.fixRounds ?? null);
	const held = $derived(!!execution && execution.state === 'running' && isBudgetHold(execution));
	const message = $derived(view.feedback?.scope === 'execution' ? view.feedback : null);

	const stateBadge: Record<ExecutionState, BadgeVariant> = { running: 'accent', waiting_approval: 'warning', blocked: 'destructive', paused: 'warning', completed: 'success', stopped: 'default' };

	let feedback = $state<HTMLParagraphElement | null>(null);

	async function act(action: ExecutionAction, pressed: EventTarget | null) {
		const outcome: ActOutcome = await (action === 'start' ? controller.startExecution(mayStart) : action === 'continue' ? controller.continueExecution(mayStart) : controller.stopExecution(mayStart));
		if (outcome === 'ignored') return;
		await tick();
		// The button may be gone with the new state, or a second click has to confirm: the focus goes to the message that says so.
		// Judged by the pressed button, not by the focus: Safari does not focus a button that is clicked.
		if (outcome === 'unread' || !(pressed as Element | null)?.isConnected) feedback?.focus();
		if (outcome === 'done') await onchanged();
	}
	/** The second click of a double click never confirms. */
	const once = (action: ExecutionAction) => (e: MouseEvent) => {
		if (e.detail <= 1) void act(action, e.currentTarget);
	};

	const heading = 'text-muted-foreground text-xs font-semibold tracking-wide uppercase';
	const wrap = '[overflow-wrap:anywhere]';
	const button = 'h-auto min-h-9 whitespace-normal max-sm:w-full aria-disabled:opacity-60';
</script>

<section class="flex min-w-0 scroll-mt-16 flex-col gap-2" aria-labelledby="card-execution-title" data-testid="pipeline-execution" data-state={execution?.state ?? 'none'}>
	<div class="flex flex-wrap items-center gap-2">
		<h3 class={heading} id="card-execution-title">{t('pipeline.exec.title')}</h3>
		{#if execution}<Badge variant={stateBadge[execution.state] ?? 'default'} data-testid="pipeline-execution-state">{t(executionStateKey(execution.state))}</Badge>{/if}
	</div>

	<div class="bg-card flex min-w-0 flex-col gap-3 rounded-xl border p-3">
		{#if execution}
			<dl class="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1" data-testid="pipeline-execution-status">
				{#if active && stepName}
					<dt class="text-muted-foreground">{t('pipeline.exec.step')}</dt>
					<dd class="font-medium {wrap}" data-testid="pipeline-execution-step">{stepName}</dd>
				{/if}
				{#if execution.deviceLabel || execution.bindingLabel}
					<dt class="text-muted-foreground">{t('pipeline.exec.device')}</dt>
					<dd class={wrap} data-testid="pipeline-execution-device">{[execution.deviceLabel, execution.bindingLabel].filter(Boolean).join(' · ')}</dd>
				{/if}
				{#if active && execution.jobState}
					<dt class="text-muted-foreground">{t('pipeline.exec.job')}</dt>
					<dd class={wrap} data-testid="pipeline-execution-job">{t(jobStateKey(execution.jobState))}</dd>
				{/if}
				{#if active && execution.jobProgress && !held}
					<dt class="text-muted-foreground">{t('pipeline.exec.progress')}</dt>
					<dd class="{wrap} whitespace-pre-wrap" data-testid="pipeline-execution-progress">{execution.jobProgress}</dd>
				{/if}
			</dl>

			{#if held}
				<p class="bg-warning-soft text-warning flex min-w-0 items-start gap-2 rounded-lg p-2.5 font-medium" data-testid="pipeline-execution-hold">
					<Hourglass class="mt-0.5 size-4 shrink-0" aria-hidden="true" />
					<span class="min-w-0 {wrap} whitespace-pre-wrap">{execution.jobProgress}</span>
				</p>
			{/if}

			{#if execution.state === 'waiting_approval'}
				<p class={wrap} data-testid="pipeline-execution-hint">{t('pipeline.exec.waitingApproval')}</p>
			{:else if execution.state === 'blocked'}
				<div class="flex flex-col gap-1">
					<p class={wrap} data-testid="pipeline-execution-hint">{t(execution.reason === 'fix_rounds_exhausted' ? 'pipeline.exec.blocked.fix_rounds_exhausted' : 'pipeline.exec.blocked.step_failed', { step: stepName ?? t('pipeline.step.unknown') })}</p>
					{#if rounds}<p class="text-muted-foreground text-xs" data-tabular data-testid="pipeline-execution-rounds">{t('pipeline.exec.fixRounds', { used: rounds.used, max: rounds.max })}</p>{/if}
				</div>
			{:else if execution.state === 'paused'}
				<p class={wrap} data-testid="pipeline-execution-hint">{t(pauseReasonKey(execution.reason))}</p>
			{:else if execution.state === 'completed'}
				<p class={wrap} data-testid="pipeline-execution-hint">{t(reviewPending ? 'pipeline.exec.completedReview' : 'pipeline.exec.completed')}</p>
			{:else if execution.state === 'stopped'}
				<p class={wrap} data-testid="pipeline-execution-hint">{t('pipeline.exec.stopped')}</p>
			{/if}

			{#if active && execution.runnerSupportsPipeline === false}
				<p class="text-warning flex min-w-0 items-start gap-2 text-xs" data-testid="pipeline-execution-unsupported">
					<TriangleAlert class="mt-0.5 size-3.5 shrink-0" aria-hidden="true" /><span class="min-w-0 {wrap}">{t('pipeline.exec.unsupported')}</span>
				</p>
			{/if}

			{#if active && mayStart}
				<!-- aria-disabled instead of disabled: the focus stays on the button while sending; the controller ignores repeats. -->
				<div class="flex flex-wrap gap-2">
					{#if execution.state === 'paused'}
						<Button class={button} aria-disabled={view.acting !== null} data-testid="pipeline-execution-continue" onclick={once('continue')}>
							<Play aria-hidden="true" />{view.acting === 'continue' ? t('pipeline.exec.sending') : view.confirmExecution === 'continue' ? t('pipeline.exec.continueConfirm', { version: data?.plan?.version ?? '?' }) : t('pipeline.exec.continue')}
						</Button>
					{/if}
					<Button variant="outline" class={button} aria-disabled={view.acting !== null} data-testid="pipeline-execution-stop" onclick={once('stop')}>
						<Square aria-hidden="true" />{view.acting === 'stop' ? t('pipeline.exec.sending') : t('pipeline.exec.stop')}
					</Button>
				</div>
			{:else if active && execution.state === 'paused'}
				<p class="text-muted-foreground text-xs" data-testid="pipeline-execution-owner-only">{t('pipeline.exec.ownerOnly')}</p>
			{/if}

			{#if execution.state === 'completed' && reviewPending}
				<div class="flex"><Button class={button} data-testid="pipeline-execution-review" onclick={onreview}>{t('pipeline.exec.toReview')}</Button></div>
			{/if}
		{/if}

		{#if section.start}
			<div class={['flex min-w-0 flex-col gap-2', execution && 'border-t pt-3']} data-testid="pipeline-execution-start">
				<label class="font-medium" for="card-execution-binding">{t('pipeline.exec.binding')}</label>
				<div class="flex min-w-0 flex-wrap items-center gap-2">
					<Select id="card-execution-binding" class="w-full sm:w-72" value={view.bindingID} onchange={(e: Event) => controller.choose((e.currentTarget as HTMLSelectElement).value)} aria-describedby="card-execution-intro">
						{#each view.bindings as b (b.id)}<option value={b.id}>{b.deviceLabel} · {b.label}</option>{/each}
					</Select>
					<Button class={button} aria-disabled={view.acting !== null} data-testid="pipeline-execution-start-button" onclick={once('start')}>
						<Play aria-hidden="true" />{view.acting === 'start' ? t('pipeline.exec.sending') : view.confirmExecution === 'start' ? t('pipeline.exec.startConfirm', { version: data?.plan?.version ?? '?' }) : t('pipeline.exec.start')}
					</Button>
				</div>
				<p class="text-muted-foreground text-xs" id="card-execution-intro">{t('pipeline.exec.intro')}</p>
			</div>
		{:else if !active && execution?.state !== 'completed' && mayStart && view.bindings.length > 0 && nothingToRun(data)}
			<p class="text-muted-foreground text-xs" data-testid="pipeline-execution-nothing">{t('pipeline.exec.nothingToRun')}</p>
		{/if}
	</div>

	<!-- Always present, so screen readers announce what appears in it. -->
	<p
		bind:this={feedback}
		role="status"
		aria-live="polite"
		tabindex="-1"
		class={['focus-visible:ring-ring/60 rounded-lg font-medium [overflow-wrap:anywhere] outline-none empty:-mt-2 focus-visible:ring-2', message?.tone === 'error' ? 'text-destructive' : message?.tone === 'success' ? 'text-success' : 'text-foreground']}
		data-testid="pipeline-execution-feedback"
	>{message ? t(message.key, message.params) : ''}</p>
</section>
