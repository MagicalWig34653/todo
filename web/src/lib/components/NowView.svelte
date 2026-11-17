<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import { api, type OverviewNow, type OverviewProject } from '#lib/api.js';
	import { relativeWhen } from '#lib/cardRef.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { de } from '#lib/i18n/de.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { liveRefresh, startLiveRefresh } from '#lib/liveRefresh.js';
	import {
		allowRefetch, buildCommit, buildSummary, groupProjects, isEmptyNow, isExpanded, isOrphaned, loadExpanded, percentOf, projectStats, saveExpanded, type ExpandedMap
	} from '#lib/now.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import IdChip from './IdChip.svelte';
	import Radio from '@lucide/svelte/icons/radio';

	const sectionHead = 'text-muted-foreground mb-0.5 text-[11px] font-semibold tracking-wider uppercase';
	let data = $state<OverviewNow | null>(null);
	let failed = $state(false);
	let loading = $state(true);
	let live = $state(false);
	let expanded = $state<ExpandedMap>(loadExpanded());
	/** Re-evaluates relative ages and the quiet boundary without refetching (every 30 s). */
	let now = $state(new Date());
	let lastFetchAt: number | null = null;

	const groups = $derived(data ? groupProjects(data.projects, now) : { active: [], quiet: [] });
	const asOf = $derived(
		data
			? new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(data.serverTime))
			: ''
	);

	async function load() {
		try {
			const next = await api.overviewNow();
			lastFetchAt = Date.now();
			data = next;
			failed = false;
			now = new Date();
			live = liveRefresh.mode === 'live';
		} catch {
			failed = true;
		} finally {
			loading = false;
		}
	}
	/** Hints from the central service; in polling mode (old server) at most one refetch per 30 s. */
	async function refresh() {
		if (!allowRefetch(lastFetchAt, Date.now(), liveRefresh.mode === 'poll' ? 'poll' : 'live')) return;
		await load();
	}

	let ticker: ReturnType<typeof setInterval> | undefined;
	onMount(() => {
		void load();
		const unsubscribe = startLiveRefresh(refresh);
		ticker = setInterval(() => (now = new Date()), 30_000);
		return unsubscribe;
	});
	onDestroy(() => clearInterval(ticker));

	/** Only real user clicks (mouse, Enter, Space) are stored; the native toggle is replaced so defaults are never written by render. */
	function toggle(id: string, quiet: boolean, e: Event) {
		e.preventDefault();
		expanded = { ...expanded, [id]: !isExpanded(expanded, id, quiet) };
		saveExpanded(expanded);
	}

	const plural = (n: number, one: MessageKey, many: MessageKey) => (n === 1 ? t(one) : t(many, { count: n }));
	const when = (iso: string) => relativeWhen(iso, now);
	const eventLabel = (kind: string) => (`activity.kind.${kind}` in de ? t(`activity.kind.${kind}` as MessageKey) : t('now.event.unknown', { kind }));
	const clock = (iso: string) => new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
</script>

{#snippet time(iso: string)}<time datetime={new Date(iso).toISOString()} title={iso}>{when(iso)}</time>{/snippet}

{#snippet projectRow(p: OverviewProject, quiet: boolean)}
	{@const s = projectStats(p)}
	<details
		class={['bg-card rounded-xl border shadow-card', quiet && 'opacity-95']}
		open={isExpanded(expanded, p.projectID, quiet)}
		data-testid="now-project"
		data-project={p.projectID}
		data-quiet={quiet}
	>
		<summary onclick={(e) => toggle(p.projectID, quiet, e)} class="focus-visible:ring-ring/50 flex cursor-pointer flex-wrap items-center gap-2 rounded-xl px-3.5 py-3 outline-none focus-visible:ring-2 [&::-webkit-details-marker]:hidden">
			<span class="text-muted-foreground w-3 text-xs" aria-hidden="true">{isExpanded(expanded, p.projectID, quiet) ? '▾' : '▸'}</span>
			<span class={['min-w-36 flex-1 font-semibold', quiet && 'text-muted-foreground font-medium']} data-testid="now-project-name">{p.projectName}</span>
			{#if s.running > 0}<Badge data-testid="now-stat-running">{plural(s.running, 'now.stat.runningOne', 'now.stat.running')}</Badge>{/if}
			{#if s.sessions > 0}<Badge variant="success" data-testid="now-stat-sessions">{plural(s.sessions, 'now.stat.sessionsOne', 'now.stat.sessions')}</Badge>{/if}
			{#if s.waiting > 0}<Badge variant="warning" data-testid="now-stat-waiting">{plural(s.waiting, 'now.stat.waitingOne', 'now.stat.waiting')}</Badge>{/if}
			{#if s.builds > 0}<Badge data-testid="now-stat-builds">{plural(s.builds, 'now.stat.buildsOne', 'now.stat.builds')}</Badge>{/if}
			{#if s.running + s.sessions + s.waiting + s.builds === 0}<span class="text-muted-foreground text-sm">{t('now.nothingOpen')}</span>{/if}
			<span class="text-muted-foreground text-[13px]">{t('now.lastActivity', { time: when(p.lastActivityAt) })}</span>
		</summary>
		<div class="flex flex-col gap-3 px-3.5 pb-3.5 pl-9 max-menu:pl-3.5">
			{#if p.runningTasks.length > 0}
				<section aria-labelledby="run-{p.projectID}" data-testid="now-running">
					<h3 id="run-{p.projectID}" class={sectionHead}>{t('now.section.running')}</h3>
					<ul class="divide-y">
						{#each p.runningTasks as task (task.taskID)}
							{@const pct = percentOf(task)}
							<li class="flex flex-col gap-1 py-2" data-testid="now-running-item">
								<div class="flex flex-wrap items-center gap-2">
									<button type="button" class="hover:underline text-left text-sm font-semibold [overflow-wrap:anywhere]" onclick={() => cardDetail.open({ type: 'task', id: task.taskID })}>{task.title}</button>
									<Badge>{task.worker || t('now.noWorker')}</Badge>
									<IdChip id={task.taskID} subtle />
								</div>
								{#if pct !== null}
									<div class="bg-muted h-1.5 overflow-hidden rounded-full" role="progressbar" aria-valuenow={pct} aria-valuemin="0" aria-valuemax="100" aria-label={t('now.progress', { percent: pct })}>
										<div class="bg-ui-accent h-full" style:width="{pct}%"></div>
									</div>
								{/if}
								<p class="text-muted-foreground text-[13px]">
									{#if pct !== null}{pct} % · {/if}{#if task.lastProgress}„{task.lastProgress.note}“ · {@render time(task.lastProgress.at)}{:else}{t('now.noNote')}{/if}
								</p>
							</li>
						{/each}
					</ul>
				</section>
			{/if}
			{#if p.sessions.length > 0}
				<section aria-labelledby="ses-{p.projectID}" data-testid="now-sessions">
					<h3 id="ses-{p.projectID}" class={sectionHead}>{t('now.section.sessions')}</h3>
					<ul class="divide-y">
						{#each p.sessions as session (session.sessionName)}
							{@const orphan = isOrphaned(session)}
							<li class="flex flex-col gap-0.5 py-2" data-testid="now-session" data-orphaned={orphan}>
								<div class="flex flex-wrap items-center gap-2">
									<span class="text-sm font-semibold [overflow-wrap:anywhere]">{session.sessionName}</span>
									<Badge variant={orphan ? 'destructive' : 'success'}>{orphan ? t('now.session.orphaned') : t('now.session.active')}</Badge>
									<span class="text-muted-foreground text-[13px]">{t('now.heartbeat', { time: when(session.updatedAt) })}</span>
								</div>
								<p class="text-muted-foreground text-[13px] [overflow-wrap:anywhere]">{orphan ? `${session.activity} · ${t('now.session.orphanedHint')}` : session.activity}</p>
							</li>
						{/each}
					</ul>
				</section>
			{/if}
			{#if p.openQuestions.length + p.pendingReviews.length > 0}
				<section aria-labelledby="wait-{p.projectID}" data-testid="now-waiting">
					<h3 id="wait-{p.projectID}" class={sectionHead}>{t('now.section.waiting')}</h3>
					<ul class="flex flex-col gap-1.5">
						{#each p.openQuestions as q (q.id)}
							<li class="bg-warning-soft flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg px-3 py-2 text-sm" data-testid="now-waiting-item" data-kind="question">
								<span class="min-w-0 flex-1 [overflow-wrap:anywhere]"><b>{t('now.question')}:</b> {q.text} <span class="text-muted-foreground">· {q.taskTitle} · {@render time(q.createdAt)}</span></span>
								<Button size="sm" onclick={() => cardDetail.open({ type: 'question', id: q.id })}>{t('now.answer')}</Button>
							</li>
						{/each}
						{#each p.pendingReviews as r (r.id)}
							<li class="bg-warning-soft flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg px-3 py-2 text-sm" data-testid="now-waiting-item" data-kind="review">
								<span class="min-w-0 flex-1 [overflow-wrap:anywhere]"><b>{t('now.review')}:</b> {r.text} <span class="text-muted-foreground">· {r.taskTitle} · {@render time(r.createdAt)}</span></span>
								<Button size="sm" variant="outline" onclick={() => cardDetail.open({ type: 'review', id: r.taskID })}>{t('now.look')}</Button>
							</li>
						{/each}
					</ul>
				</section>
			{/if}
			{#if p.builds.length > 0}
				<section aria-labelledby="bld-{p.projectID}" data-testid="now-builds">
					<h3 id="bld-{p.projectID}" class={sectionHead}>{t('now.section.builds')}</h3>
					<ul class="divide-y">
						{#each p.builds as b (b.buildID)}
							<li class="flex flex-wrap items-center gap-2 py-2 text-sm" data-testid="now-build">
								<span class="font-semibold [overflow-wrap:anywhere]">{buildSummary(b)}</span>
								{#if buildCommit(b)}<code class="text-muted-foreground font-mono text-[12px]" title={b.commit} data-testid="now-build-commit">{buildCommit(b)}</code>{/if}
								<span class="text-muted-foreground text-[13px]">{@render time(b.createdAt)}</span>
							</li>
						{/each}
					</ul>
				</section>
			{/if}
			{#if p.recentActivity.length > 0}
				<section aria-labelledby="evt-{p.projectID}" data-testid="now-events">
					<h3 id="evt-{p.projectID}" class={sectionHead}>{t('now.section.events')}</h3>
					<ul class="border-border ml-1 flex flex-col gap-0.5 border-l-2 pl-3">
						{#each p.recentActivity as e, i (e.createdAt + e.kind + i)}
							<li class="text-[13px]"><time class="text-muted-foreground mr-1.5" datetime={new Date(e.createdAt).toISOString()} title={e.createdAt}>{clock(e.createdAt)}</time>{eventLabel(e.kind)}: {e.taskTitle}</li>
						{/each}
					</ul>
				</section>
			{/if}
		</div>
	</details>
{/snippet}

<div data-testid="now-view">
	<PageHeader title={t('now.title')} description={t('now.hint')} testid="view-heading">
		{#snippet actions()}
			{#if data}
				<span class="inline-flex items-center gap-1.5" role="status" aria-live="polite">
					<Badge variant="success" data-testid="now-live"><Radio class="size-3" aria-hidden="true" />{live ? t('now.live') : t('now.liveAuto')}</Badge>
					<span class="text-muted-foreground text-[13px]" data-testid="now-asof">{t('now.asOf', { time: asOf })}</span>
				</span>
			{/if}
		{/snippet}
	</PageHeader>

	{#if loading && !data}
		<p class="text-muted-foreground text-sm" role="status" data-testid="now-loading">{t('now.loading')}</p>
	{:else if !data}
		<div role="alert" class="flex flex-col items-start gap-2" data-testid="now-error">
			<p class="text-sm">{t('now.error')}</p>
			<Button variant="outline" onclick={() => load()}>{t('now.retry')}</Button>
		</div>
	{:else}
		{#if failed}<p class="text-warning mb-3 text-sm" role="alert" data-testid="now-stale">{t('now.errorStale')}</p>{/if}
		{#if isEmptyNow(data.projects)}
			<div data-testid="now-empty">
				<EmptyState title={t('now.empty')} icon={Radio}><p>{t('now.emptyHint')}</p></EmptyState>
			</div>
		{:else}
			<div class="flex flex-col gap-2.5" data-testid="now-active">
				{#each groups.active as p (p.projectID)}{@render projectRow(p, false)}{/each}
			</div>
			{#if groups.quiet.length > 0}
				<h3 class="text-muted-foreground mt-6 mb-2 text-[13px]" data-testid="now-quiet-heading">
					{groups.quiet.length === 1 ? t('now.quietOne') : t('now.quiet', { count: groups.quiet.length })}
				</h3>
				<div class="flex flex-col gap-2.5" data-testid="now-quiet">
					{#each groups.quiet as p (p.projectID)}{@render projectRow(p, true)}{/each}
				</div>
			{/if}
		{/if}
	{/if}
</div>
