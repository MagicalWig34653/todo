<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type Project, type ProjectComment, type Role } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { personName } from '#lib/people.js';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';

	let { project }: { project: Project } = $props();

	let items = $state<ProjectComment[]>([]);
	let loaded = $state(false);
	let role = $state<Role | null>(null);
	let body = $state('');
	let editingID = $state<string | null>(null);
	let draft = $state('');
	/** Retrying the same text after a lost response must not create a second comment. */
	let pending: { text: string; key: string } | null = null;

	const canComment = $derived(role === null || role === 'comment' || role === 'edit' || role === 'manage');
	const canManage = $derived(role === 'manage');

	async function load() {
		items = await api.listProjectComments(project.id);
		loaded = true;
	}
	/** Silent refetch (focus, visibility, interval): keeps the list when nothing changed and never interrupts an edit. */
	async function refresh() {
		if (editingID) return;
		const next = await api.listProjectComments(project.id);
		if (!editingID && !sameList(items, next)) items = next;
	}
	onMount(() => startLiveRefresh(refresh));
	$effect(() => {
		void project.id;
		editingID = null;
		attempt(load);
		// Role decides which buttons appear; the server enforces the rules either way.
		api.visibility(project.id).then((v) => (role = v.role ?? null)).catch(() => (role = null));
	});

	async function add(e: Event) {
		e.preventDefault();
		const text = body.trim();
		if (!text) return;
		if (!pending || pending.text !== text) pending = { text, key: crypto.randomUUID() };
		const key = pending.key;
		if (await attempt(async () => (items = [...items, await api.createProjectComment(project.id, text, key)]), load)) {
			body = '';
			pending = null;
		}
	}
	async function save(c: ProjectComment) {
		const text = draft.trim();
		if (!text) return;
		const ok = await attempt(async () => {
			const u = await api.updateProjectComment(c, text);
			items = items.map((x) => (x.id === u.id ? u : x));
		}, load);
		if (ok) editingID = null;
	}
	async function remove(c: ProjectComment) {
		await attempt(async () => {
			await api.deleteProjectComment(c);
			items = items.filter((x) => x.id !== c.id);
		}, load);
	}
</script>

<div class="flex flex-col gap-3" data-testid="project-comments">
	{#if loaded && items.length === 0}<p class="text-muted-foreground text-sm">{t('project.commentsEmpty')}</p>{/if}
	<ul class="flex flex-col gap-2">
		{#each items as c (c.id)}
			{@const mine = c.authorID === auth.user?.id}
			<li class="bg-muted/40 rounded-lg p-2.5 text-sm" data-testid="project-comment">
				<div class="text-muted-foreground mb-1 flex flex-wrap items-center justify-between gap-1 text-xs">
					<span>
						<span class="text-foreground font-medium" data-testid="comment-author">{mine ? t('comments.mine') : personName(c.authorName, t('comments.other'))}</span>
						{#if c.createdAt}<span> · {formatWhen(c.createdAt)}</span>{/if}
					</span>
					{#if editingID !== c.id && (mine || canManage)}
						<span class="flex gap-1">
							{#if mine}<Button size="xs" variant="ghost" onclick={() => ((editingID = c.id), (draft = c.body))}>{t('comments.edit')}</Button>{/if}
							<Button size="xs" variant="ghost" data-testid="project-comment-delete" onclick={() => remove(c)}>{t('common.delete')}</Button>
						</span>
					{/if}
				</div>
				{#if editingID === c.id}
					<Textarea bind:value={draft} aria-label={t('comments.edit')} />
					<div class="mt-1 flex gap-1">
						<Button size="sm" disabled={!draft.trim()} onclick={() => save(c)}>{t('common.save')}</Button>
						<Button size="sm" variant="ghost" onclick={() => (editingID = null)}>{t('common.cancel')}</Button>
					</div>
				{:else}
					<p class="whitespace-pre-wrap">{c.body}</p>
				{/if}
			</li>
		{/each}
	</ul>
	{#if canComment}
		<form class="flex flex-col gap-1.5" onsubmit={add}>
			<Textarea bind:value={body} maxlength={10000} placeholder={t('project.commentsNew')} aria-label={t('project.commentsNew')} />
			<div><Button type="submit" size="sm" disabled={!body.trim()}>{t('comments.add')}</Button></div>
		</form>
	{:else}
		<p class="text-muted-foreground text-sm">{t('project.commentsReadOnly')}</p>
	{/if}
</div>
