<script lang="ts">
	import { api, type Comment } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';

	let { taskID, onchanged }: { taskID: string; onchanged?: () => unknown } = $props();

	let items = $state<Comment[]>([]);
	let body = $state('');
	let editingID = $state<string | null>(null);
	let draft = $state('');

	async function load() {
		items = await api.listComments(taskID);
	}
	$effect(() => {
		void taskID;
		editingID = null;
		attempt(load);
	});

	async function add(e: Event) {
		e.preventDefault();
		const v = body.trim();
		if (!v) return;
		if (await attempt(async () => (items = [...items, await api.createComment(taskID, v)]), load)) {
			body = '';
			await onchanged?.();
		}
	}
	async function save(c: Comment) {
		const ok = await attempt(async () => {
			const u = await api.updateComment(c, draft.trim());
			items = items.map((x) => (x.id === u.id ? u : x));
		}, load);
		if (ok) {
			editingID = null;
			await onchanged?.();
		}
	}
	async function remove(c: Comment) {
		if (
			await attempt(async () => {
				await api.deleteComment(c);
				items = items.filter((x) => x.id !== c.id);
			}, load)
		)
			await onchanged?.();
	}
</script>

<div class="flex flex-col gap-2">
	{#if items.length === 0}<p class="text-muted-foreground text-xs">{t('comments.empty')}</p>{/if}
	<ul class="flex flex-col gap-2">
		{#each items as c (c.id)}
			{@const mine = c.authorID === auth.user?.id}
			<li class="bg-muted/40 rounded-md p-2 text-sm" data-testid="comment">
				<div class="text-muted-foreground mb-1 flex items-center justify-between text-xs">
					<span>{mine ? t('comments.mine') : t('comments.other')}</span>
					{#if mine && editingID !== c.id}
						<span class="flex gap-1">
							<Button size="xs" variant="ghost" onclick={() => ((editingID = c.id), (draft = c.body))}>{t('comments.edit')}</Button>
							<Button size="xs" variant="ghost" onclick={() => remove(c)}>{t('common.delete')}</Button>
						</span>
					{/if}
				</div>
				{#if editingID === c.id}
					<Textarea bind:value={draft} aria-label={t('comments.edit')} />
					<div class="mt-1 flex gap-1">
						<Button size="sm" onclick={() => save(c)}>{t('common.save')}</Button>
						<Button size="sm" variant="ghost" onclick={() => (editingID = null)}>{t('common.cancel')}</Button>
					</div>
				{:else}
					<p class="whitespace-pre-wrap">{c.body}</p>
				{/if}
			</li>
		{/each}
	</ul>
	<form class="flex flex-col gap-1" onsubmit={add}>
		<Textarea bind:value={body} placeholder={t('comments.new')} aria-label={t('comments.new')} />
		<div><Button type="submit" size="sm">{t('comments.add')}</Button></div>
	</form>
</div>
