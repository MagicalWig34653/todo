<script lang="ts">
	import type { OverviewProject } from '#lib/api.js';
	import { relativeWhen } from '#lib/cardRef.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { de } from '#lib/i18n/de.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { uniqueKeys } from '#lib/keys.js';
	import {
		BUILD_FILE_LIMIT, NOW_EVENTS_FIRST, buildCommit, buildEventHead, buildStatusOf, buildSummary, groupBuilds, isOrphaned, percentOf, projectStats, visibleSessions
	} from '#lib/now.js';
	import { previewText } from '#lib/previewText.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import IdChip from '../IdChip.svelte';
	import BuildStatusBadge from '../BuildStatusBadge.svelte';
	import NowWaitingList from './NowWaitingList.svelte';
	import ProjectMark from './ProjectMark.svelte';

	/** One project as a compact row; its sections appear when opened. The open state belongs to the page (stored per device). */
	let { project: p, quiet, open, now, ontoggle }: { project: OverviewProject; quiet: boolean; open: boolean; now: Date; ontoggle: (e: Event) => void } = $props();

	const sectionHead = 'text-muted-foreground mb-1 text-[11px] font-semibold tracking-wider uppercase';
	const s = $derived(projectStats(p));
	const sessions = $derived(visibleSessions(p));
	const builds = $derived(groupBuilds(p.builds));
	const waiting = $derived(
		[
			...p.openQuestions.map((q) => ({ ...q, kind: 'question' as const, projectID: p.projectID })),
			...p.pendingReviews.map((r) => ({ ...r, kind: 'review' as const, projectID: p.projectID }))
		]
	);
	let allEvents = $state(false);
	const events = $derived(allEvents ? p.recentActivity : p.recentActivity.slice(0, NOW_EVENTS_FIRST));

	const plural = (n: number, one: MessageKey, many: MessageKey) => (n === 1 ? t(one) : t(many, { count: n }));
	const when = (iso: string) => relativeWhen(iso, now);
	const eventLabel = (kind: string) => (`activity.kind.${kind}` in de ? t(`activity.kind.${kind}` as MessageKey) : t('now.event.unknown', { kind }));
	const clock = (iso: string) => new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
</script>

{#snippet time(iso: string)}<time datetime={new Date(iso).toISOString()} title={iso}>{when(iso)}</time>{/snippet}

<details class={['group rounded-xl border', quiet ? 'bg-transparent' : 'bg-card shadow-card']} {open} data-testid="now-project" data-project={p.projectID} data-quiet={quiet}>
	<summary onclick={ontoggle} class="focus-visible:ring-ring/50 hover:bg-muted/50 flex min-h-11 cursor-pointer items-start gap-2 rounded-xl px-3 py-2.5 outline-none focus-visible:ring-2 [&::-webkit-details-marker]:hidden">
		<ChevronRight class="text-muted-foreground mt-1 size-4 shrink-0 group-open:rotate-90" aria-hidden="true" />
		<span class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 gap-y-1">
			<span class="flex min-w-0 flex-1 basis-40 items-center gap-1.5">
				<ProjectMark id={p.projectID} />
				<span class={['min-w-0 [overflow-wrap:anywhere]', quiet ? 'text-muted-foreground font-medium' : 'font-semibold']} data-testid="now-project-name">{p.projectName}</span>
			</span>
			{#if s.running > 0}<Badge variant="accent" data-testid="now-stat-running">{plural(s.running, 'now.stat.runningOne', 'now.stat.running')}</Badge>{/if}
			{#if s.sessions > 0}<Badge variant="success" data-testid="now-stat-sessions">{plural(s.sessions, 'now.stat.sessionsOne', 'now.stat.sessions')}</Badge>{/if}
			{#if s.waiting > 0}<Badge variant="warning" data-testid="now-stat-waiting">{plural(s.waiting, 'now.stat.waitingOne', 'now.stat.waiting')}</Badge>{/if}
			{#if s.builds > 0}<Badge data-testid="now-stat-builds">{plural(s.builds, 'now.stat.buildsOne', 'now.stat.builds')}</Badge>{/if}
			{#if s.running + s.sessions + s.waiting + s.builds === 0}<span class="text-muted-foreground text-xs">{t('now.nothingOpen')}</span>{/if}
			<span class="text-muted-foreground text-xs">{t('now.lastActivity', { time: when(p.lastActivityAt) })}</span>
		</span>
	</summary>
	<div class="flex flex-col gap-4 border-t px-3 pt-3 pb-3.5">
		{#if p.runningTasks.length > 0}
			<section aria-labelledby="run-{p.projectID}" data-testid="now-running">
				<h4 id="run-{p.projectID}" class={sectionHead}>{t('now.section.running')}</h4>
				<ul class="divide-y">
					{#each uniqueKeys(p.runningTasks, (x) => x.taskID) as { item: task, key } (key)}
						{@const pct = percentOf(task)}
						<li class="flex flex-col gap-1 py-2" data-testid="now-running-item">
							<div class="flex flex-wrap items-center gap-2">
								<button type="button" class="focus-visible:ring-ring/50 max-menu:min-h-10 rounded text-left text-sm font-semibold outline-none hover:underline focus-visible:ring-2 [overflow-wrap:anywhere]" onclick={() => cardDetail.open({ type: 'task', id: task.taskID })}>{task.title}</button>
								<Badge class="max-w-full"><span class="truncate">{task.worker || t('now.noWorker')}</span></Badge>
								<IdChip id={task.taskID} subtle />
							</div>
							{#if pct !== null}
								<div class="bg-muted h-1.5 overflow-hidden rounded-full" role="progressbar" aria-valuenow={pct} aria-valuemin="0" aria-valuemax="100" aria-label={t('now.progress', { percent: pct })}>
									<div class="bg-ui-accent h-full" style:width="{pct}%"></div>
								</div>
							{/if}
							<p class="text-muted-foreground line-clamp-3 text-[13px] [overflow-wrap:anywhere]">
								{#if pct !== null}{t('now.percent', { percent: pct })} · {/if}{#if task.lastProgress}{@render time(task.lastProgress.at)} · „{previewText(task.lastProgress.note)}“{:else}{t('now.noNote')}{/if}
							</p>
						</li>
					{/each}
				</ul>
			</section>
		{/if}
		{#if sessions.length > 0}
			<section aria-labelledby="ses-{p.projectID}" data-testid="now-sessions">
				<h4 id="ses-{p.projectID}" class={sectionHead}>{t('now.section.sessions')}</h4>
				<ul class="divide-y">
					{#each uniqueKeys(sessions, (x) => x.sessionName) as { item: session, key } (key)}
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
		{#if waiting.length > 0}
			<section class="@container" aria-labelledby="wait-{p.projectID}" data-testid="now-waiting">
				<h4 id="wait-{p.projectID}" class={sectionHead}>{t('now.section.waiting')}</h4>
				<NowWaitingList items={waiting} {now} />
			</section>
		{/if}
		{#if builds.length > 0}
			<section aria-labelledby="bld-{p.projectID}" data-testid="now-builds">
				<h4 id="bld-{p.projectID}" class={sectionHead}>{t('now.section.builds')}</h4>
				<ul class="divide-y">
					{#each builds as b (b.key)}
						<li class="flex flex-wrap items-center gap-x-2 gap-y-0.5 py-2 text-sm" data-testid="now-build">
							<span class="font-semibold [overflow-wrap:anywhere]">{buildSummary(b)}</span>
							<BuildStatusBadge status={b.status} />
							{#if buildCommit(b)}<code class="text-muted-foreground font-mono text-[12px]" title={b.commit} data-testid="now-build-commit">{buildCommit(b)}</code>{/if}
							<span class="text-muted-foreground text-[13px]">{plural(b.files, 'now.build.filesOne', 'now.build.files')} · {@render time(b.createdAt)}</span>
						</li>
					{/each}
				</ul>
				{#if p.builds.length >= BUILD_FILE_LIMIT}<p class="text-muted-foreground text-xs">{t('now.build.limit', { count: BUILD_FILE_LIMIT })}</p>{/if}
			</section>
		{/if}
		{#if p.recentActivity.length > 0}
			<section aria-labelledby="evt-{p.projectID}" data-testid="now-events">
				<h4 id="evt-{p.projectID}" class={sectionHead}>{t('now.section.events')}</h4>
				<ul class="border-border ml-1 flex flex-col gap-0.5 border-l-2 pl-3">
					{#each events as e, i (e.createdAt + e.kind + i)}
						<li class="text-[13px] [overflow-wrap:anywhere]" data-testid="now-event"><time class="text-muted-foreground mr-1.5" datetime={new Date(e.createdAt).toISOString()} title={e.createdAt}>{clock(e.createdAt)}</time>{#if e.kind === 'build.status_changed' && buildStatusOf(e.status)}{t(...buildEventHead(e.label))} <BuildStatusBadge status={e.status} />: {e.taskTitle}{:else}{eventLabel(e.kind)}: {e.taskTitle}{/if}</li>
					{/each}
				</ul>
				{#if p.recentActivity.length > NOW_EVENTS_FIRST}
					<Button variant="ghost" size="sm" class="max-menu:h-10 mt-1" aria-expanded={allEvents} data-testid="now-events-toggle" onclick={() => (allEvents = !allEvents)}>{allEvents ? t('now.events.less') : t('now.events.more')}</Button>
				{/if}
			</section>
		{/if}
	</div>
</details>
