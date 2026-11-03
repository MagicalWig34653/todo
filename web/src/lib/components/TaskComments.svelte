<script lang="ts">
	import { onMount, tick, untrack } from 'svelte';
	import { api, type Comment, type CommentThread } from '#lib/api.js';
	import { relativeWhen } from '#lib/cardRef.js';
	import { formatWhen } from '#lib/planning.js';
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
	import Bot from '@lucide/svelte/icons/bot';
	import Paperclip from '@lucide/svelte/icons/paperclip';
	import SendHorizontal from '@lucide/svelte/icons/send-horizontal';

	/**
	 * `chat` (card detail): message bubbles by author (you right, others and agents left), relative time, the rounded
	 * composer with a paperclip below the history; `onattached` runs after a file was uploaded.
	 * `thread` selects whose chat it is: the task's own (default) or one question's / review's.
	 */
	let { taskID, onchanged, chat = false, onattached, thread = 'task' }: { taskID: string; onchanged?: () => unknown; chat?: boolean; onattached?: () => unknown; thread?: CommentThread } = $props();
	const threadKey = $derived(JSON.stringify(thread));
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
					await attachFile(taskID, file, 'reference', thread);
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
		// Enter and Ctrl/Cmd+Enter send, Shift+Enter inserts a line break.
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
	let scroller = $state<HTMLElement | null>(null);
	let stickToEnd = true;
	function onscroll() {
		if (scroller) stickToEnd = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48;
	}
	/** New messages scroll into view only when the reader was already at the end. */
	$effect(() => {
		void items.length;
		if (!chat || !stickToEnd) return;
		tick().then(() => {
			if (scroller) scroller.scrollTop = scroller.scrollHeight;
		});
	});
	const isMine = (c: Comment) => c.authorKind !== 'agent' && c.authorID === auth.user?.id;
	const authorOf = (c: Comment) =>
		c.authorKind === 'agent' ? c.authorLabel?.trim() || t('comments.agent') : isMine(c) ? t('comments.mine') : personName(c.authorName, t('comments.other'));

	async function load() {
		try {
			items = await api.listComments(taskID, thread);
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
		const key = threadKey;
		const next = await api.listComments(taskID, thread);
		if (key !== threadKey) return;
		if (!editingID && items === before && !sameList(items, next)) items = next;
	}
	// The chat lives in the card window (a dialog); it must keep refreshing there. Refresh never touches the draft.
	onMount(() => startLiveRefresh(refresh, { allowInDialog: chat }));
	$effect(() => {
		void taskID;
		void threadKey;
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
			if (await attempt(async () => (items = [...items, await api.createComment(taskID, v, thread)]), load)) {
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

{#snippet bubbles()}
	<ul class="flex max-h-80 min-h-0 flex-col gap-3 overflow-y-auto py-1" bind:this={scroller} {onscroll} data-testid="chat-history" aria-live="polite">
		{#each items as c (c.id)}
			{@const mine = isMine(c)}
			{@const agent = c.authorKind === 'agent'}
			<li class="flex max-w-[85%] flex-col gap-0.5 {mine ? 'items-end self-end' : 'items-start self-start'}" data-testid="comment" data-author-kind={agent ? 'agent' : 'person'} data-mine={mine}>
				<div class="text-muted-foreground flex items-center gap-1.5 text-xs">
					{#if agent}<Bot class="size-3.5" aria-hidden="true" />{/if}
					<span data-testid="comment-author">{authorOf(c)}</span>
					{#if c.createdAt}<time datetime={c.createdAt} title={formatWhen(c.createdAt)} data-testid="comment-time">{relativeWhen(c.createdAt)}</time>{/if}
				</div>
				{#if editingID === c.id}
					<div class="w-full min-w-64">
						<Textarea bind:value={draft} aria-label={t('comments.edit')} />
						<div class="mt-1 flex gap-1">
							<Button size="sm" onclick={() => save(c)}>{t('common.save')}</Button>
							<Button size="sm" variant="ghost" onclick={() => (editingID = null)}>{t('common.cancel')}</Button>
						</div>
					</div>
				{:else}
					{#if c.kind === 'attachment' && c.attachments?.length}
						<div class="flex flex-col gap-1" data-testid="comment-attachment">
							{#each c.attachments as a (a.id)}
								<a href={api.attachmentPreviewURL(a.id)} target="_blank" rel="noopener" class="rounded-2xl text-sm [overflow-wrap:anywhere] {mine ? 'bg-ui-accent text-ui-accent-foreground rounded-br-md' : 'bg-muted rounded-bl-md'} flex items-center gap-2 overflow-hidden p-1.5 pe-3">
									{#if a.mediaType.startsWith('image/')}
										<img src={api.attachmentPreviewURL(a.id)} alt={a.filename} loading="lazy" class="size-16 shrink-0 rounded-lg object-cover" />
									{:else}
										<Paperclip class="size-4 shrink-0" aria-hidden="true" />
									{/if}
									<span>{a.filename}</span>
								</a>
							{/each}
						</div>
					{:else}
						<p class="rounded-2xl px-3.5 py-2 text-sm [overflow-wrap:anywhere] whitespace-pre-wrap {mine ? 'bg-ui-accent text-ui-accent-foreground rounded-br-md' : agent ? 'bg-ui-accent-soft rounded-bl-md' : 'bg-muted rounded-bl-md'}">{c.body}</p>
					{/if}
					{#if mine}
						<span class="flex gap-1">
							<Button size="xs" variant="ghost" onclick={() => ((editingID = c.id), (draft = c.body))}>{t('comments.edit')}</Button>
							<Button size="xs" variant="ghost" onclick={() => remove(c)}>{t('common.delete')}</Button>
						</span>
					{/if}
				{/if}
			</li>
		{/each}
	</ul>
{/snippet}

{#if chat}
	<div class="flex flex-col gap-2">
		{#if !loaded}
			<div class="bg-muted/60 h-16 animate-pulse rounded-md" role="status" aria-label={t('common.loading')} data-testid="comments-loading"></div>
		{:else if loadFailed && items.length === 0}
			<p class="text-destructive text-xs" role="alert" data-testid="comments-error">{t('common.loadFailed')} <button type="button" class="underline" onclick={() => attempt(load)}>{t('common.retry')}</button></p>
		{:else if items.length === 0}<p class="text-muted-foreground text-xs">{t('card.chat.empty')}</p>{/if}
		{#if items.length > 0}{@render bubbles()}{/if}
		{@render composer()}
	</div>
{:else}
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
					{#each c.attachments ?? [] as a (a.id)}
						<a href={api.attachmentPreviewURL(a.id)} target="_blank" rel="noopener" class="text-ui-accent text-sm underline">{a.filename}</a>
					{/each}
				{/if}
			</li>
		{/each}
	</ul>
	<form class="flex flex-col gap-1" onsubmit={add}>
		<Textarea bind:value={body} placeholder={t('comments.new')} aria-label={t('comments.new')} disabled={sending} />
		<div><Button type="submit" size="sm" disabled={sending || !body.trim()}>{sending ? t('common.sending') : t('comments.add')}</Button></div>
	</form>
</div>
{/if}
