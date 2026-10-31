<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type JobListItem, type JobState, type Pairing, type RunnerDevice, type Task } from '#lib/api.js';
	import { bindableDevices, bindingsForProject, canStopJob, validateBinding, validateRelease, SCOPE_MAX } from '#lib/agentsLogic.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import Panel from './app/Panel.svelte';

	const STATES: JobState[] = ['queued', 'claimed', 'running', 'waiting_for_answer', 'awaiting_review', 'succeeded', 'failed', 'cancelled'];

	let label = $state('');
	let pairing = $state<Pairing | null>(null);
	let devices = $state<RunnerDevice[]>([]);
	let devicesLoaded = $state(false);
	let jobs = $state<JobListItem[]>([]);
	let jobsNext = $state<string | null>(null);
	let jobsLoaded = $state(false);
	let stateFilter = $state<JobState | ''>('');
	let generation = 0;
	// Two-step confirmation instead of a blocking browser dialog.
	let confirmRevoke = $state<string | null>(null);
	let confirmStop = $state<string | null>(null);
	// Binding form.
	let bindDevice = $state('');
	let bindProject = $state('');
	let bindKey = $state('');
	let bindLabel = $state('');
	let bindError = $state<'incomplete' | 'key' | null>(null);
	// Release form. The id is the idempotency key; it stays the same until a release succeeded.
	let relProject = $state('');
	let relTasks = $state<Task[]>([]);
	let relTask = $state('');
	let relBinding = $state('');
	let relMode = $state<'clarify' | 'implement'>('clarify');
	let relScope = $state('');
	let relID = crypto.randomUUID();
	let done = $state<string | null>(null);

	const bindable = $derived(bindableDevices(devices));
	const relBindings = $derived(relProject ? bindingsForProject(devices, relProject) : []);
	const relValid = $derived(validateRelease({ taskID: relTask, bindingID: relBinding, scope: relScope }));
	const projectsWithBinding = $derived(workspace.projects.filter((p) => bindingsForProject(devices, p.id).length > 0));

	const projectName = (id: string) => workspace.projects.find((p) => p.id === id)?.name ?? t('agents.unknownProject');

	async function loadDevices() {
		devices = await api.listDevices();
		devicesLoaded = true;
	}
	async function loadJobs(more = false) {
		const my = more ? generation : ++generation;
		const page = await api.listJobs({ state: stateFilter, before: more ? jobsNext : null, limit: 20 });
		if (my !== generation) return;
		jobs = more ? [...jobs, ...page.items] : page.items;
		jobsNext = page.nextCursor ?? null;
		jobsLoaded = true;
	}
	const reload = () => Promise.all([loadDevices(), loadJobs()]);

	onMount(() => {
		attempt(loadDevices);
	});
	$effect(() => {
		void stateFilter;
		attempt(() => loadJobs());
	});

	async function pair(e: Event) {
		e.preventDefault();
		const l = label.trim();
		if (!l) return;
		if (await attempt(async () => (pairing = await api.pairDevice(l)))) {
			label = '';
			await attempt(loadDevices);
		}
	}

	async function revoke(d: RunnerDevice) {
		if (await attempt(() => api.revokeDevice(d.id), loadDevices)) {
			confirmRevoke = null;
			done = t('agents.revokeDone');
			await attempt(loadDevices);
		}
	}
	async function bind(e: Event) {
		e.preventDefault();
		done = null;
		bindError = validateBinding({ projectID: bindProject, deviceID: bindDevice, repositoryKey: bindKey, label: bindLabel });
		if (bindError) return;
		if (await attempt(() => api.createBinding({ projectID: bindProject, deviceID: bindDevice, repositoryKey: bindKey.trim(), label: bindLabel.trim() }))) {
			bindKey = '';
			bindLabel = '';
			done = t('agents.bindDone');
			await attempt(loadDevices);
		}
	}
	async function pickReleaseProject() {
		relTask = '';
		relBinding = '';
		relTasks = [];
		if (!relProject) return;
		const my = relProject;
		const list = await api.listTasks(my);
		if (my === relProject) relTasks = list.filter((x) => x.status !== 'done');
	}
	async function release(e: Event) {
		e.preventDefault();
		done = null;
		const task = relTasks.find((x) => x.id === relTask);
		if (!task || !relValid) return;
		const ok = await attempt(() =>
			api.releaseJob({ id: relID, taskID: task.id, bindingID: relBinding, taskRevision: task.version, mode: relMode, scope: relScope.trim() })
		);
		if (ok) {
			relID = crypto.randomUUID();
			relScope = '';
			relTask = '';
			done = t('agents.releaseDone');
			await attempt(() => loadJobs());
		}
	}
	async function stop(j: JobListItem) {
		if (await attempt(() => api.stopJob(j.job.id), () => loadJobs())) {
			confirmStop = null;
			done = t('agents.stopDone');
			await attempt(() => loadJobs());
		}
	}

	function status(d: RunnerDevice): 'revoked' | 'paired' | 'pending' {
		return d.revokedAt ? 'revoked' : d.paired ? 'paired' : 'pending';
	}
	const tone = (s: JobState) => (s === 'failed' || s === 'cancelled' ? 'destructive' : s === 'succeeded' ? 'success' : 'default');
</script>

<section class="flex flex-col gap-4">
	<PageHeader title={t('nav.agents')} description={t('agents.hint')} testid="view-heading">
		{#snippet actions()}
			<Button variant="outline" size="sm" onclick={() => attempt(reload)}>{t('agents.reload')}</Button>
		{/snippet}
	</PageHeader>
	<Panel title={t('agents.pairTitle')} description={t('agents.pairHint')}>
		<form class="flex gap-2" onsubmit={pair}>
			<Input bind:value={label} placeholder={t('agents.labelPlaceholder')} aria-label={t('agents.label')} maxlength={100} />
			<Button type="submit" disabled={!label.trim()}>{t('agents.pair')}</Button>
		</form>
		{#if pairing}
			<div class="bg-muted/50 rounded-lg border p-3 text-sm" data-testid="pairing-code">
				<p class="text-muted-foreground mb-1">{t('agents.codeOnce', { until: formatWhen(pairing.expiresAt) })}</p>
				<code class="text-base font-semibold break-all">{pairing.code}</code>
			</div>
		{/if}
	</Panel>

	<Panel title={t('agents.devicesTitle')}>
		{#if devicesLoaded && devices.length === 0}<p class="text-muted-foreground text-sm">{t('agents.devicesEmpty')}</p>{/if}
		<ul class="flex flex-col divide-y" data-testid="device-list">
			{#each devices as d (d.id)}
				{@const s = status(d)}
				<li class="flex flex-col gap-1.5 py-3 first:pt-0 last:pb-0" data-testid="device" data-status={s}>
					<div class="flex flex-wrap items-center gap-2">
						<span class="font-medium" data-testid="device-label">{d.label}</span>
						<Badge variant={s === 'paired' ? 'success' : s === 'revoked' ? 'destructive' : 'default'} data-testid="device-status">{t(`agents.deviceStatus.${s}` as MessageKey)}</Badge>
						{#if d.revokedAt}<span class="text-muted-foreground text-xs">{t('agents.revokedAt', { when: formatWhen(d.revokedAt) })}</span>{/if}
						<span class="text-muted-foreground ml-auto text-xs" data-testid="device-active">{t('agents.activeRuns', { count: d.activeRunCount })}</span>
						{#if !d.revokedAt}
							{#if confirmRevoke === d.id}
								<span class="flex flex-wrap items-center gap-1 text-xs" role="alert">
									<span class="text-muted-foreground">{t('agents.revokeConfirm', { label: d.label })}</span>
									<Button size="xs" variant="destructive" data-testid="device-revoke-confirm" onclick={() => revoke(d)}>{t('agents.revoke')}</Button>
									<Button size="xs" variant="ghost" onclick={() => (confirmRevoke = null)}>{t('common.cancel')}</Button>
								</span>
							{:else}
								<Button size="xs" variant="outline" data-testid="device-revoke" onclick={() => (confirmRevoke = d.id)}>{t('agents.revoke')}</Button>
							{/if}
						{/if}
					</div>
					<div class="text-sm">
						<p class="text-muted-foreground mb-0.5 text-xs font-semibold">{t('agents.bindings')}</p>
						{#if d.bindings.length === 0}
							<p class="text-muted-foreground text-xs">{t('agents.noBindings')}</p>
						{:else}
							<ul class="flex flex-col gap-0.5">
								{#each d.bindings as b (b.id)}
									<li class="flex flex-wrap gap-x-2 text-[13px]" data-testid="binding">
										<span class="font-medium">{projectName(b.projectID)}</span>
										<span class="text-muted-foreground">{b.label}</span>
									</li>
								{/each}
							</ul>
						{/if}
					</div>
				</li>
			{/each}
		</ul>
	</Panel>

	<Panel title={t('agents.bindTitle')} description={t('agents.bindHint')}>
		{#if bindable.length === 0}
			<p class="text-muted-foreground text-sm">{t('agents.bindNoDevice')}</p>
		{:else}
			<form class="grid gap-2 sm:grid-cols-2" onsubmit={bind} data-testid="bind-form">
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.bindDevice')}
					<Select bind:value={bindDevice} data-testid="bind-device">
						<option value="">–</option>
						{#each bindable as d (d.id)}<option value={d.id}>{d.label}</option>{/each}
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.bindProject')}
					<Select bind:value={bindProject} data-testid="bind-project">
						<option value="">–</option>
						{#each workspace.projects as p (p.id)}<option value={p.id}>{p.name}</option>{/each}
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.bindKey')}
					<Input bind:value={bindKey} placeholder="123e4567-e89b-12d3-a456-426614174000" autocomplete="off" aria-invalid={bindError === 'key'} data-testid="bind-key" />
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.bindLabel')}
					<Input bind:value={bindLabel} maxlength={100} data-testid="bind-label" />
				</label>
				<div class="sm:col-span-2"><Button type="submit" data-testid="bind-submit">{t('agents.bind')}</Button></div>
				{#if bindError}<p class="text-destructive text-xs sm:col-span-2" role="alert">{bindError === 'key' ? t('agents.bindInvalidKey') : t('error.generic')}</p>{/if}
			</form>
		{/if}
		<p class="text-muted-foreground text-xs">{t('agents.bindRevokeMissing')}</p>
	</Panel>

	<Panel title={t('agents.releaseTitle')} description={t('agents.releaseHint')}>
		{#if projectsWithBinding.length === 0}
			<p class="text-muted-foreground text-sm">{t('agents.releaseNoBinding')}</p>
		{:else}
			<form class="grid gap-2 sm:grid-cols-2" onsubmit={release} data-testid="release-form">
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.releaseProject')}
					<Select bind:value={relProject} onchange={() => attempt(pickReleaseProject)} data-testid="release-project">
						<option value="">–</option>
						{#each projectsWithBinding as p (p.id)}<option value={p.id}>{p.name}</option>{/each}
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.releaseTask')}
					<Select bind:value={relTask} data-testid="release-task">
						<option value="">–</option>
						{#each relTasks as x (x.id)}<option value={x.id}>{x.title}</option>{/each}
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.releaseBinding')}
					<Select bind:value={relBinding} data-testid="release-binding">
						<option value="">–</option>
						{#each relBindings as b (b.id)}<option value={b.id}>{b.deviceLabel} · {b.label}</option>{/each}
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">{t('agents.releaseMode')}
					<Select bind:value={relMode} data-testid="release-mode">
						<option value="clarify">{t('agents.mode.clarify')}</option>
						<option value="implement">{t('agents.mode.implement')}</option>
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium sm:col-span-2">{t('agents.releaseScope')}
					<Textarea bind:value={relScope} maxlength={SCOPE_MAX} placeholder={t('agents.releaseScopePlaceholder')} data-testid="release-scope" />
				</label>
				<div class="sm:col-span-2"><Button type="submit" disabled={!relValid} data-testid="release-submit">{t('agents.release')}</Button></div>
			</form>
		{/if}
	</Panel>

	{#if done}<p class="text-success text-sm" role="status" data-testid="agents-done">{done}</p>{/if}

	<Panel title={t('agents.jobsTitle')}>
		{#snippet action()}
			<label class="flex items-center gap-2 text-sm">
				<span class="text-muted-foreground">{t('agents.jobsFilter')}</span>
				<Select bind:value={stateFilter} class="w-52 max-w-[50vw]" data-testid="job-filter">
					<option value="">{t('agents.jobsAll')}</option>
					{#each STATES as s (s)}<option value={s}>{t(`agents.job.${s}` as MessageKey)}</option>{/each}
				</Select>
			</label>
		{/snippet}
		{#if jobsLoaded && jobs.length === 0}<p class="text-muted-foreground text-sm">{t('agents.jobsEmpty')}</p>{/if}
		<ul class="flex flex-col divide-y" data-testid="job-list">
			{#each jobs as j (j.job.id)}
				<li class="flex flex-col gap-1 py-2.5 first:pt-0 last:pb-0" data-testid="job" data-state={j.job.state}>
					<div class="flex flex-wrap items-center gap-2">
						<span class="font-medium" data-testid="job-title">{j.taskTitle}</span>
						<Badge variant={tone(j.job.state)} data-testid="job-state">{t(`agents.job.${j.job.state}` as MessageKey)}</Badge>
						<span class="text-muted-foreground text-xs">{t(`agents.mode.${j.job.mode}` as MessageKey)}</span>
						{#if j.createdAt}<span class="text-muted-foreground ml-auto text-xs" data-tabular>{formatWhen(j.createdAt)}</span>{/if}
					</div>
					<p class="text-muted-foreground text-xs">{j.projectName}</p>
					{#if j.job.progress}<p class="line-clamp-2 text-[13px]">{j.job.progress}</p>{/if}
					{#if canStopJob(j.job.state)}
						{#if confirmStop === j.job.id}
							<div class="flex flex-wrap items-center gap-1 text-xs" role="alert">
								<span class="text-muted-foreground">{t('agents.stopConfirm', { title: j.taskTitle })}</span>
								<Button size="xs" variant="destructive" data-testid="job-stop-confirm" onclick={() => stop(j)}>{t('agents.stop')}</Button>
								<Button size="xs" variant="ghost" onclick={() => (confirmStop = null)}>{t('common.cancel')}</Button>
							</div>
						{:else}
							<div><Button size="xs" variant="outline" data-testid="job-stop" onclick={() => (confirmStop = j.job.id)}>{t('agents.stop')}</Button></div>
						{/if}
					{/if}
				</li>
			{/each}
		</ul>
		{#if jobsNext}
			<div><Button size="sm" variant="ghost" data-testid="jobs-more" onclick={() => attempt(() => loadJobs(true))}>{t('agents.jobsMore')}</Button></div>
		{/if}
	</Panel>
</section>
