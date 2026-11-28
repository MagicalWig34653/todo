<script lang="ts">
	import { untrack } from 'svelte';
	import { api } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { canApprove, deployErrorText, hasOpenRollback, isDecidable, isOpenPlan, sortPlans, stageLabel, type DeployPlan, type DeployTarget } from '#lib/deploy.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import ArrowLeft from '@lucide/svelte/icons/arrow-left';
	import Lock from '@lucide/svelte/icons/lock';

	/**
	 * Upload plans of one deploy target (card 354ADE12, ADR 0044): a person sees what would change, approves (and with a locked plan
	 * says explicitly that changes made on the server are overwritten), rejects, or plans the way back. The server checks every
	 * right and the server state again.
	 */
	let { target, canManage, onback }: { target: DeployTarget; canManage: boolean; onback: () => void } = $props();

	let status = $state<'loading' | 'failed' | 'ready'>('loading');
	let plans = $state<DeployPlan[]>([]);
	/** Plan ID and what is happening to it. */
	let busy = $state<{ id: string; action: 'approve' | 'reject' | 'rollback' } | null>(null);
	let override = $state<Record<string, boolean>>({});
	let errors = $state<Record<string, string>>({});
	let message = $state('');
	const sorted = $derived(sortPlans(plans));

	async function load() {
		try {
			plans = (await api.deployPlans(target.id)).items;
			status = 'ready';
		} catch {
			status = 'failed';
		}
	}
	$effect(() => {
		void target.id;
		untrack(() => void load());
	});

	async function act(plan: DeployPlan, action: 'approve' | 'reject' | 'rollback') {
		if (busy) return;
		busy = { id: plan.id, action };
		errors = { ...errors, [plan.id]: '' };
		message = '';
		try {
			if (action === 'reject') await api.rejectDeployPlan(plan.id);
			else if (action === 'rollback') {
				const r = await api.rollbackDeployPlan(plan.id);
				if (!r.ok) errors = { ...errors, [plan.id]: deployErrorText(r.code ?? 'deploy_failed') };
				else message = t('deploy.plans.rollbackPlanned');
			} else {
				// A way back planned here has no request yet: the person asks and decides in one step.
				if (plan.state === 'planned') await api.requestDeployPlan(plan.id);
				await api.approveDeployPlan(plan.id, plan.blocked && !!override[plan.id]);
			}
		} catch (e) {
			errors = { ...errors, [plan.id]: deployErrorText(e) };
		} finally {
			await load();
			busy = null;
		}
	}

	const stateVariant = (state: string) => (state === 'succeeded' ? 'success' : state === 'failed' ? 'destructive' : state === 'requested' || state === 'running' ? 'warning' : 'outline');
	const when = (iso: string) => new Date(iso).toLocaleString('de-DE', { dateStyle: 'short', timeStyle: 'short' });
	const heading = 'text-muted-foreground text-xs font-semibold tracking-wide uppercase';
</script>

<section class="flex min-w-0 flex-col gap-3" data-testid="deploy-plans" aria-labelledby="deploy-plans-title">
	<div><Button size="sm" variant="ghost" data-testid="deploy-plans-back" onclick={onback}><ArrowLeft aria-hidden="true" />{t('deploy.sync.back')}</Button></div>
	<div class="flex min-w-0 flex-wrap items-center gap-2">
		<h3 id="deploy-plans-title" class="min-w-0 font-semibold [overflow-wrap:anywhere]">{t('deploy.plans.title', { name: target.name })}</h3>
		<Badge variant={target.stage === 'prod' ? 'warning' : 'accent'}>{stageLabel(target.stage)}</Badge>
		<Button size="sm" variant="outline" class="ml-auto" data-testid="deploy-plans-reload" onclick={() => void load()}>{t('deploy.plans.reload')}</Button>
	</div>
	<p class="text-muted-foreground text-sm">{target.stage === 'prod' ? t('deploy.plans.prod') : t('deploy.plans.intro')}</p>
	{#if !canManage}
		<p class="bg-muted/60 rounded-xl border p-3 text-sm">{t('deploy.plans.needsManage')}</p>
	{/if}
	<p role="status" aria-live="polite" class="text-success text-sm font-medium empty:hidden" data-testid="deploy-plans-status">{message}</p>

	{#if status === 'loading'}
		<p class="text-muted-foreground min-h-16 text-sm" role="status">{t('deploy.plans.loading')}</p>
	{:else if status === 'failed'}
		<p class="text-destructive text-sm font-medium" role="alert">{t('deploy.plans.loadFailed')}</p>
	{:else if plans.length === 0}
		<p class="text-muted-foreground rounded-xl border border-dashed p-4 text-center text-sm" data-testid="deploy-plans-empty">{t('deploy.plans.empty')}</p>
	{:else}
		<ul class="flex flex-col gap-3">
			{#each sorted as plan (plan.id)}
				<li class="flex min-w-0 flex-col gap-2 rounded-xl border p-3 text-sm" data-testid="deploy-plan" data-plan-id={plan.id} data-state={plan.state} data-kind={plan.kind}>
					<div class="flex min-w-0 flex-wrap items-center gap-2">
						<span class="font-medium">{t(`deploy.plans.kind.${plan.kind}` as MessageKey)}</span>
						<Badge variant={stateVariant(plan.state)} data-testid="deploy-plan-state">{t(`deploy.plans.state.${plan.state}` as MessageKey)}</Badge>
						<span class="text-muted-foreground text-xs">{when(plan.createdAt)}</span>
					</div>
					<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]">
						{plan.requestedBy ? t('deploy.plans.requestedBy', { name: plan.requestedBy }) : t('deploy.plans.createdBy', { name: plan.createdBy ?? '?' })}
						{#if plan.decidedBy} · {t('deploy.plans.decidedBy', { name: plan.decidedBy })}{/if}
						{#if plan.ref} · {t('deploy.plans.ref', { ref: plan.ref })}{/if}
					</p>
					{#if plan.note}<p class="[overflow-wrap:anywhere]" data-testid="deploy-plan-note">{plan.note}</p>{/if}
					<p data-testid="deploy-plan-counts">{t('deploy.plans.counts', { upload: plan.summary.upload, delete: plan.summary.delete, unchanged: plan.summary.unchanged })}</p>
					{#if plan.summary.serverOnly > 0}<p class="text-muted-foreground text-xs">{t('deploy.plans.serverOnly', { n: plan.summary.serverOnly })}</p>{/if}

					{#if plan.blocked && isOpenPlan(plan)}
						<div class="bg-warning-soft flex min-w-0 flex-col gap-2 rounded-lg p-3" data-testid="deploy-plan-locked">
							<p class="flex items-center gap-2 font-semibold"><Lock class="size-4 shrink-0" aria-hidden="true" />{t('deploy.plans.lockedTitle')}</p>
							<p>{t('deploy.plans.lockedText')}</p>
							<ul class="flex flex-col gap-1">
								{#each plan.blockers as b (b.serverPath)}
									<li class="min-w-0 text-xs [overflow-wrap:anywhere]" data-testid="deploy-plan-blocker"><span class="font-mono">{b.serverPath}</span>: {t(`deploy.plans.block.${b.reason}` as MessageKey)}</li>
								{/each}
							</ul>
							{#if !plan.overridable}
								<p class="font-medium">{t('deploy.plans.hardLocked')}</p>
							{:else if canManage}
								<label class="flex min-h-9 cursor-pointer items-center gap-2 font-medium">
									<Checkbox bind:checked={() => override[plan.id] ?? false, (v) => (override = { ...override, [plan.id]: v === true })} data-testid="deploy-plan-override" class="border-foreground/50" />{t('deploy.plans.override')}
								</label>
							{/if}
						</div>
					{/if}

					{#if plan.files.length > 0}
						<details open={isOpenPlan(plan) && plan.files.length <= 20}>
							<summary class="{heading} min-h-9 cursor-pointer py-2">{t('deploy.plans.files', { n: plan.files.length })}</summary>
							<ul class="flex flex-col divide-y rounded-lg border">
								{#each plan.files as f (f.serverPath)}
									<li class="flex min-w-0 flex-wrap items-baseline justify-between gap-x-3 px-2 py-1.5" data-testid="deploy-plan-file">
										<span class="min-w-0 font-mono text-xs [overflow-wrap:anywhere]">{f.serverPath}</span>
										<span class={['text-xs font-medium', f.reason === 'drift' || f.reason === 'remove' ? 'text-warning' : 'text-muted-foreground']}>{t(`deploy.plans.reason.${f.reason}` as MessageKey)}</span>
									</li>
								{/each}
							</ul>
						</details>
					{/if}
					{#if plan.findings.length > 0 && isOpenPlan(plan)}
						<details>
							<summary class="text-muted-foreground min-h-9 cursor-pointer py-2 text-xs">{t('deploy.plans.findings', { n: plan.findings.length })}</summary>
							<ul class="flex flex-col gap-1">
								{#each plan.findings as f (f.path)}<li class="font-mono text-xs [overflow-wrap:anywhere]">{f.path}</li>{/each}
							</ul>
						</details>
					{/if}

					{#if plan.state === 'succeeded'}
						<p class="text-success font-medium" data-testid="deploy-plan-result">{t('deploy.plans.done', { n: plan.written.length })}</p>
					{:else if plan.state === 'failed'}
						<p class="text-destructive font-medium [overflow-wrap:anywhere]" data-testid="deploy-plan-result">{deployErrorText(plan.code ?? 'deploy_failed')}{plan.written.length > 0 ? ` ${t('deploy.plans.failedWritten', { n: plan.written.length })}` : ''}</p>
					{/if}
					{#if plan.state === 'planned' && !isDecidable(plan)}
						<p class="text-muted-foreground text-xs" data-testid="deploy-plan-unasked">{t('deploy.plans.unasked')}</p>
					{/if}
					<p role="alert" class="text-destructive font-medium [overflow-wrap:anywhere] empty:hidden" data-testid="deploy-plan-error">{errors[plan.id] ?? ''}</p>

					{#if (canManage && isOpenPlan(plan) && target.stage === 'test') || (plan.canRollback && !hasOpenRollback(plans, plan))}
						<div class="flex flex-wrap gap-2">
							{#if canManage && isOpenPlan(plan) && target.stage === 'test'}
								{#if isDecidable(plan)}
									<Button size="sm" data-testid="deploy-plan-approve" disabled={!canApprove(plan) || (plan.blocked && !override[plan.id]) || busy !== null} onclick={() => void act(plan, 'approve')}>
										{busy?.id === plan.id && busy.action === 'approve' ? t('deploy.plans.running') : plan.kind === 'rollback' ? t('deploy.plans.approveRollback') : t('deploy.plans.approve')}
									</Button>
								{/if}
								<Button size="sm" variant="outline" data-testid="deploy-plan-reject" disabled={busy !== null} onclick={() => void act(plan, 'reject')}>{t('deploy.plans.reject')}</Button>
							{/if}
							{#if plan.canRollback && !hasOpenRollback(plans, plan) && target.stage === 'test'}
								<Button size="sm" variant="outline" data-testid="deploy-plan-rollback" disabled={busy !== null} onclick={() => void act(plan, 'rollback')}>
									{busy?.id === plan.id && busy.action === 'rollback' ? t('deploy.plans.planningRollback') : t('deploy.plans.rollback')}
								</Button>
							{/if}
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</section>
