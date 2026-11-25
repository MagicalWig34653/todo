<script lang="ts">
	import { tick, untrack } from 'svelte';
	import { api, type Project } from '#lib/api.js';
	import { can, roleOf } from '#lib/access.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { EFFORTS, PIPELINE_ROLES, PIPELINE_STEPS, effortKey, stepNameKey } from '#lib/pipeline.js';
	import { MODEL_SUGGESTIONS, createSettingsController, emptySettingsView, settingsDirty, settingsSummary, type SettingsProblem } from '#lib/pipelineSettings.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Timestamp from './Timestamp.svelte';

	/**
	 * Project settings "Pipeline" (card B926E7D8): switch each step on or off, model and effort per role, number of fix rounds,
	 * notification while an approval waits. Only the manage right edits; everyone else sees the values. The server checks the right.
	 */
	let { project }: { project: Project } = $props();

	const view = $state(emptySettingsView());
	const controller = createSettingsController(view, api);
	const canManage = $derived(can(roleOf(project), 'editProject'));
	/** Primitive on purpose: a refreshed project object must not reload the form (and drop what is typed). */
	const projectID = $derived(project.id);
	$effect(() => {
		const id = projectID;
		untrack(() => void controller.open(id));
	});

	const dirty = $derived(!!view.data && !!view.draft && settingsDirty(view.data, view.draft));
	const problemOf = (field: SettingsProblem['field'], role?: string) => view.problems.find((p) => p.field === field && p.role === role);
	let form = $state<HTMLFormElement | null>(null);

	async function submit() {
		const outcome = await controller.save(canManage);
		if (outcome === 'ignored') return;
		await tick();
		// Invalid input: the focus goes to the first field that needs attention.
		if (outcome === 'invalid') form?.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus();
	}

	const heading = 'text-muted-foreground text-xs font-semibold tracking-wide uppercase';
	const sid = (name: string) => `pset-${name}`;
</script>

<div class="flex min-w-0 flex-col gap-4" data-testid="pipeline-settings">
	{#if view.status === 'loading'}
		<p class="text-muted-foreground min-h-16 text-sm" role="status" data-testid="pipeline-settings-loading">{t('pipeline.settings.loading')}</p>
	{:else if view.status === 'failed'}
		<div class="flex flex-wrap items-center gap-2" role="alert">
			<span>{t('pipeline.settings.loadFailed')}</span>
			<Button size="sm" variant="outline" onclick={() => void controller.reload()}>{t('common.retry')}</Button>
		</div>
	{:else if view.status === 'unsupported'}
		<p class="text-muted-foreground text-sm" data-testid="pipeline-settings-unsupported">{t('pipeline.settings.unsupported')}</p>
	{:else if view.draft}
		<p class="text-muted-foreground text-sm">{t('pipeline.settings.intro')}</p>
		{#if !canManage}
			<p class="bg-muted/60 rounded-xl border p-3 text-sm" data-testid="pipeline-settings-readonly">{t('pipeline.settings.readonly')}</p>
		{/if}

		<form bind:this={form} class="flex min-w-0 flex-col gap-5" novalidate onsubmit={(e) => { e.preventDefault(); void submit(); }}>
			<fieldset class="flex min-w-0 flex-col gap-2" disabled={!canManage}>
				<legend class={heading}>{t('pipeline.settings.steps')}</legend>
				<p class="text-muted-foreground text-xs">{t('pipeline.settings.stepsHint')}</p>
				<ul class="flex flex-col divide-y rounded-xl border">
					{#each PIPELINE_STEPS as step (step)}
						<li>
							<label class="flex min-h-11 cursor-pointer items-start gap-3 px-3 py-2.5 has-[:disabled]:cursor-default">
								<Checkbox class="mt-0.5" bind:checked={view.draft.steps[step]} aria-labelledby={sid(`step-${step}`)} aria-describedby={sid(`step-${step}-d`)} data-testid="pipeline-settings-step-{step}" />
								<span class="flex min-w-0 flex-col gap-0.5">
									<span class="font-medium" id={sid(`step-${step}`)}>{t(stepNameKey(step))}</span>
									<span class="text-muted-foreground text-xs" id={sid(`step-${step}-d`)}>{t(`pipeline.settings.step.${step}` as MessageKey)}</span>
								</span>
							</label>
						</li>
					{/each}
				</ul>
			</fieldset>

			<fieldset class="flex min-w-0 flex-col gap-2" disabled={!canManage}>
				<legend class={heading}>{t('pipeline.settings.roles')}</legend>
				<p class="text-muted-foreground text-xs">{t('pipeline.settings.rolesHint')}</p>
				<datalist id={sid('models')}>
					{#each MODEL_SUGGESTIONS as m (m)}<option value={m}></option>{/each}
				</datalist>
				<ul class="flex flex-col divide-y rounded-xl border">
					{#each PIPELINE_ROLES as role (role)}
						{@const roleName = t(`pipeline.role.${role}` as MessageKey)}
						{@const modelProblem = problemOf('model', role)}
						{@const effortProblem = problemOf('effort', role)}
						<li class="grid min-w-0 gap-2 px-3 py-2.5 sm:grid-cols-[6.5rem_minmax(0,1fr)_10rem] sm:items-start" data-testid="pipeline-settings-role" data-role={role}>
							<span class="font-medium sm:pt-6">{roleName}</span>
							<div class="flex min-w-0 flex-col gap-1">
								<label class="text-muted-foreground flex min-w-0 flex-col gap-1 text-xs font-medium">
									<span aria-hidden="true">{t('pipeline.settings.modelShort')}</span>
									<Input
										class="text-foreground"
										list={sid('models')}
										autocomplete="off"
										autocapitalize="none"
										spellcheck={false}
										placeholder={t('pipeline.modelDefault')}
										aria-label={t('pipeline.settings.model', { role: roleName })}
										aria-invalid={modelProblem ? 'true' : undefined}
										aria-describedby={modelProblem ? sid(`model-${role}-p`) : undefined}
										bind:value={view.draft.roles[role].model}
									/>
								</label>
								{#if modelProblem}<p class="text-destructive text-xs font-medium" role="alert" id={sid(`model-${role}-p`)}>{t('pipeline.settings.problem.model')}</p>{/if}
							</div>
							<div class="flex min-w-0 flex-col gap-1">
								<label class="text-muted-foreground flex min-w-0 flex-col gap-1 text-xs font-medium">
									<span aria-hidden="true">{t('pipeline.settings.effortShort')}</span>
									<Select
										class="text-foreground"
										aria-label={t('pipeline.settings.effort', { role: roleName })}
										aria-invalid={effortProblem ? 'true' : undefined}
										bind:value={view.draft.roles[role].effort}
									>
										<option value="">{t('pipeline.effort.default')}</option>
										{#each EFFORTS as e (e)}<option value={e}>{t(effortKey(e))}</option>{/each}
									</Select>
								</label>
								{#if effortProblem}<p class="text-destructive text-xs font-medium" role="alert">{t('pipeline.settings.problem.effort')}</p>{/if}
							</div>
						</li>
					{/each}
				</ul>
			</fieldset>

			<fieldset class="flex min-w-0 flex-col gap-3" disabled={!canManage}>
				<div class="flex flex-col gap-1">
					<label class="font-medium" for={sid('rounds')}>{t('pipeline.settings.rounds')}</label>
					<Input
						id={sid('rounds')}
						class="w-24"
						inputmode="numeric"
						autocomplete="off"
						aria-invalid={problemOf('maxFixRounds') ? 'true' : undefined}
						aria-describedby={problemOf('maxFixRounds') ? `${sid('rounds-p')} ${sid('rounds-h')}` : sid('rounds-h')}
						bind:value={view.draft.maxFixRounds}
					/>
					<p class="text-muted-foreground text-xs" id={sid('rounds-h')}>{t('pipeline.settings.roundsHint')}</p>
					{#if problemOf('maxFixRounds')}<p class="text-destructive text-xs font-medium" role="alert" id={sid('rounds-p')}>{t('pipeline.settings.problem.rounds')}</p>{/if}
				</div>
				<label class="flex min-h-9 cursor-pointer items-start gap-3 has-[:disabled]:cursor-default">
					<Checkbox class="mt-0.5" bind:checked={view.draft.notify} aria-labelledby={sid('notify')} aria-describedby={sid('notify-d')} />
					<span class="flex min-w-0 flex-col gap-0.5">
						<span class="font-medium" id={sid('notify')}>{t('pipeline.settings.notify')}</span>
						<span class="text-muted-foreground text-xs" id={sid('notify-d')}>{t('pipeline.settings.notifyHint')}</span>
					</span>
				</label>
			</fieldset>

			<div class="flex flex-col gap-2">
				{#if canManage}
					<!-- aria-disabled instead of disabled: the focus stays on the button while saving; the controller ignores repeats. -->
					<div class="flex flex-wrap gap-2">
						<Button type="submit" class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={view.busy}>{view.busy ? t('pipeline.settings.saving') : t('pipeline.settings.save')}</Button>
						{#if dirty}<Button type="button" variant="outline" class="max-sm:w-full" onclick={() => controller.discard()}>{t('pipeline.settings.discard')}</Button>{/if}
					</div>
				{/if}
				<p
					role="status"
					aria-live="polite"
					class={['font-medium [overflow-wrap:anywhere] empty:hidden', view.feedback?.tone === 'error' ? 'text-destructive' : view.feedback?.tone === 'success' ? 'text-success' : 'text-foreground']}
					data-testid="pipeline-settings-feedback"
				>{view.feedback ? t(view.feedback.key) : ''}</p>
			</div>
		</form>

		<section class="flex min-w-0 flex-col gap-1.5" aria-labelledby={sid('history')} data-testid="pipeline-settings-history">
			<h3 class={heading} id={sid('history')}>{t('pipeline.settings.history')}</h3>
			{#if !view.data || view.data.history.length === 0}
				<p class="text-muted-foreground text-sm">{t('pipeline.settings.historyEmpty')}</p>
			{:else}
				<ol class="flex flex-col gap-2 border-l pl-3">
					{#each view.data.history as e (e.id)}
						<li class="min-w-0" data-testid="pipeline-settings-event">
							<p class="[overflow-wrap:anywhere]">{settingsSummary(e.summary)}</p>
							<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]" data-tabular>{e.actorLabel || t('cc.update.anonymous')}{#if e.createdAt}{' · '}<Timestamp value={e.createdAt} />{/if}</p>
						</li>
					{/each}
				</ol>
			{/if}
		</section>
	{/if}
</div>
