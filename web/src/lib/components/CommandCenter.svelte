<script lang="ts" module>
	import type { CommandCenter as CC, Question as Q, Review as R, UpdateItem } from '#lib/api.js';
	/**
	 * Last answers per scope and view, kept across visits of the page: leaving /overview and coming back (or switching
	 * the tab) paints the previous data at once while the fresh data loads (stale-while-revalidate).
	 */
	const cache = new Map<string, { cc?: CC; questions?: Q[]; reviews?: R[]; moreUpdates?: UpdateItem[] }>();
</script>

<script lang="ts">
	import { onMount } from 'svelte';
	import { api, ApiError, type CommandCard, type CommandCenter, type CommandCenterParams, type LaneKey, type Question, type Review } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import {
		attentionCount,
		cardsOf,
		loadView,
		orderedLanes,
		saveView,
		sortUpdates,
		updateKind,
		type OverviewSection,
		type OverviewView
	} from '#lib/commandCenter.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import EmptyState from './app/EmptyState.svelte';
	import PageHeader from './app/PageHeader.svelte';
	import AgentBriefPanel from './overview/AgentBriefPanel.svelte';
	import OverviewCard from './overview/OverviewCard.svelte';
	import QuestionAnswer from './overview/QuestionAnswer.svelte';
	import SyncChip from './overview/SyncChip.svelte';
	import SyncDetail from './overview/SyncDetail.svelte';
	import RepositoryLine from './overview/RepositoryLine.svelte';
	import SyncList from './overview/SyncList.svelte';
	import ReviewDecision from './overview/ReviewDecision.svelte';
	import Columns3 from '@lucide/svelte/icons/columns-3';
	import List from '@lucide/svelte/icons/list';
	import RefreshCw from '@lucide/svelte/icons/refresh-cw';
	import Gauge from '@lucide/svelte/icons/gauge';

	/** Command center (ADR 0014): account-wide when `projectID` is absent, else one project with its sub-projects. */
	interface Props {
		projectID?: string;
	}
	let { projectID }: Props = $props();

	const PAGE = 50;

	let view = $state<OverviewView>(loadView());
	let section = $state<OverviewSection>('board');
	const cacheKey = (v: string, lane: string, kind: string, qf: boolean, srt: string, lim: number) => [projectID ?? 'account', v, lane, kind, qf, srt, lim].join('|');
	const seed = cache.get(cacheKey(loadView(), '', '', false, 'attention', PAGE));
	let cc = $state<CommandCenter | null>(seed?.cc ?? null);
	let questions = $state<Question[]>(seed?.questions ?? []);
	let reviews = $state<Review[]>(seed?.reviews ?? []);
	let loaded = $state(!!seed?.cc);
	/** The lists of the question and review tabs are only trusted once they were fetched (no "nothing here" flash while loading). */
	let questionsLoaded = $state(!!seed?.questions);
	let reviewsLoaded = $state(!!seed?.reviews);
	/** The updates tab shows a longer feed than the board's 10 entries; it is fetched on its own (no lanes, small answer). */
	let moreUpdates = $state<UpdateItem[] | null>(seed?.moreUpdates ?? null);
	let refreshing = $state(false);
	let showBrief = $state(false);
	let showSync = $state(false);
	// List view filters.
	let laneFilter = $state<'' | LaneKey>('');
	let kindFilter = $state<'' | 'task' | 'feature'>('');
	let questionFilter = $state(false);
	let sort = $state<NonNullable<CommandCenterParams['sort']>>('attention');
	let limit = $state(PAGE);
	let seq = 0;

	const scope = $derived(projectID ? 'project' : 'account');
	const project = $derived(projectID ? workspace.projects.find((p) => p.id === projectID) : undefined);
	/** Account scope lists only projects in the management view; classic projects are plain todo lists (per account). */
	const shown = (projectID: string | null | undefined) => scope === 'project' || workspace.modeOf(projectID) === 'management';
	const lanes = $derived(
		orderedLanes(cc?.lanes, (k) => t(`cc.lane.${k}` as MessageKey)).map((l) => {
			const cards = l.cards.filter((c) => shown(c.project.id));
			return { ...l, cards, count: Math.max(cards.length, l.count - (l.cards.length - cards.length)) };
		})
	);
	const items = $derived((cc?.items ?? []).filter((c) => shown(c.project.id)));
	const updates = $derived(sortUpdates((moreUpdates ?? cc?.updates ?? []).filter((u) => shown(u.projectID))));
	/** One visible list per section drives cards, counters and empty states (management projects only in account scope). */
	const visibleQuestions = $derived(questions.filter((q) => shown(q.projectID)));
	const visibleReviews = $derived(reviews.filter((r) => shown(r.projectID)));
	const boardEmpty = $derived(lanes.every((l) => l.cards.length === 0) && updates.length === 0);
	const summary = $derived(cc?.summary);
	const syncEntries = $derived((cc?.projects ?? []).filter((e) => shown(e.projectID)));
	/** Project scope: the entry of the project itself (the response may also list its sub-projects). */
	const ownSync = $derived(projectID ? syncEntries.find((e) => e.projectID === projectID) : undefined);

	function params(): CommandCenterParams {
		const base: CommandCenterParams = {
			scope: scope as 'account' | 'project',
			projectID,
			view,
			updatesLimit: 10
		};
		if (view === 'list') {
			return {
				...base,
				lane: laneFilter || undefined,
				kind: kindFilter || undefined,
				hasQuestion: questionFilter ? true : undefined,
				sort,
				limit
			};
		}
		return base;
	}

	const remember = (patch: { cc?: CC; questions?: Q[]; reviews?: R[]; moreUpdates?: UpdateItem[] }) => {
		const key = cacheKey(view, laneFilter, kindFilter, questionFilter, sort, limit);
		cache.set(key, { ...cache.get(key), ...patch });
	};
	let seqQuestions = 0;
	let seqReviews = 0;

	/** Board data and counters. The prefs refresh (derived modes) runs beside it, not before it. */
	async function fetchCC() {
		const my = ++seq;
		const [center] = await Promise.all([api.commandCenter(params()), scope === 'account' ? workspace.refreshPrefs(5000) : undefined]);
		if (my !== seq) return;
		if (!sameList([cc], [center])) cc = center;
		loaded = true;
		remember({ cc: center });
		if (scope === 'account') workspace.attention = center.summary;
	}
	let seqUpdates = 0;
	async function fetchUpdates() {
		const my = ++seqUpdates;
		const center = await api.commandCenter({ scope: scope as 'account' | 'project', projectID, view: 'list', limit: 1, updatesLimit: 50 });
		if (my !== seqUpdates) return;
		if (!sameList(moreUpdates ?? [], center.updates)) moreUpdates = center.updates;
		remember({ moreUpdates: center.updates });
		if (scope === 'account') workspace.attention = center.summary;
	}
	async function fetchQuestions() {
		const my = ++seqQuestions;
		const qs = await api.listQuestions({ projectID, includeSubprojects: true, state: 'open' });
		if (my !== seqQuestions) return;
		if (!sameList(questions, qs)) questions = qs;
		questionsLoaded = true;
		remember({ questions: qs });
	}
	async function fetchReviews() {
		const my = ++seqReviews;
		const rs = await api.listReviews({ projectID, state: 'pending' });
		if (my !== seqReviews) return;
		if (!sameList(reviews, rs)) reviews = rs;
		reviewsLoaded = true;
		remember({ reviews: rs });
	}
	/** Everything the open tab shows, in parallel. */
	function fetchAll() {
		return Promise.all([fetchCC(), section === 'questions' ? fetchQuestions() : undefined, section === 'reviews' ? fetchReviews() : undefined, section === 'updates' ? fetchUpdates() : undefined]);
	}
	/** Hover/focus on a tab: the list is fetched before the click (errors surface only when the tab is really opened). */
	function prefetch(id: OverviewSection) {
		if (id === 'questions' && !questionsLoaded) void fetchQuestions().catch(() => undefined);
		if (id === 'reviews' && !reviewsLoaded) void fetchReviews().catch(() => undefined);
	}

	/** Visible reload (manual refresh): errors become a notice. */
	function reload() {
		return attempt(() => fetchAll());
	}
	/** Background and post-action reload: never replaces a notice, only a lost session matters. */
	async function refresh() {
		if (refreshing) return;
		refreshing = true;
		try {
			await fetchAll();
		} catch (e) {
			if (e instanceof ApiError && e.isUnauthorized) auth.user = null;
		} finally {
			refreshing = false;
		}
	}

	// Board data: only filters, view, project and the updates length matter; switching tabs does not refetch it.
	$effect(() => {
		void projectID;
		void view;
		void laneFilter;
		void kindFilter;
		void questionFilter;
		void sort;
		void limit;
		void attempt(fetchCC);
	});
	$effect(() => {
		void projectID;
		if (section === 'questions') void attempt(fetchQuestions);
	});
	$effect(() => {
		void projectID;
		if (section === 'reviews') void attempt(fetchReviews);
	});
	$effect(() => {
		void projectID;
		if (section === 'updates') void attempt(fetchUpdates);
	});

	onMount(() => startLiveRefresh(refresh));

	function setView(v: OverviewView) {
		// The other layout has its own answer; show the one fetched last time right away.
		const known = cache.get(cacheKey(v, laneFilter, kindFilter, questionFilter, sort, PAGE))?.cc ?? null;
		cc = known;
		loaded = !!known;
		view = v;
		saveView(v);
		limit = PAGE;
	}
	/** Every card opens the shared large detail window. */
	function openCard(card: CommandCard) {
		cardDetail.open({ type: 'task', id: card.task.id });
	}
	function openTask(id: string, _title: string) {
		cardDetail.open({ type: 'task', id });
	}

	const sections: { id: OverviewSection; key: MessageKey }[] = [
		{ id: 'board', key: 'cc.section.board' },
		{ id: 'questions', key: 'cc.section.questions' },
		{ id: 'reviews', key: 'cc.section.reviews' },
		{ id: 'updates', key: 'cc.section.updates' }
	];
	const countOf = (id: OverviewSection) =>
		id === 'questions'
			? questionsLoaded && section === 'questions'
				? visibleQuestions.length
				: summary?.openQuestions
			: id === 'reviews'
				? reviewsLoaded && section === 'reviews'
					? visibleReviews.length
					: summary?.pendingReviews
				: undefined;
	/** Arrow keys, Home and End move between the tabs (roving tabindex); the focused tab is activated at once. */
	function tabKey(e: KeyboardEvent) {
		const i = sections.findIndex((s) => s.id === section);
		const next = e.key === 'ArrowRight' ? (i + 1) % sections.length : e.key === 'ArrowLeft' ? (i - 1 + sections.length) % sections.length : e.key === 'Home' ? 0 : e.key === 'End' ? sections.length - 1 : -1;
		if (next < 0) return;
		e.preventDefault();
		section = sections[next].id;
		document.getElementById(`cc-tab-${sections[next].id}`)?.focus();
	}
	const who = (name: string | null | undefined) => name || t('cc.update.anonymous');
</script>

{#snippet skeleton(wide: boolean)}
	<div class={['flex gap-3', wide ? 'items-start' : 'max-w-3xl flex-col']} role="status" aria-live="polite" data-testid="cc-loading">
		<span class="sr-only">{t('cc.loading')}</span>
		{#each [0, 1, 2] as i (i)}
			<div class={['bg-muted/60 motion-safe:animate-pulse rounded-xl border', wide ? 'h-48 w-72 shrink-0' : 'h-24 w-full']} aria-hidden="true"></div>
		{/each}
	</div>
{/snippet}

{#snippet controls()}
	<div class="flex flex-wrap items-center gap-2">
		{#if section === 'board'}
			<div class="inline-flex max-w-full flex-wrap rounded-lg border p-0.5" role="group" aria-label={t('cc.view')}>
				<Button size="sm" variant={view === 'kanban' ? 'default' : 'ghost'} aria-pressed={view === 'kanban'} data-testid="cc-view-kanban" onclick={() => setView('kanban')}>
					<Columns3 aria-hidden="true" />{t('cc.view.kanban')}
				</Button>
				<Button size="sm" variant={view === 'list' ? 'default' : 'ghost'} aria-pressed={view === 'list'} data-testid="cc-view-list" onclick={() => setView('list')}>
					<List aria-hidden="true" />{t('cc.view.list')}
				</Button>
			</div>
		{/if}
		<Button variant="outline" size="sm" aria-label={t('cc.refresh')} data-testid="cc-refresh" onclick={() => reload()}>
			<RefreshCw aria-hidden="true" /><span class="hidden sm:inline">{t('cc.refresh')}</span>
		</Button>
	</div>
{/snippet}

{#snippet card(c: CommandCard, showLane: boolean)}
	<OverviewCard card={c} {showLane} onopen={openCard} onchanged={refresh} />
{/snippet}

<section class="flex flex-col gap-4" data-testid="command-center" data-scope={scope}>
	{#if scope === 'account'}
		<PageHeader title={t('cc.title')} description={t('cc.hint')} testid="view-heading">
			{#snippet actions()}{@render controls()}{/snippet}
		</PageHeader>
	{:else}
		<div class="flex flex-wrap items-center justify-between gap-2">
			<p class="text-muted-foreground text-sm">{t('cc.hint')}</p>
			{@render controls()}
		</div>
	{/if}

	<div class="flex flex-wrap items-center gap-x-4 gap-y-2">
	<div class="flex flex-wrap items-center gap-x-4 gap-y-2" role="tablist" tabindex="-1" aria-label={t('cc.sections')} onkeydown={tabKey}>
		{#each sections as s (s.id)}
			{@const count = countOf(s.id)}
			<button
				type="button"
				role="tab"
				id="cc-tab-{s.id}"
				aria-selected={section === s.id}
				aria-controls="cc-panel"
				tabindex={section === s.id ? 0 : -1}
				data-testid="cc-section-{s.id}"
				class={[
					'-mb-px inline-flex min-h-9 items-center gap-1.5 border-b-2 px-1 text-sm font-medium transition-colors',
					section === s.id ? 'border-ui-accent text-foreground' : 'text-muted-foreground hover:text-foreground border-transparent'
				]}
				onclick={() => (section = s.id)}
				onpointerenter={() => prefetch(s.id)}
				onfocus={() => prefetch(s.id)}
			>
				{t(s.key)}
				{#if count}<Badge variant={s.id === 'board' ? 'default' : 'accent'} data-testid="cc-count-{s.id}">{count}</Badge>{/if}
			</button>
		{/each}
	</div>
		{#if scope === 'project'}
			<button
				type="button"
				class={['-mb-px ml-auto inline-flex min-h-9 items-center gap-1.5 border-b-2 px-1 text-sm font-medium', showBrief ? 'border-ui-accent' : 'text-muted-foreground border-transparent']}
				aria-pressed={showBrief}
				data-testid="cc-brief-toggle"
				onclick={() => (showBrief = !showBrief)}
			>
				<Gauge class="size-4" aria-hidden="true" />{t('cc.section.brief')}
			</button>
		{/if}
	</div>

	{#if scope === 'account'}
		<p class="text-muted-foreground text-xs" data-testid="cc-mode-filter">{t('mode.overviewFilter')}</p>
	{/if}

	{#if summary}
		<p class="text-muted-foreground flex flex-wrap gap-x-4 gap-y-1 text-xs" data-testid="cc-summary" data-attention={attentionCount(summary)}>
			<span>{t('cc.summary.agents', { count: summary.activeAgents })}</span>
			<span>{t('cc.summary.questions', { count: summary.openQuestions })}</span>
			<span>{t('cc.summary.reviews', { count: summary.pendingReviews })}</span>
			{#if summary.pendingConfirmations}<span class="text-warning" data-testid="cc-confirmations">{t('cc.summary.confirmations', { count: summary.pendingConfirmations })}</span>{/if}
			<span>{t('cc.summary.features', { count: summary.features })}</span>
			<span>{t('cc.summary.backlog', { count: summary.backlog })}</span>
			{#if scope === 'account' && summary.staleProjects}<span class="text-warning" data-testid="cc-stale-count">{t('sync.summary.stale', { count: summary.staleProjects })}</span>{/if}
			{#if cc}<span>{t('cc.updatedAt', { when: formatWhen(cc.generatedAt) })}</span>{/if}
		</p>
	{/if}

	{#if scope === 'project' && projectID && ownSync}
		<div class="flex flex-col gap-2" data-testid="cc-sync-head">
			<div class="flex flex-wrap items-center gap-2">
				<SyncChip sync={ownSync.sync} />
				<button
					type="button"
					class="text-ui-accent-ink min-h-9 text-xs underline underline-offset-2"
					aria-expanded={showSync}
					data-testid="cc-sync-toggle"
					onclick={() => (showSync = !showSync)}
				>
					{showSync ? t('sync.hideDetails') : t('sync.details')}
				</button>
			</div>
			<RepositoryLine {projectID} />
			{#if showSync}<SyncDetail {projectID} onchanged={refresh} />{/if}
		</div>
	{:else if scope === 'account' && section === 'board' && syncEntries.length > 0}
		<SyncList entries={syncEntries} onchanged={refresh} />
	{/if}

	{#if scope === 'project' && showBrief && projectID}
		<AgentBriefPanel {projectID} onchanged={refresh} />
	{/if}

	<div id="cc-panel" role="tabpanel" aria-labelledby="cc-tab-{section}" class="flex flex-col gap-4">
	{#if !loaded && section !== 'questions' && section !== 'reviews'}
		{@render skeleton(true)}
	{:else if section === 'board'}
		{#if view === 'kanban'}
			{#if boardEmpty}
				<EmptyState title={t('cc.empty')} icon={Gauge}><p>{t('cc.emptyHint')}</p></EmptyState>
			{/if}
			<div class="-mx-4 flex snap-x snap-mandatory items-start gap-3 overflow-x-auto px-4 pb-3 menu:mx-0 menu:px-0" data-testid="cc-board">
				{#each lanes as lane (lane.key)}
					<section class="bg-muted/40 flex w-[85vw] max-w-80 shrink-0 snap-start flex-col gap-2 rounded-xl border p-2 sm:w-72" aria-label={lane.title} data-testid="cc-lane" data-lane={lane.key}>
						<h3 class="flex items-center justify-between px-1 pt-0.5 text-sm font-semibold">
							{t(`cc.lane.${lane.key}` as MessageKey)}
							<Badge data-testid="cc-lane-count">{lane.count}</Badge>
						</h3>
						{#each lane.cards as c (c.task.id)}
							{@render card(c, false)}
						{:else}
							<p class="text-muted-foreground px-1 pb-2 text-xs">{t('cc.lane.empty')}</p>
						{/each}
						{#if lane.truncated}<p class="text-muted-foreground px-1 text-xs">{t('cc.lane.truncated', { shown: lane.cards.length, count: lane.count })}</p>{/if}
					</section>
				{/each}
			</div>
		{:else}
			<div class="flex flex-wrap items-end gap-3" data-testid="cc-filters">
				<label class="flex flex-col gap-1 text-xs font-medium">
					{t('cc.filter.lane')}
					<Select bind:value={laneFilter} data-testid="cc-filter-lane">
						<option value="">{t('cc.filter.laneAll')}</option>
						{#each ['running', 'question', 'review', 'ready', 'blocked', 'done'] as k (k)}<option value={k}>{t(`cc.lane.${k}` as MessageKey)}</option>{/each}
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">
					{t('cc.filter.kind')}
					<Select bind:value={kindFilter}>
						<option value="">{t('cc.filter.kindAll')}</option>
						<option value="task">{t('cc.filter.kindTask')}</option>
						<option value="feature">{t('cc.filter.kindFeature')}</option>
					</Select>
				</label>
				<label class="flex flex-col gap-1 text-xs font-medium">
					{t('cc.sort')}
					<Select bind:value={sort}>
						{#each ['attention', 'updated', 'due', 'progress', 'title'] as k (k)}<option value={k}>{t(`cc.sort.${k}` as MessageKey)}</option>{/each}
					</Select>
				</label>
				<label class="flex min-h-9 items-center gap-2 text-sm"><input type="checkbox" bind:checked={questionFilter} />{t('cc.filter.question')}</label>
			</div>
			{#if items.length === 0}
				<EmptyState title={t('cc.empty')} icon={Gauge}><p>{t('cc.emptyHint')}</p></EmptyState>
			{:else}
				<p class="text-muted-foreground text-xs" data-testid="cc-total">{t('cc.list.total', { count: cc?.total ?? items.length })}</p>
				<div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3" data-testid="cc-list">
					{#each items as c (c.task.id)}
						{@render card(c, true)}
					{/each}
				</div>
				{#if (cc?.total ?? 0) > items.length}
					<div><Button variant="outline" onclick={() => (limit += PAGE)}>{t('common.more')}</Button></div>
				{/if}
			{/if}
		{/if}
	{:else if section === 'questions' && !questionsLoaded}
		{@render skeleton(false)}
	{:else if section === 'reviews' && !reviewsLoaded}
		{@render skeleton(false)}
	{:else if section === 'questions'}
		{#if visibleQuestions.length === 0}
			<EmptyState title={t('cc.question.empty')} icon={Gauge}><p>{t('cc.question.emptyHint')}</p></EmptyState>
		{/if}
		<ul class="flex max-w-3xl flex-col gap-3" data-testid="cc-questions">
			{#each visibleQuestions as q (q.id)}
				<li class="flex flex-col gap-1">
					<QuestionAnswer
						id={q.id}
						prompt={q.prompt}
						options={q.options}
						blocking={q.blocking}
						askedBy={q.askedByLabel ?? q.askedByName}
						context={t('cc.question.in', { task: q.taskTitle ?? '', project: q.projectName ?? '' })}
						onopen={() => openTask(q.taskID, q.taskTitle ?? '')}
						onanswered={refresh}
					/>
				</li>
			{/each}
		</ul>
	{:else if section === 'reviews'}
		{#if visibleReviews.length === 0}
			<EmptyState title={t('cc.review.empty')} icon={Gauge}><p>{t('cc.review.emptyHint')}</p></EmptyState>
		{/if}
		<ul class="flex max-w-3xl flex-col gap-3" data-testid="cc-reviews">
			{#each visibleReviews as r (r.id)}
				<li class="flex flex-col gap-1">
					<ReviewDecision
						taskID={r.taskID}
						summary={r.summary}
						requestedBy={r.requestedByLabel}
						context={t('cc.question.in', { task: r.taskTitle ?? '', project: r.projectName ?? '' })}
						onopen={() => openTask(r.taskID, r.taskTitle ?? '')}
						ondecided={refresh}
					/>
				</li>
			{/each}
		</ul>
	{:else if section === 'updates'}
		{#if updates.length === 0}
			<EmptyState title={t('cc.updates.empty')} icon={Gauge}><p>{t('cc.updates.emptyHint')}</p></EmptyState>
		{/if}
		<ul class="flex max-w-3xl flex-col divide-y rounded-xl border" data-testid="cc-updates">
			{#each updates as u (u.id)}
				<li class="flex flex-col gap-0.5 p-3 text-sm" data-testid="cc-update" data-kind={u.kind}>
					<p class="text-muted-foreground text-xs">
						{t(`cc.update.${updateKind(u.kind)}` as MessageKey, { who: who(u.actorName) })} · {formatWhen(u.createdAt)}
					</p>
					<button type="button" class="text-left font-medium hover:underline" onclick={() => openTask(u.taskID, u.taskTitle)}>{u.taskTitle}</button>
					<p class="text-muted-foreground text-xs">{u.projectName}</p>
					{#if u.text}<p class="break-words whitespace-pre-wrap">{u.text}</p>{/if}
				</li>
			{/each}
		</ul>
	{/if}
	</div>
</section>
