<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Maximize from '@lucide/svelte/icons/maximize';

	/** Large view of screenshots and images with previous/next, thumbnails and full screen. */
	export interface GalleryImage {
		id: string;
		url: string;
		label: string;
	}
	let { images }: { images: GalleryImage[] } = $props();

	let index = $state(0);
	let stage = $state<HTMLElement | null>(null);
	const current = $derived(images[Math.min(index, images.length - 1)]);
	const many = $derived(images.length > 1);

	function step(delta: number) {
		if (images.length === 0) return;
		index = (Math.min(index, images.length - 1) + delta + images.length) % images.length;
	}
	function onkeydown(e: KeyboardEvent) {
		if (!many || (e.target as HTMLElement).closest('input,textarea,select')) return;
		if (e.key === 'ArrowLeft') (e.preventDefault(), step(-1));
		else if (e.key === 'ArrowRight') (e.preventDefault(), step(1));
	}
	function fullscreen() {
		void stage?.requestFullscreen?.().catch(() => window.open(current?.url, '_blank', 'noopener'));
	}
</script>

{#if current}
	<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
	<div class="flex min-w-0 flex-col gap-2" role="group" aria-label={t('card.gallery')} data-testid="card-gallery" {onkeydown}>
		<div bind:this={stage} class="bg-muted relative flex min-h-48 items-center justify-center overflow-hidden rounded-xl border">
			<img src={current.url} alt={current.label} class="max-h-[60vh] w-auto max-w-full object-contain" data-testid="gallery-image" />
			{#if many}
				<Button variant="secondary" size="icon" class="absolute top-1/2 left-2 -translate-y-1/2 rounded-full opacity-90" aria-label={t('card.gallery.prev')} data-testid="gallery-prev" onclick={() => step(-1)}>
					<ChevronLeft aria-hidden="true" />
				</Button>
				<Button variant="secondary" size="icon" class="absolute top-1/2 right-2 -translate-y-1/2 rounded-full opacity-90" aria-label={t('card.gallery.next')} data-testid="gallery-next" onclick={() => step(1)}>
					<ChevronRight aria-hidden="true" />
				</Button>
			{/if}
		</div>
		<div class="flex flex-wrap items-center justify-between gap-2 text-xs">
			<span class="text-muted-foreground min-w-0 [overflow-wrap:anywhere]" aria-live="polite">
				{current.label}{many ? ` · ${t('card.gallery.count', { index: Math.min(index, images.length - 1) + 1, total: images.length })}` : ''}
			</span>
			<Button variant="outline" size="sm" onclick={fullscreen} data-testid="gallery-fullscreen"><Maximize aria-hidden="true" />{t('card.gallery.fullscreen')}</Button>
		</div>
		{#if many}
			<div class="flex gap-2 overflow-x-auto pb-1">
				{#each images as image, i (image.id)}
					<button
						type="button"
						class={['relative size-16 shrink-0 overflow-hidden rounded-lg border', i === index && 'ring-ui-accent ring-2']}
						aria-label={t('card.gallery.show', { label: image.label })}
						aria-current={i === index}
						onclick={() => (index = i)}
					>
						<img src={image.url} alt="" loading="lazy" class="size-full object-cover object-top" />
					</button>
				{/each}
			</div>
		{/if}
	</div>
{/if}
