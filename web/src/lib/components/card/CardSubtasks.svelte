<script lang="ts">
	import { api, type Task } from '#lib/api.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import Check from '@lucide/svelte/icons/check';
	import Plus from '@lucide/svelte/icons/plus';

	/**
	 * Subtasks of the card with "+ Unteraufgabe hinzufügen". A subtask is a normal task of the same project whose workflow
	 * parent is this task (only one level deep, the server refuses more). Completing one needs no extra window.
	 */
	let { task, subtasks, canAdd = true, onchanged }: { task: Task; subtasks: Task[]; canAdd?: boolean; onchanged: () => unknown } = $props();

	let adding = $state(false);
	let title = $state('');
	let busy = $state(false);
	let input = $state<HTMLInputElement | null>(null);

	async function add(e: Event) {
		e.preventDefault();
		const v = title.trim();
		if (!v || busy) return;
		busy = true;
		try {
			const ok = await attempt(async () => {
				const created = await api.createTask(task.projectID, v);
				await api.setTaskStructure(created.id, { parentTaskID: task.id });
			}, async () => { await onchanged(); });
			if (ok) {
				title = '';
				await onchanged();
				await workspace.reloadTasks();
				input?.focus();
			}
		} finally {
			busy = false;
		}
	}
	async function toggle(s: Task) {
		await attempt(async () => {
			await api.updateTask(s, { status: s.status === 'done' ? 'open' : 'done' });
			await onchanged();
			await workspace.reloadTasks();
		}, async () => { await onchanged(); });
	}
	function startAdd() {
		adding = true;
		queueMicrotask(() => input?.focus());
	}
</script>

<section class="flex flex-col gap-1" aria-label={t('cc.detail.subtasks')} data-testid="card-subtasks">
	{#if subtasks.length > 0}
		<ul class="flex flex-col">
			{#each subtasks as s (s.id)}
				<li class="border-border/60 flex min-h-10 items-center gap-2.5 border-b py-1" data-testid="card-subtask">
					<button
						type="button"
						role="checkbox"
						aria-checked={s.status === 'done'}
						aria-label={s.status === 'done' ? t('tasks.reopen') : t('tasks.done')}
						class={['hit-area relative inline-flex size-5 shrink-0 items-center justify-center rounded-full border-[1.5px] transition-colors', s.status === 'done' ? 'bg-success border-success text-white' : 'border-muted-foreground/60 hover:border-foreground']}
						onclick={() => toggle(s)}
					>
						{#if s.status === 'done'}<Check class="size-3" aria-hidden="true" />{/if}
					</button>
					<button type="button" class={['min-w-0 flex-1 text-left text-sm [overflow-wrap:anywhere] hover:underline', s.status === 'done' && 'text-muted-foreground line-through']} onclick={() => cardDetail.open({ type: 'task', id: s.id }, subtasks.map((x) => ({ type: 'task' as const, id: x.id })))}>{s.title}</button>
				</li>
			{/each}
		</ul>
	{/if}
	{#if canAdd}
		{#if adding}
			<form class="flex items-center gap-2 py-1" onsubmit={add}>
				<input
					bind:this={input}
					bind:value={title}
					class="border-input bg-background focus-visible:border-ring focus-visible:ring-ring/40 h-9 min-w-0 flex-1 rounded-lg border px-3 text-sm outline-none focus-visible:ring-2"
					placeholder={t('card.subtask.placeholder')}
					aria-label={t('card.subtask.placeholder')}
					disabled={busy}
					onkeydown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); adding = false; title = ''; } }}
				/>
				<button type="submit" class="bg-ui-accent text-ui-accent-foreground h-9 shrink-0 rounded-lg px-3 text-sm font-medium disabled:opacity-50" disabled={busy || !title.trim()}>{t('card.subtask.add')}</button>
			</form>
		{:else}
			<button type="button" class="text-muted-foreground hover:text-foreground hover:bg-muted -ml-2 inline-flex min-h-9 w-fit items-center gap-2 rounded-lg px-2 text-sm font-medium" data-testid="card-subtask-add" onclick={startAdd}>
				<Plus class="size-4" aria-hidden="true" />{t('card.subtask.addRow')}
			</button>
		{/if}
	{/if}
</section>
