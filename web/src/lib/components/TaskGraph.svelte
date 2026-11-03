<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import GitBranch from '@lucide/svelte/icons/git-branch';
	import Tag from '@lucide/svelte/icons/tag';
	import { api, type Project, type Task } from '#lib/api.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { descendantIDs } from '#lib/projectState.js';
	import { edgePath, filterGraph, layoutGraph, limitLayout, neighbourNode, shortID, type GraphInput, type GraphTask, type LaidNode } from '#lib/taskGraph.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Select } from '#lib/components/ui/select/index.js';

	let { project }: { project: Project } = $props();

	const LANE_W = 18;
	const PAGE = 300;
	const MAX_PROJECTS = 40;
	/** One hue per palette index; chosen to stay apart from each other (orange, green, cyan, pink, yellow, violet, red, blue). */
	const LANE_HUES = [45, 150, 205, 335, 95, 285, 20, 250];

	let includeSub = $state(false);
	let featuresOnly = $state(false);
	let hideDone = $state<string>('30');
	let limit = $state(PAGE);
	let loaded = $state(false);
	let rawTasks = $state<GraphTask[]>([]);
	let extraTasks = $state<GraphTask[]>([]);
	let edges = $state<GraphInput['edges']>([]);
	let milestones = $state<GraphInput['milestones']>([]);
	let projectNames = $state<Record<string, string>>({});
	let pitch = $state(40);
	let focusID = $state<string | null>(null);
	let seq = 0;

	const projectKey = $derived(project.id);

	async function load() {
		const my = ++seq;
		const id = project.id;
		const ids = includeSub ? [id, ...descendantIDs(workspace.projects, id).slice(0, MAX_PROJECTS - 1)] : [id];
		const [lists, graph, ms] = await Promise.all([
			Promise.all(ids.map((pid) => api.listTasks(pid))),
			api.taskGraph(id, includeSub),
			api.milestones(id)
		]);
		if (my !== seq) return;
		const facts = new Map(graph.tasks.map((x) => [x.taskID, x]));
		const milestoneOf = new Map<string, string>();
		for (const m of ms) for (const task of m.tasks) milestoneOf.set(task.id, m.milestone.id);
		const toGraph = (task: Task): GraphTask => {
			const f = facts.get(task.id);
			return {
				id: task.id,
				title: task.title,
				status: task.status,
				projectID: task.projectID,
				isFeature: f?.kind === 'feature',
				dueAt: task.planning?.dueAt ?? null,
				doneAt: task.status === 'done' ? (f?.updatedAt ?? null) : null,
				updatedAt: f?.updatedAt ?? null,
				createdAt: f?.createdAt ?? null,
				parentID: f?.parentTaskID ?? null,
				agent: f?.claimedLabel ?? null,
				milestoneID: milestoneOf.get(task.id) ?? null
			};
		};
		const mine = lists.flat().map(toGraph);
		const known = new Set(mine.map((x) => x.id));
		// Milestone members outside the loaded projects only count for the milestone's progress.
		extraTasks = ms.flatMap((m) => m.tasks).filter((x) => !known.has(x.id)).map(toGraph);
		rawTasks = mine;
		edges = graph.edges;
		milestones = ms.map((m) => ({ id: m.milestone.id, title: m.milestone.title, dueAt: m.milestone.dueAt ?? null }));
		projectNames = Object.fromEntries([[id, project.name], ...workspace.projects.map((p) => [p.id, p.name] as const)]);
		loaded = true;
	}
	$effect(() => {
		void projectKey;
		void includeSub;
		void ui.changeTick;
		untrack(() => attempt(load));
	});
	$effect(() => {
		void projectKey;
		loaded = false;
		rawTasks = [];
		edges = [];
		limit = PAGE;
	});
	onMount(() => startLiveRefresh(() => load().catch(() => {}), { guardEditing: true }));

	const now = $derived(new Date(Date.now() - (Date.now() % 60000)));
	const full = $derived.by(() => {
		const full: GraphInput = { tasks: [...rawTasks, ...extraTasks], edges, milestones };
		const shown = filterGraph(
			{ tasks: rawTasks, edges, milestones },
			{ featuresOnly, hideDoneDays: hideDone === 'never' ? null : Number(hideDone), now }
		);
		return layoutGraph(shown, now, full);
	});
	const layout = $derived(limitLayout(full, limit));
	const hiddenRows = $derived(full.rows.length - layout.rows.length);
	const titleOf = $derived(new Map(layout.nodes.map((n) => [n.task.id, n.task.title])));
	const gutter = $derived(layout.laneCount * LANE_W + 14);
	const x = (lane: number) => 9 + lane * LANE_W + LANE_W / 2;
	const y = (row: number) => row * pitch + pitch / 2;
	const hue = (color: number) => LANE_HUES[color % LANE_HUES.length];
	const lane = (color: number) => `oklch(0.68 0.17 ${hue(color)})`;
	const nodeByID = $derived(new Map(layout.nodes.map((n) => [n.task.id, n])));
	const focusEdges = $derived(new Set(layout.edges.filter((e) => e.taskID === focusID || e.targetID === focusID).map((e) => `${e.taskID}>${e.targetID}`)));
	const pill = (color: number) => `--lc: oklch(0.68 0.17 ${hue(color)})`;

	const statusLabel = (s: GraphTask['status']) => t(`status.${s}` as MessageKey);
	function waitingText(n: LaidNode): string {
		const first = titleOf.get(n.waitingFor[0]) ?? '';
		return n.waitingFor.length > 1
			? t('graph.waitingForMore', { title: first, count: n.waitingFor.length - 1 })
			: t('graph.waitingFor', { title: first });
	}
	function whenText(n: LaidNode): string {
		const at = n.when.at ? formatWhen(n.when.at) : '';
		if (!at) return '';
		return t(n.when.kind === 'done' ? 'graph.when.done' : n.when.kind === 'due' ? 'graph.when.due' : 'graph.when.updated', { date: at });
	}
	function open(n: LaidNode) {
		cardDetail.open({ type: 'task', id: n.task.id }, layout.nodes.map((m) => ({ type: 'task' as const, id: m.task.id })));
	}
	let host: HTMLElement | undefined = $state();
	function onkey(e: KeyboardEvent, n: LaidNode) {
		const dir = ({ ArrowUp: 'up', ArrowDown: 'down', Home: 'first', End: 'last' } as const)[e.key as 'ArrowUp'];
		if (!dir) return;
		const next = neighbourNode(layout, n.task.id, dir);
		if (!next) return;
		e.preventDefault();
		host?.querySelector<HTMLElement>(`[data-node="${next}"]`)?.focus();
	}
	const nodeStroke = (n: LaidNode) => (n.overdue ? 'var(--destructive)' : n.blocked ? 'var(--warning)' : lane(n.color));
	const nodeFill = (n: LaidNode) => (n.task.status === 'open' ? 'var(--background)' : n.task.status === 'in_review' ? 'var(--warning)' : lane(n.color));
	const rowBg = (i: number) => (i % 2 === 1 ? 'bg-muted/40' : '');
</script>

<section class="flex min-w-0 flex-col gap-3" data-testid="task-graph" aria-label={t('graph.title')}>
	<p class="text-muted-foreground max-w-prose text-sm">{t('graph.hint')}</p>
	<div class="flex flex-wrap items-center gap-x-5 gap-y-2 text-sm" role="group" aria-label={t('graph.filters')}>
		<label class="flex min-h-9 items-center gap-2">
			<Checkbox checked={includeSub} onchange={(e) => (includeSub = e.currentTarget.checked)} data-testid="graph-sub" />{t('graph.sub')}
		</label>
		<label class="flex min-h-9 items-center gap-2">
			<Checkbox checked={featuresOnly} onchange={(e) => (featuresOnly = e.currentTarget.checked)} data-testid="graph-features" />{t('graph.features')}
		</label>
		<label class="flex min-h-9 items-center gap-2">
			<span>{t('graph.hideDone')}</span>
			<Select class="w-auto" value={hideDone} onchange={(e) => (hideDone = e.currentTarget.value)} data-testid="graph-hide-done">
				<option value="never">{t('graph.hideDone.never')}</option>
				{#each [7, 14, 30, 90] as days (days)}<option value={String(days)}>{t('graph.hideDone.days', { days })}</option>{/each}
			</Select>
		</label>
	</div>

	{#if !loaded}
		<p class="text-muted-foreground text-sm" role="status">{t('graph.loading')}</p>
	{:else if layout.nodes.length === 0}
		<p class="text-muted-foreground text-sm" data-testid="graph-empty">{rawTasks.length > 0 ? t('graph.emptyFiltered') : t('graph.empty')}</p>
	{:else}
		<div class="min-w-0 overflow-x-auto rounded-xl border" data-testid="graph-scroll" tabindex="-1">
			<div bind:this={host} class="relative min-w-[22rem]" style:--graph-row="2.5rem" role="list" aria-label={t('graph.canvas', { count: layout.nodes.length })}>
				<div class="pointer-events-none invisible absolute w-0" style:height="var(--graph-row)" bind:clientHeight={pitch} aria-hidden="true"></div>
				<svg class="pointer-events-none absolute top-0 left-0 z-10" width={gutter} height={layout.rows.length * pitch} aria-hidden="true" data-testid="graph-svg">
					{#each layout.edges as e (e.kind + e.taskID + e.targetID)}
						{@const hot = focusEdges.has(`${e.taskID}>${e.targetID}`)}
						<path
							d={edgePath(e.points, x, y)}
							fill="none"
							stroke={e.blocking ? 'var(--warning)' : lane(e.color)}
							stroke-width={hot ? 3.5 : 2.25}
							stroke-linecap="round"
							stroke-dasharray={e.blocking ? '4 3' : undefined}
							data-edge="{e.taskID}>{e.targetID}"
							data-kind={e.kind}
							data-blocking={e.blocking}
						/>
					{/each}
					{#each layout.nodes as n (n.task.id)}
						<g transform="translate({x(n.lane)} {y(n.row)})" data-lane={n.lane}>
							{#if n.merge}
								<circle r="7" fill="var(--background)" stroke={nodeStroke(n)} stroke-width="2.25" />
								<path d="M-3.5 0h7M0 -3.5v7" stroke={nodeStroke(n)} stroke-width="1.75" stroke-linecap="round" />
							{:else}
								<circle r={n.task.isFeature ? 6 : 4.5} fill={nodeFill(n)} stroke={nodeStroke(n)} stroke-width={n.task.status === 'open' || n.blocked || n.overdue ? 2.25 : 1.5} />
							{/if}
						</g>
					{/each}
				</svg>

				{#each layout.rows as r, i (i)}
					{#if r.kind === 'now'}
						<div role="listitem" class="relative flex items-center" style:height="var(--graph-row)" data-testid="graph-now">
							<div class="bg-ui-accent/60 absolute right-0 left-0 h-px" style:left="{gutter}px" aria-hidden="true"></div>
							<span class="bg-background text-ui-accent relative rounded-full border px-2 py-0.5 text-xs font-medium" style:margin-left="{gutter + 8}px">{t('graph.now')}</span>
						</div>
					{:else}
						{@const n = nodeByID.get(r.id)}
						{#if n}
							<div role="listitem" class={rowBg(i)} style:height="var(--graph-row)">
								<button
									type="button"
									class="hover:bg-ui-accent/10 focus-visible:ring-ring grid h-full w-full min-w-0 grid-cols-[minmax(0,1fr)] items-center text-left text-sm focus-visible:ring-2 focus-visible:outline-none focus-visible:ring-inset sm:grid-cols-[minmax(0,1fr)_11rem_12rem_5rem]"
									data-testid="graph-node"
									data-node={n.task.id}
									data-status={n.task.status}
									data-blocked={n.blocked}
									data-overdue={n.overdue}
									aria-label={t('graph.node', { title: n.task.title, status: statusLabel(n.task.status) }) + (n.blocked ? ', ' + waitingText(n) : '') + (whenText(n) ? ', ' + whenText(n) : '')}
									onclick={() => open(n)}
									onfocus={() => (focusID = n.task.id)}
									onblur={() => (focusID = null)}
									onmouseenter={() => (focusID = n.task.id)}
									onmouseleave={() => (focusID = null)}
									onkeydown={(e) => onkey(e, n)}
								>
									<span class="flex min-w-0 items-center gap-1.5 pr-3" style:padding-left="{gutter + 6}px">
										{#if n.task.isFeature}
											<span class="badge" style={pill(n.color)} data-testid="graph-badge-feature"><GitBranch class="size-3" aria-hidden="true" />{t('graph.feature')}</span>
										{/if}
										{#each n.tags as tag (tag.milestoneID)}
											<span class={['badge', 'tag', tag.state === 'planned' && 'planned', tag.overdue && 'overdue']} data-testid="graph-tag" data-state={tag.state} title={tag.dueAt ? formatWhen(tag.dueAt) : undefined}>
												<Tag class="size-3" aria-hidden="true" />{tag.title}<span class="sr-only"> ({t(tag.state === 'released' ? 'graph.milestone.released' : tag.overdue ? 'graph.milestone.overdue' : 'graph.milestone.planned')})</span>
											</span>
										{/each}
										{#if n.task.status === 'in_progress' || n.task.status === 'in_review'}
											<span class={['badge status', n.task.status]}>{statusLabel(n.task.status)}</span>
										{/if}
										<span class={['truncate', n.task.status === 'done' && 'text-muted-foreground']}>{n.task.title}</span>
										{#if n.blocked}<span class="text-warning hidden shrink-0 truncate text-xs font-medium sm:inline" data-testid="graph-waiting">{waitingText(n)}</span>{/if}
										{#if n.blocking}<span class="text-warning hidden shrink-0 text-xs md:inline">{t('graph.blocking')}</span>{/if}
										{#if n.overdue}<span class="text-destructive shrink-0 text-xs font-medium">{t('graph.overdue')}</span>{/if}
									</span>
									<span class="text-muted-foreground hidden h-full min-w-0 items-center truncate border-l px-3 sm:flex">{n.task.agent ?? projectNames[n.task.projectID] ?? ''}</span>
									<span class={['hidden h-full min-w-0 items-center truncate border-l px-3 sm:flex', n.overdue ? 'text-destructive' : 'text-muted-foreground']}>{whenText(n)}</span>
									<span class="text-muted-foreground hidden h-full items-center border-l px-3 font-mono text-xs sm:flex">{shortID(n.task.id)}</span>
								</button>
							</div>
						{/if}
					{/if}
				{/each}
			</div>
		</div>
		{#if hiddenRows > 0}
			<div class="flex items-center gap-3 text-sm">
				<span class="text-muted-foreground">{t('graph.more.hint', { shown: layout.rows.length, total: full.rows.length })}</span>
				<button type="button" class="text-ui-accent min-h-9 underline" data-testid="graph-more" onclick={() => (limit += PAGE)}>{t('graph.more', { count: Math.min(PAGE, hiddenRows) })}</button>
			</div>
		{/if}
		<p class="text-muted-foreground flex flex-wrap gap-x-4 gap-y-1 text-xs" aria-label={t('graph.legend')}>
			<span>{t('graph.legend.open')}</span><span>{t('graph.legend.merge')}</span><span>{t('graph.legend.wait')}</span><span>{t('graph.legend.tag')}</span>
		</p>
	{/if}
</section>

<style>
	.badge {
		--lc: var(--ui-accent);
		display: inline-flex;
		flex-shrink: 0;
		align-items: center;
		gap: 0.25rem;
		border-radius: 0.5rem;
		padding: 0.05rem 0.45rem;
		font-size: 0.75rem;
		font-weight: 500;
		line-height: 1.25rem;
		background: color-mix(in oklch, var(--lc) 20%, transparent);
		color: color-mix(in oklch, var(--lc) 65%, var(--foreground));
	}
	.badge.tag {
		--lc: oklch(0.65 0.22 325);
	}
	.badge.tag.planned {
		background: transparent;
		border: 1px dashed var(--lc);
	}
	.badge.tag.overdue {
		--lc: var(--destructive);
	}
	.badge.status.in_progress {
		--lc: var(--ui-accent);
	}
	.badge.status.in_review {
		--lc: var(--warning);
	}
</style>
