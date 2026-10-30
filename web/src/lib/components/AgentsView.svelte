<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type JobListItem, type JobState, type Pairing, type RunnerDevice } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
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
				</li>
			{/each}
		</ul>
		{#if jobsNext}
			<div><Button size="sm" variant="ghost" data-testid="jobs-more" onclick={() => attempt(() => loadJobs(true))}>{t('agents.jobsMore')}</Button></div>
		{/if}
	</Panel>
</section>
