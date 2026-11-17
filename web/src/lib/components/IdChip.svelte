<script lang="ts">
	import { onDestroy } from 'svelte';
	import { copyText } from '#lib/clipboard.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { shortID } from '#lib/shortId.js';

	/**
	 * Short id (first 8 characters) of an entry in monospace. Activating the button (tap, Enter, Space) copies the full UUID.
	 * The confirmation replaces the text inside the same grid cell, so the chip never changes its size.
	 */
	let {
		id,
		kind,
		subtle = false,
		testid = 'id-chip'
	}: { id: string; kind?: MessageKey; subtle?: boolean; testid?: string } = $props();

	const short = $derived(shortID(id));
	let copied = $state(false);
	let timer: ReturnType<typeof setTimeout> | undefined;

	async function copy(e: Event) {
		// On board cards the chip sits inside a clickable area: copying must not open the card.
		e.stopPropagation();
		if (!(await copyText(id))) return;
		copied = true;
		clearTimeout(timer);
		timer = setTimeout(() => (copied = false), 1400);
	}
	onDestroy(() => clearTimeout(timer));
</script>

{#if id}
	<span class="inline-flex items-center gap-1.5" data-testid="{testid}-wrap">
		{#if kind}<span class="text-muted-foreground text-xs">{t(kind)}</span>{/if}
		<button
			type="button"
			class={[
				'hit-area text-muted-foreground hover:text-foreground focus-visible:ring-ring/50 relative inline-grid cursor-copy rounded-md font-mono tracking-wide outline-none focus-visible:ring-2',
				subtle ? 'px-1 py-px text-[11px]' : 'bg-muted px-1.5 py-0.5 text-xs'
			]}
			aria-label={kind ? t('id.copyWithKind', { id: short, kind: t(kind) }) : t('id.copy', { id: short })}
			title={id}
			data-testid={testid}
			data-id={id}
			onclick={copy}
			onkeydown={(e) => e.stopPropagation()}
		>
			<span class={['col-start-1 row-start-1', copied && 'invisible']} aria-hidden="true">{short}</span>
			<span class={['text-success col-start-1 row-start-1 font-sans font-medium', !copied && 'invisible']} aria-hidden="true">{t('id.copied')}</span>
		</button>
		<span class="sr-only" role="status" aria-live="polite" data-testid="{testid}-status">{copied ? t('id.copied') : ''}</span>
	</span>
{/if}
