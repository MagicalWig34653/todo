<script lang="ts">
	import Timestamp from './Timestamp.svelte';
	import { onDestroy, onMount, tick } from 'svelte';
	import { api, ApiError } from '#lib/api.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { cardOfConfirmation, cardOfNeed, cardOfPost, cardTabOfNeed, cardTabOfPost, uniqueCards } from '#lib/cardRef.js';
	import { actionRequest, appendPosts, mergeFirstPage, needDetailText, needInputKind, needKindKey, postTitleKey, type ActionRequest, type ForYouAccessRequest, type ForYouAction, type ForYouConfirmation, type ForYouImage, type ForYouNeed, type ForYouPage, type ForYouPost } from '#lib/forYou.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';
	import { attempt, attemptLoad } from '#lib/notice.svelte.js';
	import { startLiveRefresh, sameList } from '#lib/liveRefresh.js';
	import { formatWhen } from '#lib/planning.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import QuestionAnswer from './overview/QuestionAnswer.svelte';
	import OptionButtons from './overview/OptionButtons.svelte';
	import ConfirmationCard from './overview/ConfirmationCard.svelte';
	import AccessRequestCard from './overview/AccessRequestCard.svelte';
	import Dialog from './app/Dialog.svelte';
	import BuildStatusBadge from './BuildStatusBadge.svelte';
	import { buildEventHead, buildStatusOf } from '#lib/now.js';
	import NowEntry from './NowEntry.svelte';
	import Sparkles from '@lucide/svelte/icons/sparkles';

	let { onnow }: { onnow?: () => void } = $props();

	let needs = $state<ForYouNeed[]>([]);
	let needsTotal = $state(0);
	let confirmations = $state<ForYouConfirmation[]>([]);
	/** Requests decided on this page stay visible with their outcome until the page is left. */
	let decided = $state<Record<string, { item: ForYouConfirmation; result: ActionRequest }>>({});
	const confirmationCards = $derived([
		...confirmations.filter((c) => !decided[c.id]).map((item) => ({ item, result: null as ActionRequest | null })),
		...Object.values(decided).map((d) => ({ item: d.item, result: d.result as ActionRequest | null }))
	]);
	let accessRequests = $state<ForYouAccessRequest[]>([]);
	let posts = $state<ForYouPost[]>([]);
	/** The cards in display order: what the window's up/down arrows step through. */
	const orderedCards = $derived(uniqueCards([...confirmationCards.map((c) => cardOfConfirmation(c.item)), ...needs.map(cardOfNeed), ...posts.map(cardOfPost)]));
	let next = $state<string | null>(null);
	let loaded = $state(false);
	let unsupported = $state(false);
	let loading = $state(false);
	let busy = $state<Set<string>>(new Set());
	let texts = $state<Record<string, string>>({});
	let noteFor = $state<string | null>(null);
	/** Entries whose mandatory comment (plan changes) is still missing. */
	let missing = $state<Set<string>>(new Set());
	let sentinel = $state<HTMLElement | null>(null);
	let zoom = $state<ForYouImage | null>(null);
	let zoomOpen = $state(false);

	function adopt(page: ForYouPage) {
		if (!sameList(needs, page.needsYou)) needs = page.needsYou;
		needsTotal = page.needsYouTotal;
		if (!sameList(confirmations, page.confirmations ?? [])) confirmations = page.confirmations ?? [];
		if (!sameList(accessRequests, page.accessRequests ?? [])) accessRequests = page.accessRequests ?? [];
		const merged = mergeFirstPage(posts, page.posts);
		if (!sameList(posts, merged.posts)) posts = merged.posts;
		if (!merged.keepCursor) next = page.nextCursor ?? null;
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
		if (!req && needInputKind(action) === 'comment') {
			missing = new Set(missing).add(item.id);
			await tick();
			document.getElementById(`need-i-${item.id}`)?.focus();
		}
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
		// Not `attempt`: it would wipe the message of a refused action (for example a plan that changed in the meantime).
		await attemptLoad(load);
		void attemptLoad(() => workspace.refreshLive());
	}
	/** Answered through the shared question controls (options or own text): drop the card, then reload. */
	async function answered(item: ForYouNeed) {
		needs = needs.filter((n) => n.id !== item.id);
		needsTotal = Math.max(0, needsTotal - 1);
		await attempt(load);
		void attempt(() => workspace.refreshLive());
	}
	function click(item: ForYouNeed, action: ForYouAction) {
		const kind = needInputKind(action);
		if ((kind === 'note' || kind === 'comment') && noteFor !== item.id) {
			noteFor = item.id;
			if (kind === 'comment') void tick().then(() => document.getElementById(`need-i-${item.id}`)?.focus());
		} else void run(item, action);
	}
	/** The comment of a plan change is mandatory, the note of a review optional: they ask with different words. */
	const asksComment = (item: ForYouNeed) => item.actions.some((a) => needInputKind(a) === 'comment');
	function onDecided(item: ForYouConfirmation, result: ActionRequest) {
		decided[item.id] = { item, result };
		confirmations = confirmations.filter((c) => c.id !== item.id);
		void attempt(load);
		void attempt(() => workspace.refreshLive());
	}
	function onAccessDone(item: ForYouAccessRequest) {
		accessRequests = accessRequests.filter((a) => a.id !== item.id);
		void attempt(load);
		void attempt(() => workspace.refreshLive());
	}
	function actor(p: ForYouPost): string {
		return p.actor.name ?? (p.actor.type === 'Person' ? '' : t('forYou.agent'));
	}
</script>

<section class="flex flex-col gap-4" data-testid="for-you">
	<PageHeader title={t('forYou.title')} description={t('forYou.hint')} testid="view-heading" />
	{#if onnow}<NowEntry onopen={onnow} />{/if}

	{#if unsupported}
		<EmptyState title={t('forYou.unsupported')} icon={Sparkles} />
	{:else if loaded && needs.length === 0 && posts.length === 0 && confirmationCards.length === 0 && accessRequests.length === 0}
		<EmptyState title={t('forYou.empty')} icon={Sparkles}><p>{t('forYou.emptyHint')}</p></EmptyState>
	{:else if loaded}
		{#if needs.length > 0 || confirmationCards.length > 0 || accessRequests.length > 0}
			<div class="flex flex-col gap-2" data-testid="needs-you">
				<h3 class="text-muted-foreground flex items-baseline gap-2 text-xs font-semibold tracking-wide uppercase">
					{t('forYou.needsYou')}
					{#if needsTotal > needs.length}<span class="font-normal normal-case">{t('forYou.needsYouMore', { count: needsTotal - needs.length })}</span>{/if}
				</h3>
				{#each confirmationCards as c (c.item.id)}
					<ConfirmationCard item={c.item} outcome={c.result} ondecided={onDecided} onopen={() => cardDetail.open(cardOfConfirmation(c.item), orderedCards)} />
				{/each}
				{#each accessRequests as a (a.id)}
					<AccessRequestCard item={a} ondone={onAccessDone} />
				{/each}
				{#each needs as item (item.id)}
					<article class="bg-card flex min-w-0 flex-col gap-2 rounded-xl border p-3" data-testid="needs-card" data-kind={item.kind}>
						<button type="button" class="flex w-full min-w-0 flex-col items-start gap-0.5 text-left [overflow-wrap:anywhere]" aria-labelledby="need-t-{item.id}" aria-describedby="need-d-{item.id}" onclick={() => cardDetail.open(cardOfNeed(item), orderedCards, cardTabOfNeed(item))}>
							<span class={['text-xs font-semibold', item.kind === 'overdue' || item.kind === 'blocked' ? 'text-destructive' : 'text-ui-accent']}>{t(needKindKey(item.kind))}</span>
							<span id="need-t-{item.id}" class="text-sm font-semibold">{item.title}</span>
							{#if item.detail}<span class="text-muted-foreground text-sm">{needDetailText(item)}</span>{/if}
							<span id="need-d-{item.id}" class="text-muted-foreground text-xs">
								{[item.projectName, item.kind === 'question' || item.kind === 'review' ? item.taskTitle : '', item.dueAt ? formatWhen(item.dueAt) : ''].filter(Boolean).join(' · ')}
							</span>
							<span class="text-muted-foreground h-4 w-full truncate text-xs" data-tabular><Timestamp value={item.createdAt} label={item.kind === 'question' ? 'time.asked' : item.kind === 'review' ? 'time.requested' : 'time.created'} /></span>
						</button>
						{#if item.actions.length > 0}
							{@const free = item.actions.length === 1 && item.actions[0].requiresInput && item.actions[0].inputField === 'answer'}
							{#if item.kind === 'question' && item.questionID && item.options.length > 0}
								<QuestionAnswer bare id={item.questionID} prompt={item.title} options={item.options} onanswered={() => answered(item)} />
							{:else if free}
								<form class="flex gap-2" onsubmit={(e) => { e.preventDefault(); void run(item, item.actions[0]); }}>
									<Input class="min-w-0 flex-1" placeholder={t('forYou.answerPlaceholder')} aria-label={t('forYou.answerPlaceholder')} bind:value={texts[item.id]} />
									<Button type="submit" disabled={busy.has(item.id) || !(texts[item.id] ?? '').trim()}>{t('forYou.send')}</Button>
								</form>
							{:else}
								<OptionButtons
									class="gap-2"
									items={item.actions.map((a, i) => ({ key: String(i), label: a.label }))}
									disabled={busy.has(item.id)}
									onpick={(i) => click(item, item.actions[Number(i)])}
								/>
								{#if noteFor === item.id}
									{@const comment = asksComment(item)}
									<Input
										id="need-i-{item.id}"
										placeholder={t(comment ? 'forYou.planCommentPlaceholder' : 'forYou.notePlaceholder')}
										aria-label={t(comment ? 'forYou.planCommentPlaceholder' : 'forYou.notePlaceholder')}
										aria-invalid={comment && missing.has(item.id) && !(texts[item.id] ?? '').trim() ? 'true' : undefined}
										aria-describedby={comment && missing.has(item.id) ? `need-p-${item.id}` : undefined}
										oninput={() => { if (missing.has(item.id)) { const m = new Set(missing); m.delete(item.id); missing = m; } }}
										bind:value={texts[item.id]}
									/>
									{#if comment && missing.has(item.id)}
										<p class="text-destructive text-xs font-medium" role="alert" id="need-p-{item.id}">{t('forYou.planCommentRequired')}</p>
									{/if}
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
						<button type="button" class="flex w-full min-w-0 flex-col items-start gap-0.5 text-left [overflow-wrap:anywhere]" aria-labelledby="post-t-{post.id}" aria-describedby="post-d-{post.id}" onclick={() => cardDetail.open(cardOfPost(post), orderedCards, cardTabOfPost(post))}>
							<span id="post-t-{post.id}" class="text-sm font-semibold">{actor(post)} {t(postTitleKey(post) as MessageKey)}</span>
							{#if post.event === 'build.status_changed' && buildStatusOf(post.status)}
								<span class="inline-flex flex-wrap items-center gap-1 text-sm" data-testid="post-build-status">{t(...buildEventHead(post.text))} <BuildStatusBadge status={post.status} /></span>
							{:else if post.text}<span class="text-sm whitespace-pre-line">{post.text}</span>{/if}
							{#if post.detail}<span class="text-muted-foreground text-sm">→ {post.detail}</span>{/if}
							<span id="post-d-{post.id}" class="text-muted-foreground text-xs">{[post.projectName, post.taskTitle].filter(Boolean).join(' · ')}{#if post.createdAt} · <Timestamp value={post.createdAt} />{/if}</span>
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
