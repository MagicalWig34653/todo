<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import { api, type NowActive, type OverviewNow, type OverviewProject } from '#lib/api.js';
	import { relativeWhen } from '#lib/cardRef.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { uniqueKeys } from '#lib/keys.js';
	import { de } from '#lib/i18n/de.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { liveRefresh, startLiveRefresh } from '#lib/liveRefresh.js';
	import {
		allowRefetch, blockOf, buildCommit, buildEventHead, buildStatusOf, buildSummary, dueInfo, groupProjects, isExpanded, isOrphaned, lifeSignText, loadExpanded, percentOf, projectStats,
		saveExpanded, serverClock, showEmptyPage, sinceText, visibleSessions, waitingCard, type ExpandedMap
	} from '#lib/now.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import IdChip from './IdChip.svelte';
	import BuildStatusBadge from './BuildStatusBadge.svelte';
	import Radio from '@lucide/svelte/icons/radio';
	import CircleCheck from '@lucide/svelte/icons/circle-check';

	const activeKey = (item: NowActive) => `${item.kind}:${item.taskID ?? item.projectID + item.title}`;
	const sectionHead = 'text-muted-foreground mb-0.5 text-[11px] font-semibold tracking-wider uppercase';
	let data = $state<OverviewNow | null>(null);
	let failed = $state(false);
	let loading = $state(true);
	let live = $state(false);
	let expanded = $state<ExpandedMap>(loadExpanded());
	/** Re-evaluates relative ages and the quiet boundary without refetching (every 30 s). */
	let now = $state(new Date());
	let lastFetchAt: number | null = null;

	const groups = $derived(data ? groupProjects(data.projects ?? [], now) : { active: [], quiet: [] });
	/** Relative texts follow the server clock (kept running between fetches), not the device clock. */
	const ref = $derived(data && lastFetchAt !== null ? serverClock(data.serverTime, lastFetchAt, now.getTime()) : now);
	/** Block "Jetzt" (field `now`); null for an old server, then only the project sections are shown. */
	const block = $derived(blockOf(data, ref));
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

{#snippet activeItem(item: NowActive, testid: string, muted: boolean)}
	{@const pct = item.kind === 'task' ? percentOf(item) : null}
	{@const due = item.kind === 'task' ? dueInfo(item.dueAt, ref) : null}
	{@const since = sinceText(item, ref)}
	<li class="flex flex-col gap-1 py-2.5" data-testid={testid} data-kind={item.kind}>
		<div class="flex flex-wrap items-center gap-x-2 gap-y-1">
			{#if item.kind === 'task' && item.taskID}
				{@const id = item.taskID}
				<button type="button" class="focus-visible:ring-ring/50 rounded text-left text-sm font-semibold outline-none hover:underline focus-visible:ring-2 [overflow-wrap:anywhere]" onclick={() => cardDetail.open({ type: 'task', id })}>{item.title}</button>
			{:else}
				<span class="text-sm font-semibold [overflow-wrap:anywhere]">{item.title}</span>
				<Badge variant="outline">{t('now.block.session')}</Badge>
			{/if}
			<span class="text-muted-foreground text-[13px]">{item.projectName}</span>
			{#if item.worker}<Badge>{item.worker}</Badge>{/if}
		</div>
		{#if item.text}<p class={['text-[13px] [overflow-wrap:anywhere]', muted ? 'text-muted-foreground' : 'text-foreground']}>{item.text}</p>{/if}
		{#if pct !== null}
			<div class="bg-muted h-1.5 overflow-hidden rounded-full" role="progressbar" aria-valuenow={pct} aria-valuemin="0" aria-valuemax="100" aria-label={t('now.progress', { percent: pct })}>
				<div class={['h-full', muted ? 'bg-muted-foreground/50' : 'bg-ui-accent']} style:width="{pct}%"></div>
			</div>
		{/if}
		<p class="text-muted-foreground flex flex-wrap gap-x-2 text-[13px]" data-testid="{testid}-meta">
			{#if since}<span>{since}</span>{/if}
			<span>{lifeSignText(item, ref)}</span>
			{#if due}<span class={due.overdue ? 'text-destructive font-medium' : ''} data-testid="{testid}-due">{due.text}</span>{/if}
		</p>
	</li>
{/snippet}

{#snippet nowBlock(b: NonNullable<typeof block>)}
	<div class="mb-6 flex flex-col gap-4" data-testid="now-block">
		<section aria-labelledby="nb-running" class="bg-card rounded-xl border px-3.5 py-3 shadow-card" data-testid="now-running">
			<h3 id="nb-running" class="text-sm font-semibold">{t('now.block.running')}{#if b.counts.running > 0}<span class="text-muted-foreground ml-1.5 font-normal">({b.counts.running})</span>{/if}</h3>
			{#if b.running.length === 0}
				<p class="text-muted-foreground mt-1 text-sm" data-testid="now-running-empty">{t('now.block.runningEmpty')}</p>
			{:else}
				<ul class="divide-y">
					{#each uniqueKeys(b.running, activeKey) as { item, key } (key)}{@render activeItem(item, 'now-running-item', false)}{/each}
				</ul>
			{/if}
		</section>

		{#if b.waiting.length > 0}
			<section aria-labelledby="nb-waiting" data-testid="now-waiting">
				<h3 id="nb-waiting" class="mb-1.5 text-sm font-semibold">{t('now.block.waiting')}<span class="text-muted-foreground ml-1.5 font-normal">({b.counts.waiting})</span></h3>
				<ul class="flex flex-col gap-1.5">
					{#each b.waiting as w (w.kind + w.id)}
						<li class="bg-warning-soft flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg px-3 py-2 text-sm" data-testid="now-waiting-item" data-kind={w.kind}>
							<span class="min-w-0 flex-1 [overflow-wrap:anywhere]"><b>{w.kind === 'review' ? t('now.review') : t('now.question')}:</b> {w.text} <span class="text-muted-foreground">· {w.taskTitle} · {w.projectName} · {@render time(w.createdAt)}</span></span>
							<Button size="sm" variant={w.kind === 'review' ? 'outline' : 'default'} onclick={() => cardDetail.open(waitingCard(w))}>{w.kind === 'review' ? t('now.look') : t('now.answer')}</Button>
						</li>
					{/each}
				</ul>
			</section>
		{/if}

		{#if b.recentlyDone.length > 0}
			<section aria-labelledby="nb-done" data-testid="now-done">
				<h3 id="nb-done" class="mb-1 text-sm font-semibold">{t('now.block.done')}<span class="text-muted-foreground ml-1.5 text-[13px] font-normal">{t('now.block.doneHint')}</span></h3>
				<ul class="divide-y">
					{#each b.recentlyDone as d (d.taskID)}
						<li class="flex flex-wrap items-center gap-x-2 gap-y-0.5 py-1.5 text-sm" data-testid="now-done-item">
							<CircleCheck class="text-muted-foreground size-4 shrink-0" aria-hidden="true" />
							<button type="button" class="focus-visible:ring-ring/50 rounded text-left outline-none hover:underline focus-visible:ring-2 [overflow-wrap:anywhere]" onclick={() => cardDetail.open({ type: 'task', id: d.taskID })}>{d.title}</button>
							<span class="text-muted-foreground text-[13px]">{d.projectName} · {t('now.block.doneAgo', { time: when(d.doneAt) })}</span>
						</li>
					{/each}
				</ul>
			</section>
		{/if}

		{#if b.counts.silent > 0 || b.silent.length > 0}
			<details class="bg-muted/40 text-muted-foreground rounded-xl border border-dashed" data-testid="now-silent">
				<summary class="focus-visible:ring-ring/50 flex cursor-pointer items-center gap-2 rounded-xl px-3.5 py-2.5 text-sm font-medium outline-none focus-visible:ring-2 [&::-webkit-details-marker]:hidden">
					<span class="w-3 text-xs" aria-hidden="true">▸</span>
					<h3 class="text-sm font-medium">{t('now.block.silent', { count: b.counts.silent })}</h3>
				</summary>
				<div class="px-3.5 pb-3">
					<p class="mb-1 text-[13px]">{t('now.block.silentHint')}</p>
					<ul class="divide-y">
						{#each uniqueKeys(b.silent, activeKey) as { item, key } (key)}{@render activeItem(item, 'now-silent-item', true)}{/each}
					</ul>
				</div>
			</details>
		{/if}
	</div>
{/snippet}

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
			{#if visibleSessions(p).length > 0}
				<section aria-labelledby="ses-{p.projectID}" data-testid="now-sessions">
					<h3 id="ses-{p.projectID}" class={sectionHead}>{t('now.section.sessions')}</h3>
					<ul class="divide-y">
						{#each uniqueKeys(visibleSessions(p), (x) => x.sessionName) as { item: session, key } (key)}
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
						{#each uniqueKeys(p.builds, (x) => x.id ?? x.buildID) as { item: b, key } (key)}
							<li class="flex flex-wrap items-center gap-2 py-2 text-sm" data-testid="now-build">
								<span class="font-semibold [overflow-wrap:anywhere]">{buildSummary(b)}</span>
								<BuildStatusBadge status={b.status} />
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
							<li class="text-[13px]"><time class="text-muted-foreground mr-1.5" datetime={new Date(e.createdAt).toISOString()} title={e.createdAt}>{clock(e.createdAt)}</time>{#if e.kind === 'build.status_changed' && buildStatusOf(e.status)}{t(...buildEventHead(e.label))} <BuildStatusBadge status={e.status} />: {e.taskTitle}{:else}{eventLabel(e.kind)}: {e.taskTitle}{/if}</li>
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
		{#if showEmptyPage(data, block)}
			<div data-testid="now-empty">
				<EmptyState title={t('now.empty')} icon={Radio}><p>{t('now.emptyHint')}</p></EmptyState>
			</div>
		{:else}
			{#if block}
				{@render nowBlock(block)}
				{#if groups.active.length + groups.quiet.length > 0}<h3 class="mb-2 text-sm font-semibold">{t('now.block.projects')}</h3>{/if}
			{/if}
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
