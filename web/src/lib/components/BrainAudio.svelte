<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import Play from '@lucide/svelte/icons/play';
	import Pause from '@lucide/svelte/icons/pause';

	/** One recording: a real button (Enter and Space work natively) in front of a hidden audio element that loads only on first play. */
	let { src }: { src: string } = $props();
	let el = $state<HTMLAudioElement>();
	let playing = $state(false);
	let failed = $state(false);

	async function toggle() {
		if (!el) return;
		failed = false;
		if (!el.paused) return el.pause();
		try {
			await el.play();
		} catch {
			failed = true;
		}
	}
</script>

<div class="flex flex-wrap items-center gap-2">
	<button
		type="button"
		class="bg-ui-accent text-ui-accent-foreground focus-visible:ring-ring/50 inline-flex size-10 shrink-0 items-center justify-center rounded-full outline-none focus-visible:ring-2"
		data-testid="brain-play"
		data-playing={playing}
		aria-label={playing ? t('brain.pause') : t('brain.play')}
		onclick={toggle}
	>
		{#if playing}<Pause class="size-5" aria-hidden="true" />{:else}<Play class="size-5" aria-hidden="true" />{/if}
	</button>
	<audio
		bind:this={el}
		{src}
		preload="none"
		onplay={() => (playing = true)}
		onpause={() => (playing = false)}
		onended={() => (playing = false)}
		onerror={() => ((failed = true), (playing = false))}
	></audio>
	{#if failed}<span class="text-destructive text-[13px]" role="status" data-testid="brain-audio-failed">{t('brain.audioFailed')}</span>{/if}
</div>
