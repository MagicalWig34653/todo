<script lang="ts">
	import { onDestroy, onMount, untrack } from 'svelte';
	import Footprints from '@lucide/svelte/icons/footprints';
	import Gauge from '@lucide/svelte/icons/gauge';
	import CircleQuestionMark from '@lucide/svelte/icons/circle-question-mark';
	import StickyNote from '@lucide/svelte/icons/sticky-note';
	import Terminal from '@lucide/svelte/icons/terminal';
	import Activity from '@lucide/svelte/icons/activity';
	import { api, type LiveEvent, type LiveSession } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { relativeWhen } from '#lib/cardRef.js';
	import { absoluteWhen, appendOlder, isStale, liveKindKey, mergeNewest, quietFor, sameLive, splitSessions } from '#lib/liveView.js';
	import { Button } from '#lib/components/ui/button/index.js';

	/**
	 * Live view of a card (ADR 0031): running sessions with the current step above the compact event history.
	 * Everything the agent reported is shown as plain text (never as HTML). Updates come through the central live refresh
	 * (token + long poll, polling as fallback); a refresh only touches what changed, so nodes stay and nothing flickers.
	 */
	let { taskID }: { taskID: string } = $props();

	let sessions = $state<LiveSession[]>([]);
	let items = $state<LiveEvent[]>([]);
	let next = $state<string | null>(null);
	/** The first load finished (successfully): until then no empty text and no layout of its own. */
	let loaded = $state(false);
	/** The first load failed: message with retry. Later refresh failures stay silent and keep the shown data. */
	let failed = $state(false);
	let now = $state(Date.now());

	const groups = $derived(splitSessions(sessions));
	const many = $derived(sessions.length > 1);
	const empty = $derived(loaded && sessions.length === 0 && items.length === 0);

	function apply(page: { sessions: LiveSession[]; items: LiveEvent[]; nextCursor?: string | null }) {
		if (!sameLive(sessions, page.sessions)) sessions = page.sessions;
		const merged = mergeNewest(items, next, page.items, page.nextCursor ?? null);
		if (merged.items.length !== items.length || merged.items[0]?.id !== items[0]?.id) items = merged.items;
		if (merged.next !== next) next = merged.next;
	}

	/** First load (also the retry): shows the failure; a stale answer of a card that was left meanwhile is dropped. */
	async function load() {
		const id = taskID;
		try {
			const page = await api.taskLive(id);
			if (id !== taskID) return;
			sessions = page.sessions;
			items = page.items;
			next = page.nextCursor ?? null;
			failed = false;
			loaded = true;
		} catch {
			if (id === taskID) failed = true;
		}
	}
	/** Silent refetch of the newest page (live refresh): errors keep what is shown, the next refresh tries again. */
	async function refresh() {
		if (!loaded) return;
		const id = taskID;
		try {
			const page = await api.taskLive(id);
			if (id === taskID) apply(page);
		} catch {
			// Keep the shown data. The wake-up that triggered this refresh is spent, so try again shortly (quietly, one timer at a time).
			retryTimer ??= setTimeout(() => {
				retryTimer = null;
				void refresh();
			}, RETRY_MS);
		}
	}
	const RETRY_MS = 5_000;
	let retryTimer: ReturnType<typeof setTimeout> | null = null;
	onDestroy(() => {
		if (retryTimer) clearTimeout(retryTimer);
	});
	async function more() {
		const id = taskID;
		const cursor = next;
		if (!cursor) return;
		const page = await api.taskLive(id, cursor);
		if (id !== taskID) return;
		items = appendOlder(items, page.items);
		next = page.nextCursor ?? null;
	}

	$effect(() => {
		void taskID;
		untrack(() => {
			loaded = false;
			failed = false;
			sessions = [];
			items = [];
			next = null;
			void load();
		});
	});
	// allowInDialog: this view lives inside the card window, where refreshes would otherwise be held back.
	onMount(() => startLiveRefresh(refresh, { allowInDialog: true }));
	// Relative times and the "silent since" hint move on without any event; a slow tick is enough.
	$effect(() => {
		const timer = setInterval(() => (now = Date.now()), 30_000);
		return () => clearInterval(timer);
	});

	const icons = { 'live.kind.step': Footprints, 'live.kind.tool': Terminal, 'live.kind.note': StickyNote, 'live.kind.question': CircleQuestionMark, 'live.kind.progress': Gauge, 'live.kind.other': Activity };
	const duration = (iso: string) => {
		const q = quietFor(iso, now);
		return t(`live.dur.${q.unit}` as 'live.dur.minutes', { count: q.count });
	};
	const meta = (s: LiveSession) => [s.actorLabel || t(`live.actor.${s.actorType}` as 'live.actor.person'), s.model].filter(Boolean).join(' · ');
</script>

{#snippet sessionBox(s: LiveSession)}
	<li class="bg-card flex min-w-0 flex-col gap-1 rounded-lg border p-3" data-testid="live-session">
		<div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5">
			<span class={['size-2 shrink-0 rounded-full', s.status === 'active' && !isStale(s, now) ? 'bg-emerald-500' : 'bg-muted-foreground/50']} aria-hidden="true"></span>
			<span class="min-w-0 font-medium [overflow-wrap:anywhere]">{s.name}</span>
			{#if isStale(s, now)}
				<span class="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900 dark:bg-amber-500/20 dark:text-amber-200" data-testid="live-stale">{t('live.stale', { duration: duration(s.lastSeenAt) })}</span>
			{/if}
		</div>
		<p class="text-muted-foreground text-xs [overflow-wrap:anywhere]">
			{meta(s)} · {s.status === 'active' ? t('live.since', { time: absoluteWhen(s.startedAt, new Date(now)) }) : t('live.endedAt', { time: absoluteWhen(s.endedAt ?? s.lastSeenAt, new Date(now)) })}
		</p>
		<p class="min-h-5 text-sm [overflow-wrap:anywhere] whitespace-pre-wrap" aria-live="polite" aria-label={s.status === 'active' ? t('live.currentStep') : undefined} data-testid="live-session-step">{#if s.currentStep}{s.currentStep}{:else if s.status === 'active'}<span class="text-muted-foreground">{t('live.noStep')}</span>{/if}</p>
	</li>
{/snippet}

<section class="flex min-w-0 flex-col gap-3" aria-label={t('live.title')} aria-busy={!loaded && !failed} data-testid="card-live">
	<h3 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('live.title')}</h3>

	{#if failed && !loaded}
		<div class="flex flex-wrap items-center gap-2 text-sm" role="alert" data-testid="live-error">
			<span>{t('live.error')}</span>
			<Button size="sm" variant="outline" data-testid="live-retry" onclick={() => void load()}>{t('live.retry')}</Button>
		</div>
	{:else if !loaded}
		<p class="text-muted-foreground min-h-16 text-xs">{t('live.loading')}</p>
	{:else if empty}
		<div class="flex flex-col gap-0.5">
			<p class="text-sm" data-testid="live-empty">{t('live.empty')}</p>
			<p class="text-muted-foreground text-xs">{t('live.emptyHint')}</p>
		</div>
	{:else}
		{#if groups.active.length > 0}
			<ul class="flex flex-col gap-2" aria-label={t('live.sessions')} data-testid="live-active">
				{#each groups.active as s (s.id)}{@render sessionBox(s)}{/each}
			</ul>
		{/if}
		{#if groups.ended.length > 0}
			<details class="group" data-testid="live-ended">
				<summary class="text-muted-foreground hover:text-foreground focus-visible:ring-ring/60 min-h-9 cursor-pointer rounded-md py-1.5 text-xs font-medium outline-none select-none focus-visible:ring-2">{t('live.ended', { count: groups.ended.length })}</summary>
				<ul class="mt-1 flex flex-col gap-2">
					{#each groups.ended as s (s.id)}{@render sessionBox(s)}{/each}
				</ul>
			</details>
		{/if}

		{#if items.length > 0}
			<h4 class="text-muted-foreground mt-1 text-xs font-semibold tracking-wide uppercase">{t('live.history')}</h4>
			<ol class="flex flex-col divide-y" data-testid="live-events">
				{#each items as e (e.id)}
					{@const key = liveKindKey(e.kind)}
					{@const Icon = icons[key]}
					<li class="flex min-w-0 gap-2 py-2 text-sm" data-testid="live-event" data-kind={e.kind}>
						<Icon class={['mt-0.5 size-4 shrink-0', e.kind === 'question' ? 'text-ui-accent' : 'text-muted-foreground']} aria-hidden="true" />
						<div class="min-w-0 flex-1">
							<p class="[overflow-wrap:anywhere] whitespace-pre-wrap"><span class="font-medium">{t(key)}:</span> {e.text}</p>
							<p class="text-muted-foreground text-xs">
								<time datetime={e.createdAt} title={absoluteWhen(e.createdAt, new Date(now))}>{relativeWhen(e.createdAt, new Date(now))} · {absoluteWhen(e.createdAt, new Date(now))}</time>{#if many && e.sessionName}<span>{' · '}{e.sessionName}</span>{/if}
							</p>
						</div>
					</li>
				{/each}
			</ol>
			{#if next}
				<div><Button size="sm" variant="ghost" data-testid="live-more" onclick={() => attempt(more)}>{t('live.more')}</Button></div>
			{/if}
		{/if}
	{/if}
</section>
