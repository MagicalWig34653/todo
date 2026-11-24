<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { nowEntry, nowEntryLabel, type NowEntry } from '#lib/now.js';
	import Radio from '@lucide/svelte/icons/radio';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';

	/** Slim shortcut from the start page to "Jetzt". One small request (compact, one entry per list) on load and on live hints. */
	let { onopen }: { onopen: () => void } = $props();

	let entry = $state<NowEntry>({ running: null, waiting: null });
	const label = $derived(nowEntryLabel(entry));
	const waitingLabel = $derived(
		entry.waiting ? (entry.waiting === 1 ? t('now.entry.waitingOne') : t('now.entry.waiting', { count: entry.waiting })) : ''
	);

	async function load() {
		try {
			entry = nowEntry((await api.overviewNow({ compact: true, limit: 1 })).now);
		} catch {
			/* the shortcut stays usable without counters */
		}
	}
	onMount(() => {
		void load();
		return startLiveRefresh(load);
	});

	function open(e: MouseEvent) {
		if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
		e.preventDefault();
		onopen();
	}
</script>

<a
	href="/now"
	class="bg-card hover:bg-muted focus-visible:ring-ring/50 flex min-h-11 items-center gap-2.5 rounded-xl border px-3.5 py-2 text-sm shadow-card transition-colors outline-none focus-visible:ring-2"
	data-testid="now-entry"
	onclick={open}
>
	<Radio class="text-ui-accent size-4 shrink-0" aria-hidden="true" />
	<span class="font-semibold">{t('now.entry.title')}</span>
	{#if label}<span class="text-muted-foreground" data-testid="now-entry-running">{label}</span>{/if}
	{#if waitingLabel}<span class="text-muted-foreground" data-testid="now-entry-waiting">· {waitingLabel}</span>{/if}
	<ChevronRight class="text-muted-foreground ml-auto size-4 shrink-0" aria-hidden="true" />
</a>
