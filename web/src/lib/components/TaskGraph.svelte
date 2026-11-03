<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { api, type Project, type Task } from '#lib/api.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { descendantIDs } from '#lib/projectState.js';
	import { edgePath, filterGraph, layoutGraph, neighbourNode, type GraphInput, type GraphTask, type LaidNode } from '#lib/taskGraph.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Select } from '#lib/components/ui/select/index.js';

	let { project }: { project: Project } = $props();

	const LANE_W = 22;
	const MAX_PROJECTS = 40;
	const LANE_HUES = [262, 150, 40, 330, 200, 90];

	let includeSub = $state(false);
	let featuresOnly = $state(false);
	let hideDone = $state<string>('30');
	let loaded = $state(false);
	let rawTasks = $state<GraphTask[]>([]);
	let extraTasks = $state<GraphTask[]>([]);
	let edges = $state<GraphInput['edges']>([]);
	let milestones = $state<GraphInput['milestones']>([]);
	let projectNames = $state<Record<string, string>>({});
	let pitch = $state(56);
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
		const kind = new Map(graph.tasks.map((x) => [x.taskID, x]));
		const milestoneOf = new Map<string, string>();
		for (const m of ms) for (const task of m.tasks) milestoneOf.set(task.id, m.milestone.id);
		const toGraph = (task: Task): GraphTask => ({
			id: task.id,
			title: task.title,
			status: task.status,
			projectID: task.projectID,
			isFeature: kind.get(task.id)?.kind === 'feature',
			dueAt: task.planning?.dueAt ?? null,
			doneAt: task.status === 'done' ? (kind.get(task.id)?.updatedAt ?? null) : null,
			milestoneID: milestoneOf.get(task.id) ?? null
		});
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
	});
	onMount(() => startLiveRefresh(() => load().catch(() => {}), { guardEditing: true }));

	const now = $derived(new Date(Date.now() - (Date.now() % 60000)));
	const layout = $derived.by(() => {
		const full: GraphInput = { tasks: [...rawTasks, ...extraTasks], edges, milestones };
		const shown = filterGraph(
			{ tasks: rawTasks, edges, milestones },
			{ featuresOnly, hideDoneDays: hideDone === 'never' ? null : Number(hideDone), now }
		);
		return layoutGraph(shown, now, full);
	});
	const titleOf = $derived(new Map(layout.nodes.map((n) => [n.task.id, n.task.title])));
	const gutter = $derived(layout.laneCount * LANE_W + 12);
	const x = (lane: number) => 10 + lane * LANE_W + LANE_W / 2;
	const y = (row: number) => row * pitch + pitch / 2;
	const laneColor = (lane: number) => `oklch(0.62 0.15 ${LANE_HUES[lane % LANE_HUES.length]})`;
	const nodeByID = $derived(new Map(layout.nodes.map((n) => [n.task.id, n])));
	const milestoneByRow = $derived(new Map(layout.milestones.map((m) => [m.row, m])));
	const focusEdges = $derived(new Set(layout.edges.filter((e) => e.taskID === focusID || e.prerequisiteID === focusID).map((e) => `${e.taskID}>${e.prerequisiteID}`)));

	const statusLabel = (s: GraphTask['status']) => t(`status.${s}` as MessageKey);
	function waitingText(n: LaidNode): string {
		const first = titleOf.get(n.waitingFor[0]) ?? '';
		return n.waitingFor.length > 1
			? t('graph.waitingForMore', { title: first, count: n.waitingFor.length - 1 })
			: t('graph.waitingFor', { title: first });
	}
	function open(n: LaidNode) {
		cardDetail.open({ type: 'task', id: n.task.id }, layout.nodes.map((m) => ({ type: 'task' as const, id: m.task.id })));
	}
	let host: HTMLElement | undefined = $state();
	function onkey(e: KeyboardEvent, n: LaidNode) {
		const dir = ({ ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' } as const)[e.key as 'ArrowUp'];
		if (!dir) return;
		const next = neighbourNode(layout, n.task.id, dir);
		if (!next) return;
		e.preventDefault();
		host?.querySelector<HTMLElement>(`[data-node="${next}"]`)?.focus();
	}
	const nodeFill = (n: LaidNode) =>
		n.task.status === 'done' ? 'var(--success)' : n.task.status === 'in_progress' ? 'var(--ui-accent)' : n.task.status === 'in_review' ? 'var(--warning)' : 'var(--background)';
	const nodeStroke = (n: LaidNode) => (n.overdue ? 'var(--destructive)' : n.blocked ? 'var(--warning)' : n.task.status === 'open' ? 'var(--muted-foreground)' : nodeFill(n));
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
	{:else if layout.nodes.length === 0 && layout.milestones.length === 0}
		<p class="text-muted-foreground text-sm" data-testid="graph-empty">{rawTasks.length > 0 ? t('graph.emptyFiltered') : t('graph.empty')}</p>
	{:else}
		<div class="min-w-0 overflow-x-auto rounded-xl border" data-testid="graph-scroll" tabindex="-1">
			<div bind:this={host} class="relative" style:--graph-row="3.75rem" style:min-width="{gutter + 240}px" role="list" aria-label={t('graph.canvas', { count: layout.nodes.length })}>
				<div class="pointer-events-none invisible absolute w-0" style:height="var(--graph-row)" bind:clientHeight={pitch} aria-hidden="true"></div>
				<svg class="pointer-events-none absolute top-0 left-0" width={gutter} height={layout.rows.length * pitch} aria-hidden="true" data-testid="graph-svg">
					{#each layout.edges as e (e.taskID + e.prerequisiteID)}
						{@const hot = focusEdges.has(`${e.taskID}>${e.prerequisiteID}`)}
						<path
							d={edgePath(e.points, x, y)}
							fill="none"
							stroke={e.blocking ? 'var(--warning)' : laneColor(nodeByID.get(e.taskID)?.lane ?? 0)}
							stroke-width={hot ? 3 : 1.75}
							stroke-dasharray={e.blocking ? '4 3' : undefined}
							opacity={e.blocking || hot ? 1 : 0.7}
							data-edge="{e.taskID}>{e.prerequisiteID}"
							data-blocking={e.blocking}
						/>
					{/each}
					{#each layout.nodes as n (n.task.id)}
						<g transform="translate({x(n.lane)} {y(n.row)})">
							{#if n.blocking}<circle r="10" fill="none" stroke="var(--warning)" stroke-width="1.5" stroke-dasharray="2 2" />{/if}
							<circle r="6.5" fill={nodeFill(n)} stroke={nodeStroke(n)} stroke-width={n.task.status === 'in_review' || n.blocked || n.overdue ? 3 : 2} />
							{#if n.task.status === 'done'}<path d="M-3 0l2 2.2L3.2 -2" fill="none" stroke="var(--background)" stroke-width="1.6" />{/if}
							{#if n.task.isFeature}<rect x="-3" y="-3" width="6" height="6" fill="none" stroke="var(--background)" stroke-width="1.2" transform="rotate(45)" />{/if}
						</g>
					{/each}
					{#each layout.milestones as m (m.row)}
						<rect x={10} y={y(m.row) - 7} width="14" height="14" transform="rotate(45 {17} {y(m.row)})" fill={m.state === 'released' ? 'var(--success)' : m.overdue ? 'var(--destructive)' : 'var(--ui-accent)'} />
					{/each}
				</svg>

				{#each layout.rows as r, i (i)}
					{#if r.kind === 'milestone'}
						{@const m = milestoneByRow.get(i)}
						<div
							role="listitem"
							class="bg-muted/50 flex items-center gap-2 border-y pr-3"
							style:height="var(--graph-row)"
							style:padding-left="{gutter + 4}px"
							data-testid="graph-milestone"
							data-state={m?.state}
						>
							<div class="min-w-0 flex-1">
								<p class="truncate text-sm font-semibold">{m?.milestone?.title ?? t('graph.milestone.none')}</p>
								{#if m?.milestone}
									<p class="text-muted-foreground truncate text-xs">
										<span class={m.state === 'released' ? 'text-success font-medium' : m.overdue ? 'text-destructive font-medium' : 'font-medium'}>
											{m.overdue ? t('graph.milestone.overdue') : t(m.state === 'released' ? 'graph.milestone.released' : 'graph.milestone.planned')}
										</span>
										· {m.milestone.dueAt ? formatWhen(m.milestone.dueAt) : t('graph.milestone.noDate')}
										· {t('graph.milestone.progress', { done: m.doneCount, total: m.taskCount })}
									</p>
								{/if}
							</div>
						</div>
					{:else}
						{@const n = nodeByID.get(r.id)}
						{#if n}
							<div role="listitem" style:height="var(--graph-row)">
								<button
									type="button"
									class="hover:bg-muted/60 focus-visible:ring-ring flex h-full w-full min-w-0 flex-col justify-center rounded-md pr-3 text-left focus-visible:ring-2 focus-visible:outline-none"
									style:padding-left="{gutter + 4}px"
									data-testid="graph-node"
									data-node={n.task.id}
									data-status={n.task.status}
									data-blocked={n.blocked}
									data-overdue={n.overdue}
									aria-label={t('graph.node', { title: n.task.title, status: statusLabel(n.task.status) }) + (n.blocked ? ', ' + waitingText(n) : '')}
									onclick={() => open(n)}
									onfocus={() => (focusID = n.task.id)}
									onblur={() => (focusID = null)}
									onmouseenter={() => (focusID = n.task.id)}
									onmouseleave={() => (focusID = null)}
									onkeydown={(e) => onkey(e, n)}
								>
									<span class={['truncate text-sm font-medium', n.task.status === 'done' && 'text-muted-foreground line-through']}>{n.task.title}</span>
									<span class="text-muted-foreground flex min-w-0 items-center gap-x-2 truncate text-xs">
										<span class="shrink-0">{statusLabel(n.task.status)}</span>
										{#if n.task.isFeature}<span class="shrink-0">· {t('graph.feature')}</span>{/if}
										{#if includeSub && n.task.projectID !== project.id}<span class="truncate">· {projectNames[n.task.projectID] ?? ''}</span>{/if}
										{#if n.blocked}<span class="text-warning shrink-0 font-medium" data-testid="graph-waiting">· {waitingText(n)}</span>{/if}
										{#if n.blocking}<span class="text-warning shrink-0">· {t('graph.blocking')}</span>{/if}
										{#if n.overdue}<span class="text-destructive shrink-0 font-medium">· {t('graph.overdue')}</span>
										{:else if n.task.dueAt && n.task.status !== 'done'}<span class="shrink-0">· {t('graph.due', { date: formatWhen(n.task.dueAt) })}</span>{/if}
									</span>
								</button>
							</div>
						{/if}
					{/if}
				{/each}
			</div>
		</div>
	{/if}
</section>
