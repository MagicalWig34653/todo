<script lang="ts">
	import { onDestroy, onMount, tick } from 'svelte';
	import { api, ApiError } from '#lib/api.js';
	import { actionRequest, appendPosts, postTitleKey, type ForYouAction, type ForYouImage, type ForYouNeed, type ForYouPage, type ForYouPost } from '#lib/forYou.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { startLiveRefresh, sameList } from '#lib/liveRefresh.js';
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import Dialog from './app/Dialog.svelte';
	import Sparkles from '@lucide/svelte/icons/sparkles';

	let { onopen }: { onopen?: (projectID: string, taskID: string) => void } = $props();

	let needs = $state<ForYouNeed[]>([]);
	let needsTotal = $state(0);
	let posts = $state<ForYouPost[]>([]);
	let next = $state<string | null>(null);
	let loaded = $state(false);
	let unsupported = $state(false);
	let loading = $state(false);
	let busy = $state<Set<string>>(new Set());
	let texts = $state<Record<string, string>>({});
	let noteFor = $state<string | null>(null);
	let sentinel = $state<HTMLElement | null>(null);
	let zoom = $state<ForYouImage | null>(null);
	let zoomOpen = $state(false);

	function adopt(page: ForYouPage) {
		if (!sameList(needs, page.needsYou)) needs = page.needsYou;
		needsTotal = page.needsYouTotal;
		if (!sameList(posts, page.posts)) posts = page.posts;
		next = page.nextCursor ?? null;
		loaded = true;
	}
	async function load() {
		if (loading) return;
		loading = true;
		try {
			adopt(await api.forYou({ limit: 30 }));
			unsupported = false;
		} catch (e) {
			if (e instanceof ApiError && e.status === 404) unsupported = true;
			else throw e;
		} finally {
			loading = false;
		}
	}
	async function more() {
		if (!next || loading) return;
		loading = true;
		try {
			const page = await api.forYou({ cursor: next, limit: 30 });
			posts = appendPosts(posts, page.posts);
			next = page.nextCursor ?? null;
		} finally {
			loading = false;
		}
	}
	/** Live refresh must not disturb a text being typed. */
	const typing = () => busy.size > 0 || Object.values(texts).some((v) => v.trim() !== '');
	onMount(() => startLiveRefresh(() => (typing() ? undefined : load())));
	onMount(() => void attempt(load));

	let observer: IntersectionObserver | null = null;
	$effect(() => {
		observer?.disconnect();
		observer = null;
		if (!sentinel || typeof IntersectionObserver === 'undefined') return;
		observer = new IntersectionObserver((entries) => {
			if (entries.some((e) => e.isIntersecting) && next && !loading) attempt(more);
		}, { rootMargin: '300px' });
		observer.observe(sentinel);
	});
	onDestroy(() => observer?.disconnect());
	$effect(() => {
		void posts.length;
		void next;
		if (!next || !sentinel) return;
		tick().then(() => {
			if (next && !loading && sentinel && sentinel.getBoundingClientRect().top < window.innerHeight + 300) attempt(more);
		});
	});

	async function run(item: ForYouNeed, action: ForYouAction) {
		const req = actionRequest(action, texts[item.id] ?? '');
		if (!req || busy.has(item.id)) return;
		busy = new Set(busy).add(item.id);
		await attempt(async () => {
			try {
				await api.performAction(req.method, req.path, req.body);
				needs = needs.filter((n) => n.id !== item.id);
				needsTotal = Math.max(0, needsTotal - 1);
				texts[item.id] = '';
				noteFor = null;
			} finally {
				const b = new Set(busy);
				b.delete(item.id);
				busy = b;
			}
		});
		await attempt(load);
		void attempt(() => workspace.refreshLive());
	}
	function click(item: ForYouNeed, action: ForYouAction) {
		if (action.requiresInput && action.inputField === 'note' && noteFor !== item.id) noteFor = item.id;
		else void run(item, action);
	}
	function actor(p: ForYouPost): string {
		return p.actor.name ?? (p.actor.type === 'Person' ? '' : t('forYou.agent'));
	}
	const kindKey = (k: string) => `forYou.kind.${k}` as MessageKey;
</script>

<section class="flex flex-col gap-4" data-testid="for-you">
	<PageHeader title={t('forYou.title')} description={t('forYou.hint')} testid="view-heading" />

	{#if unsupported}
		<EmptyState title={t('forYou.unsupported')} icon={Sparkles} />
	{:else if loaded && needs.length === 0 && posts.length === 0}
		<EmptyState title={t('forYou.empty')} icon={Sparkles}><p>{t('forYou.emptyHint')}</p></EmptyState>
	{:else if loaded}
		{#if needs.length > 0}
			<div class="flex flex-col gap-2" data-testid="needs-you">
				<h3 class="text-muted-foreground flex items-baseline gap-2 text-xs font-semibold tracking-wide uppercase">
					{t('forYou.needsYou')}
					{#if needsTotal > needs.length}<span class="font-normal normal-case">{t('forYou.needsYouMore', { count: needsTotal - needs.length })}</span>{/if}
				</h3>
				{#each needs as item (item.id)}
					<article class="bg-card flex flex-col gap-2 rounded-xl border p-3" data-testid="needs-card" data-kind={item.kind}>
						<button type="button" class="flex flex-col items-start gap-0.5 text-left" aria-label={t('forYou.openTask')} onclick={() => onopen?.(item.projectID, item.taskID)}>
							<span class={['text-xs font-semibold', item.kind === 'overdue' || item.kind === 'blocked' ? 'text-destructive' : 'text-ui-accent']}>{t(kindKey(item.kind))}</span>
							<span class="text-sm font-semibold">{item.title}</span>
							{#if item.detail}<span class="text-muted-foreground text-sm">{item.detail}</span>{/if}
							<span class="text-muted-foreground text-xs">
								{[item.projectName, item.kind === 'question' || item.kind === 'review' ? item.taskTitle : '', item.dueAt ? formatWhen(item.dueAt) : ''].filter(Boolean).join(' · ')}
							</span>
						</button>
						{#if item.actions.length > 0}
							{@const free = item.actions.length === 1 && item.actions[0].requiresInput && item.actions[0].inputField === 'answer'}
							{#if free}
								<form class="flex gap-2" onsubmit={(e) => { e.preventDefault(); void run(item, item.actions[0]); }}>
									<Input class="min-w-0 flex-1" placeholder={t('forYou.answerPlaceholder')} aria-label={t('forYou.answerPlaceholder')} bind:value={texts[item.id]} />
									<Button type="submit" disabled={busy.has(item.id) || !(texts[item.id] ?? '').trim()}>{t('forYou.send')}</Button>
								</form>
							{:else}
								<div class="flex flex-wrap gap-2">
									{#each item.actions as action (action.key + action.label)}
										<Button variant="outline" disabled={busy.has(item.id)} onclick={() => click(item, action)}>{action.label}</Button>
									{/each}
								</div>
								{#if noteFor === item.id}
									<Input placeholder={t('forYou.notePlaceholder')} aria-label={t('forYou.notePlaceholder')} bind:value={texts[item.id]} />
								{/if}
							{/if}
						{/if}
					</article>
				{/each}
			</div>
		{/if}

		{#if posts.length > 0}
			<div class="flex flex-col gap-2" data-testid="posts">
				<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('forYou.posts')}</h3>
				{#each posts as post (post.id)}
					<article class="bg-card flex flex-col gap-2 rounded-xl border p-3" data-testid="post-card" data-kind={post.kind}>
						<button type="button" class="flex flex-col items-start gap-0.5 text-left" aria-label={t('forYou.openTask')} onclick={() => onopen?.(post.projectID, post.taskID)}>
							<span class="text-sm font-semibold">{actor(post)} {t(postTitleKey(post) as MessageKey)}</span>
							{#if post.text}<span class="text-sm whitespace-pre-line">{post.text}</span>{/if}
							{#if post.detail}<span class="text-muted-foreground text-sm">→ {post.detail}</span>{/if}
							<span class="text-muted-foreground text-xs">{[post.projectName, post.taskTitle, post.createdAt ? formatWhen(post.createdAt) : ''].filter(Boolean).join(' · ')}</span>
						</button>
						{#if post.percent != null}
							<div class="bg-muted h-1.5 w-full overflow-hidden rounded-full" role="progressbar" aria-valuenow={post.percent} aria-valuemin="0" aria-valuemax="100">
								<div class="bg-ui-accent h-full" style:width="{post.percent}%"></div>
							</div>
						{/if}
						{#if post.images.length > 0}
							<div class="flex gap-2 overflow-x-auto">
								{#each post.images as image (image.attachmentID)}
									<button type="button" class="shrink-0 overflow-hidden rounded-lg border" aria-label="{t('forYou.image')}: {image.label ?? image.filename}" onclick={() => { zoom = image; zoomOpen = true; }}>
										<img src={image.previewURL} alt={image.label ?? image.filename} loading="lazy" class="h-48 w-auto max-w-[70vw] object-cover" />
									</button>
								{/each}
							</div>
						{/if}
					</article>
				{/each}
				<div bind:this={sentinel} aria-hidden="true"></div>
				{#if next}<Button variant="outline" class="self-center" onclick={() => attempt(more)} disabled={loading}>{t('forYou.loadMore')}</Button>{/if}
			</div>
		{/if}
	{/if}
</section>

<Dialog bind:open={zoomOpen} title={zoom?.label ?? zoom?.filename ?? ''} class="max-w-4xl" testid="image-dialog">
	{#if zoom}<img src={zoom.previewURL} alt={zoom.label ?? zoom.filename} class="mx-auto max-h-[75vh] w-auto max-w-full" />{/if}
</Dialog>
