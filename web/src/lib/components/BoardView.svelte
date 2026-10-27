<script lang="ts">
	import { api, type PlanningTask, type Project, type TaskStatus } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { STATUSES, moveWithin } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import TaskChips from './TaskChips.svelte';
	import { Select } from '#lib/components/ui/select/index.js';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import ArrowDown from '@lucide/svelte/icons/arrow-down';

	let { project }: { project: Project } = $props();

	let cols = $state<Record<TaskStatus, PlanningTask[]>>({ open: [], in_progress: [], in_review: [], done: [] });

	async function load() {
		const lists = await Promise.all(STATUSES.map((s) => api.board(project.id, s)));
		cols = { open: lists[0], in_progress: lists[1], in_review: lists[2], done: lists[3] };
	}
	$effect(() => {
		void project.id;
		attempt(load);
	});

	async function move(status: TaskStatus, id: string, delta: number) {
		const ids = cols[status].map((x) => x.task.id);
		const next = moveWithin(ids, id, delta);
		if (next === ids) return;
		const byID = new Map(cols[status].map((x) => [x.task.id, x]));
		const before = cols[status];
		cols[status] = next.map((i) => byID.get(i)!);
		const ok = await attempt(() => api.reorderBoard(project.id, status, next), load);
		if (!ok) cols[status] = before;
	}

	async function setStatus(pt: PlanningTask, status: TaskStatus) {
		if (await attempt(() => api.updateTask(pt.task, { status }), load)) await attempt(load);
	}
</script>

<div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4" data-testid="board">
	{#each STATUSES as status (status)}
		<section class="bg-muted/50 flex flex-col gap-2 rounded-xl border p-2.5" aria-label={t(`status.${status}` as MessageKey)} data-testid="board-column-{status}">
			<h3 class="flex items-center gap-2 px-1 text-sm font-semibold">{t(`status.${status}` as MessageKey)} <span class="text-muted-foreground bg-background rounded-full border px-1.5 text-xs font-medium" data-tabular>{cols[status].length}</span></h3>
			{#if cols[status].length === 0}<p class="text-muted-foreground text-xs">{t('board.empty')}</p>{/if}
			<ul class="flex flex-col gap-2">
				{#each cols[status] as pt (pt.task.id)}
					<li class="bg-card rounded-lg border p-2.5 text-sm shadow-card" data-testid="board-card">
						<p>{pt.task.title}</p>
						<div class="mt-1.5 flex flex-wrap gap-1"><TaskChips {pt} status={pt.task.status} /></div>
						<div class="mt-1 flex flex-wrap items-center gap-1">
							<Button size="xs" variant="outline" aria-label={t('board.moveUp')} onclick={() => move(status, pt.task.id, -1)}><ArrowUp aria-hidden="true" /></Button>
							<Button size="xs" variant="outline" aria-label={t('board.moveDown')} onclick={() => move(status, pt.task.id, 1)}><ArrowDown aria-hidden="true" /></Button>
							<Select
								class="min-w-0 basis-full [&_select]:h-7 [&_select]:text-xs"
								aria-label={t('board.moveTo')}
								value={status}
								onchange={(e) => setStatus(pt, e.currentTarget.value as TaskStatus)}
							>
								{#each STATUSES as s (s)}<option value={s}>{t(`status.${s}` as MessageKey)}</option>{/each}
							</Select>
						</div>
					</li>
				{/each}
			</ul>
		</section>
	{/each}
</div>
