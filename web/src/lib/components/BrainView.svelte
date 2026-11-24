<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { api } from '#lib/api.js';
	import { audioUrl, mergePage, oldestFirst, speakerOf, type ChannelMessage } from '#lib/brainChannel.js';
	import { t } from '#lib/i18n/index.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import PageHeader from './app/PageHeader.svelte';
	import EmptyState from './app/EmptyState.svelte';
	import BrainAudio from './BrainAudio.svelte';
	import MessagesSquare from '@lucide/svelte/icons/messages-square';

	let items = $state<ChannelMessage[]>([]);
	let nextCursor = $state<string | null>(null);
	let loading = $state(true);
	let loadingOlder = $state(false);
	let failed = $state(false);
	let root = $state<HTMLElement>();
	let firstLoad = true;

	const messages = $derived(oldestFirst(items));
	const stamp = (iso: string) =>
		new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));

	async function load() {
		try {
			const page = await api.brainMessages();
			const wasEmpty = items.length === 0;
			items = mergePage(items, page.items);
			if (wasEmpty) nextCursor = page.nextCursor ?? null;
			failed = false;
		} catch {
			failed = true;
		} finally {
			loading = false;
		}
		if (firstLoad && !failed) {
			firstLoad = false;
			await tick();
			// Newest message at the bottom: start there.
			root?.querySelector('[data-testid="brain-message"]:last-child')?.scrollIntoView({ block: 'end' });
		}
	}
	async function loadOlder() {
		if (!nextCursor || loadingOlder) return;
		loadingOlder = true;
		try {
			const page = await api.brainMessages(nextCursor);
			items = mergePage(items, page.items);
			nextCursor = page.nextCursor ?? null;
			failed = false;
		} catch {
			failed = true;
		} finally {
			loadingOlder = false;
		}
	}

	onMount(() => {
		void load();
		const unsubscribe = startLiveRefresh(load);
		// `play` does not bubble: one recording at a time.
		const only = (e: Event) => root?.querySelectorAll('audio').forEach((a) => a !== e.target && !a.paused && a.pause());
		root?.addEventListener('play', only, true);
		return () => {
			unsubscribe();
			root?.removeEventListener('play', only, true);
		};
	});
</script>

<section bind:this={root} data-testid="brain-view" aria-labelledby="brain-heading">
	<PageHeader title={t('brain.title')} description={t('brain.hint')} testid="view-heading" />
	{#if loading}
		<p class="text-muted-foreground text-sm" role="status">…</p>
	{:else if failed && items.length === 0}
		<EmptyState title={t('brain.loadFailed')} icon={MessagesSquare}>
			<Button class="mt-2" variant="outline" onclick={load}>{t('brain.retry')}</Button>
		</EmptyState>
	{:else if items.length === 0}
		<div data-testid="brain-empty">
			<EmptyState title={t('brain.empty')} icon={MessagesSquare}><p>{t('brain.emptyHint')}</p></EmptyState>
		</div>
	{:else}
		{#if nextCursor}
			<div class="mb-3 flex justify-center">
				<Button variant="outline" data-testid="brain-load-older" disabled={loadingOlder} onclick={loadOlder}>{t('brain.loadOlder')}</Button>
			</div>
		{/if}
		{#if failed}<p class="text-destructive mb-3 text-sm" role="alert">{t('brain.loadFailed')}</p>{/if}
		<ol class="flex flex-col gap-2.5" aria-label={t('brain.list')}>
			{#each messages as m (m.id)}
				{@const who = speakerOf(m)}
				{@const src = audioUrl(m)}
				<li
					class={[
						'flex max-w-[min(100%,40rem)] flex-col gap-1.5 rounded-xl border px-3.5 py-2.5 [overflow-wrap:anywhere]',
						who === 'you' && 'bg-ui-accent-soft self-end',
						who === 'brain' && 'bg-card shadow-card self-start',
						who === 'status' && 'text-muted-foreground self-center border-dashed text-[13px]'
					]}
					data-testid="brain-message"
					data-kind={m.kind}
					data-author={m.author}
				>
					<div class="text-muted-foreground flex flex-wrap items-baseline gap-x-2 text-[12px]">
						<span class="font-semibold">{t(`brain.${who}`)}</span>
						{#if src}<span>{t('brain.voice')}</span>{/if}
						<time datetime={new Date(m.createdAt).toISOString()}>{stamp(m.createdAt)}</time>
					</div>
					{#if src}<BrainAudio {src} />{/if}
					{#if m.text}
						<p class="text-sm whitespace-pre-wrap" data-testid={src ? 'brain-transcript' : 'brain-text'}>{m.text}</p>
					{:else if src}
						<p class="text-muted-foreground text-[13px]" data-testid="brain-transcript">{t('brain.noTranscript')}</p>
					{/if}
				</li>
			{/each}
		</ol>
	{/if}
</section>
