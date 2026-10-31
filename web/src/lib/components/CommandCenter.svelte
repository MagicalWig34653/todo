<script lang="ts">
	import { onMount } from 'svelte';
	import { api, ApiError, type CommandCard, type CommandCenter, type CommandCenterParams, type LaneKey, type Question, type Review } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import {
		REFRESH_MS,
		attentionCount,
		cardsOf,
		isEmptyOverview,
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
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Dialog from './app/Dialog.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import PageHeader from './app/PageHeader.svelte';
	import AgentBriefPanel from './overview/AgentBriefPanel.svelte';
	import CardDetail from './overview/CardDetail.svelte';
	import OverviewCard from './overview/OverviewCard.svelte';
	import QuestionAnswer from './overview/QuestionAnswer.svelte';
	import SyncChip from './overview/SyncChip.svelte';
	import SyncDetail from './overview/SyncDetail.svelte';
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
	let cc = $state<CommandCenter | null>(null);
	let questions = $state<Question[]>([]);
	let reviews = $state<Review[]>([]);
	let loaded = $state(false);
	let refreshing = $state(false);
	let showBrief = $state(false);
	let showSync = $state(false);
	// List view filters.
	let laneFilter = $state<'' | LaneKey>('');
	let kindFilter = $state<'' | 'task' | 'feature'>('');
	let questionFilter = $state(false);
	let sort = $state<NonNullable<CommandCenterParams['sort']>>('attention');
	let limit = $state(PAGE);
	// Detail dialog.
	let detail = $state<CommandCard | { id: string; title: string } | null>(null);
	let detailOpen = $state(false);
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
	const updates = $derived(sortUpdates((cc?.updates ?? []).filter((u) => shown(u.projectID))));
	const summary = $derived(cc?.summary);
	const syncEntries = $derived((cc?.projects ?? []).filter((e) => shown(e.projectID)));
	/** Project scope: the entry of the project itself (the response may also list its sub-projects). */
	const ownSync = $derived(projectID ? syncEntries.find((e) => e.projectID === projectID) : undefined);

	function params(): CommandCenterParams {
		const base: CommandCenterParams = {
			scope: scope as 'account' | 'project',
			projectID,
			view,
			updatesLimit: section === 'updates' ? 50 : 10
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

	async function fetchAll() {
		const my = ++seq;
		const [center, qs, rs] = await Promise.all([
			api.commandCenter(params()),
			section === 'questions' ? api.listQuestions({ projectID, includeSubprojects: true, state: 'open' }) : Promise.resolve(null),
			section === 'reviews' ? api.listReviews({ projectID, state: 'pending' }) : Promise.resolve(null)
		]);
		if (my !== seq) return;
		cc = center;
		if (qs) questions = qs;
		if (rs) reviews = rs;
		loaded = true;
		if (scope === 'account') workspace.attention = center.summary;
	}

	/** Visible reload (initial, filter change): errors become a notice. */
	function reload() {
		return attempt(async () => {
			if (scope === 'account') await workspace.refreshPrefs();
			await fetchAll();
		});
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

	$effect(() => {
		void projectID;
		void view;
		void section;
		void laneFilter;
		void kindFilter;
		void questionFilter;
		void sort;
		void limit;
		void reload();
	});

	onMount(() => {
		const timer = setInterval(() => {
			if (document.visibilityState === 'visible') void refresh();
		}, REFRESH_MS);
		const onVisible = () => {
			if (document.visibilityState === 'visible') void refresh();
		};
		window.addEventListener('focus', onVisible);
		document.addEventListener('visibilitychange', onVisible);
		return () => {
			clearInterval(timer);
			window.removeEventListener('focus', onVisible);
			document.removeEventListener('visibilitychange', onVisible);
		};
	});

	function setView(v: OverviewView) {
		view = v;
		saveView(v);
		limit = PAGE;
	}
	function openCard(card: CommandCard) {
		detail = card;
		detailOpen = true;
	}
	function openTask(id: string, title: string) {
		detail = { id, title };
		detailOpen = true;
	}
	const detailTaskID = (d: NonNullable<typeof detail>) => ('task' in d ? d.task.id : d.id);
	const detailTitle = (d: NonNullable<typeof detail>) => ('task' in d ? d.task.title : d.title);

	const sections: { id: OverviewSection; key: MessageKey }[] = [
		{ id: 'board', key: 'cc.section.board' },
		{ id: 'questions', key: 'cc.section.questions' },
		{ id: 'reviews', key: 'cc.section.reviews' },
		{ id: 'updates', key: 'cc.section.updates' }
	];
	const countOf = (id: OverviewSection) => (id === 'questions' ? summary?.openQuestions : id === 'reviews' ? summary?.pendingReviews : undefined);
	const who = (name: string | null | undefined) => name || t('cc.update.anonymous');
</script>

{#snippet controls()}
	<div class="flex flex-wrap items-center gap-2">
		{#if section === 'board'}
			<div class="inline-flex rounded-lg border p-0.5" role="group" aria-label={t('cc.view')}>
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

	<div class="flex flex-wrap items-center gap-x-4 gap-y-2" role="tablist" aria-label={t('cc.sections')}>
		{#each sections as s (s.id)}
			{@const count = countOf(s.id)}
			<button
				type="button"
				role="tab"
				aria-selected={section === s.id}
				data-testid="cc-section-{s.id}"
				class={[
					'-mb-px inline-flex min-h-9 items-center gap-1.5 border-b-2 px-1 text-sm font-medium transition-colors',
					section === s.id ? 'border-ui-accent text-foreground' : 'text-muted-foreground hover:text-foreground border-transparent'
				]}
				onclick={() => (section = s.id)}
			>
				{t(s.key)}
				{#if count}<Badge variant={s.id === 'board' ? 'default' : 'accent'} data-testid="cc-count-{s.id}">{count}</Badge>{/if}
			</button>
		{/each}
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
			{#if showSync}<SyncDetail {projectID} onchanged={refresh} />{/if}
		</div>
	{:else if scope === 'account' && section === 'board' && syncEntries.length > 0}
		<SyncList entries={syncEntries} onchanged={refresh} />
	{/if}

	{#if scope === 'project' && showBrief && projectID}
		<AgentBriefPanel {projectID} onchanged={refresh} />
	{/if}

	{#if !loaded}
		<p class="text-muted-foreground text-sm">{t('cc.loading')}</p>
	{:else if section === 'board'}
		{#if view === 'kanban'}
			{#if isEmptyOverview(cc)}
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
	{:else if section === 'questions'}
		{#if questions.length === 0}
			<EmptyState title={t('cc.question.empty')} icon={Gauge}><p>{t('cc.question.emptyHint')}</p></EmptyState>
		{/if}
		<ul class="flex max-w-3xl flex-col gap-3" data-testid="cc-questions">
			{#each questions.filter((q) => shown(q.projectID)) as q (q.id)}
				<li class="flex flex-col gap-1">
					<QuestionAnswer
						id={q.id}
						prompt={q.prompt}
						options={q.options}
						blocking={q.blocking}
						askedBy={q.askedByLabel ?? q.askedByName}
						context={t('cc.question.in', { task: q.taskTitle ?? '', project: q.projectName ?? '' })}
						onanswered={refresh}
					/>
					<button type="button" class="text-ui-accent-ink self-start text-xs underline underline-offset-2" onclick={() => openTask(q.taskID, q.taskTitle ?? '')}>{t('cc.card.open')}</button>
				</li>
			{/each}
		</ul>
	{:else if section === 'reviews'}
		{#if reviews.length === 0}
			<EmptyState title={t('cc.review.empty')} icon={Gauge}><p>{t('cc.review.emptyHint')}</p></EmptyState>
		{/if}
		<ul class="flex max-w-3xl flex-col gap-3" data-testid="cc-reviews">
			{#each reviews.filter((r) => shown(r.projectID)) as r (r.id)}
				<li class="flex flex-col gap-1">
					<ReviewDecision
						taskID={r.taskID}
						summary={r.summary}
						requestedBy={r.requestedByLabel}
						context={t('cc.question.in', { task: r.taskTitle ?? '', project: r.projectName ?? '' })}
						ondecided={refresh}
					/>
					<button type="button" class="text-ui-accent-ink self-start text-xs underline underline-offset-2" onclick={() => openTask(r.taskID, r.taskTitle ?? '')}>{t('cc.card.open')}</button>
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
</section>

<Dialog bind:open={detailOpen} title={detail ? t('cc.detail.title', { title: detailTitle(detail) }) : t('cc.title')} class="max-w-2xl" testid="cc-detail-dialog">
	{#if detail}<CardDetail taskID={detailTaskID(detail)} onchanged={refresh} />{/if}
</Dialog>
