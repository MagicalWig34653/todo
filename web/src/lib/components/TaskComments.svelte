<script lang="ts">
	import { untrack } from 'svelte';
	import { onMount } from 'svelte';
	import { api, type Comment } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { personName } from '#lib/people.js';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';

	let { taskID, onchanged }: { taskID: string; onchanged?: () => unknown } = $props();

	let items = $state<Comment[]>([]);
	let body = $state('');
	let editingID = $state<string | null>(null);
	let draft = $state('');
	let loaded = $state(false);
	let loadFailed = $state(false);
	let sending = $state(false);

	async function load() {
		try {
			items = await api.listComments(taskID);
			loadFailed = false;
		} catch (e) {
			loadFailed = true;
			throw e;
		} finally {
			loaded = true;
		}
	}
	/** Silent refetch (focus, visibility, interval): keeps the list when nothing changed and never interrupts an edit. */
	async function refresh() {
		if (editingID) return;
		const before = items;
		const next = await api.listComments(taskID);
		if (!editingID && items === before && !sameList(items, next)) items = next;
	}
	onMount(() => startLiveRefresh(refresh));
	$effect(() => {
		void taskID;
		editingID = null;
		loaded = false;
		untrack(() => attempt(load));
	});

	async function add(e: Event) {
		e.preventDefault();
		const v = body.trim();
		if (!v || sending) return;
		sending = true;
		try {
			// The draft stays in the field until the server accepted it.
			if (await attempt(async () => (items = [...items, await api.createComment(taskID, v)]), load)) {
				body = '';
				await onchanged?.();
			}
		} finally {
			sending = false;
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
	{#if !loaded}
		<div class="bg-muted/60 h-16 animate-pulse rounded-md" role="status" aria-label={t('common.loading')} data-testid="comments-loading"></div>
	{:else if loadFailed && items.length === 0}
		<p class="text-destructive text-xs" role="alert" data-testid="comments-error">{t('common.loadFailed')} <button type="button" class="underline" onclick={() => attempt(load)}>{t('common.retry')}</button></p>
	{:else if items.length === 0}<p class="text-muted-foreground text-xs">{t('comments.empty')}</p>{/if}
	<ul class="flex flex-col gap-2">
		{#each items as c (c.id)}
			{@const mine = c.authorID === auth.user?.id}
			<li class="bg-muted/40 rounded-md p-2 text-sm" data-testid="comment">
				<div class="text-muted-foreground mb-1 flex items-center justify-between text-xs">
					<span data-testid="comment-author">{mine ? t('comments.mine') : personName(c.authorName, t('comments.other'))}</span>
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
		<Textarea bind:value={body} placeholder={t('comments.new')} aria-label={t('comments.new')} disabled={sending} />
		<div><Button type="submit" size="sm" disabled={sending || !body.trim()}>{sending ? t('common.sending') : t('comments.add')}</Button></div>
	</form>
</div>
