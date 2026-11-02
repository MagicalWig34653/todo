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
	import { AttachProblem, attachFile } from '#lib/attachFile.js';
	import type { MessageKey } from '#lib/i18n/index.js';
	import Avatar from './app/Avatar.svelte';
	import Paperclip from '@lucide/svelte/icons/paperclip';
	import SendHorizontal from '@lucide/svelte/icons/send-horizontal';

	/** `chat` (card detail): avatar + rounded "Kommentieren" field with a paperclip above the history; `onattached` runs after a file was uploaded. */
	let { taskID, onchanged, chat = false, onattached }: { taskID: string; onchanged?: () => unknown; chat?: boolean; onattached?: () => unknown } = $props();
	let fileInput = $state<HTMLInputElement | null>(null);
	let attaching = $state(false);
	let attachProblem = $state<string | null>(null);
	async function attach() {
		const file = fileInput?.files?.[0];
		if (!file) return;
		attachProblem = null;
		attaching = true;
		try {
			await attempt(async () => {
				try {
					await attachFile(taskID, file);
				} catch (e) {
					if (e instanceof AttachProblem) {
						attachProblem = t(`attachments.problem.${e.problem}` as MessageKey);
						return;
					}
					throw e;
				}
				await onattached?.();
			});
		} finally {
			attaching = false;
			if (fileInput) fileInput.value = '';
		}
	}
	function composerKey(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
			e.preventDefault();
			(e.currentTarget as HTMLTextAreaElement).form?.requestSubmit();
		}
	}
	const initials = $derived(auth.user?.displayName ?? '?');

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

{#snippet composer()}
	<form class="flex items-start gap-3" onsubmit={add} data-testid="comment-composer">
		<Avatar name={initials} class="mt-0.5 size-9 text-xs ring-0" />
		<div class="bg-background border-input focus-within:border-ring focus-within:ring-ring/40 flex min-w-0 flex-1 items-end gap-1 rounded-3xl border py-1 pr-1.5 pl-4 transition-colors focus-within:ring-2">
			<textarea
				bind:value={body}
				rows="1"
				class="placeholder:text-muted-foreground field-sizing-content max-h-40 min-h-9 min-w-0 flex-1 resize-none bg-transparent py-2 text-sm outline-none"
				placeholder={t('card.comment.placeholder')}
				aria-label={t('comments.new')}
				disabled={sending}
				onkeydown={composerKey}
			></textarea>
			<input bind:this={fileInput} type="file" class="sr-only" tabindex="-1" aria-hidden="true" accept="image/png,image/jpeg,image/webp,application/pdf" data-testid="comment-file" onchange={attach} />
			<button type="button" class="text-muted-foreground hover:bg-muted hover:text-foreground hit-area relative inline-flex size-9 shrink-0 items-center justify-center rounded-full disabled:opacity-50" aria-label={t('card.comment.attach')} title={t('card.comment.attach')} disabled={attaching} onclick={() => fileInput?.click()}>
				<Paperclip class="size-4.5" aria-hidden="true" />
			</button>
			{#if body.trim()}
				<button type="submit" class="bg-ui-accent text-ui-accent-foreground hit-area relative inline-flex size-9 shrink-0 items-center justify-center rounded-full disabled:opacity-50" aria-label={t('comments.add')} disabled={sending} data-testid="comment-send">
					<SendHorizontal class="size-4" aria-hidden="true" />
				</button>
			{/if}
		</div>
	</form>
	{#if attachProblem}<p role="alert" class="text-destructive text-xs">{attachProblem}</p>{/if}
{/snippet}

<div class="flex flex-col gap-2">
	{#if chat}{@render composer()}{/if}
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
	{#if !chat}<form class="flex flex-col gap-1" onsubmit={add}>
		<Textarea bind:value={body} placeholder={t('comments.new')} aria-label={t('comments.new')} disabled={sending} />
		<div><Button type="submit" size="sm" disabled={sending || !body.trim()}>{sending ? t('common.sending') : t('comments.add')}</Button></div>
	</form>{/if}
</div>
