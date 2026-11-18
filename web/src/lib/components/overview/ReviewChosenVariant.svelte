<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { otherVariants, variantName, type ReviewVariant, type VariantReview } from '#lib/reviewVariants.js';
	import ImageOff from '@lucide/svelte/icons/image-off';

	/** The accepted review's choice: the chosen variant with its image, the others as small labels. */
	interface Props {
		review: VariantReview;
		chosen: ReviewVariant;
	}
	let { review, chosen }: Props = $props();
	let failed = $state(false);
	const others = $derived(otherVariants(review));
</script>

<div class="flex flex-col gap-2" data-testid="review-chosen">
	<div class="grid grid-cols-[8rem_1fr] items-center gap-3 max-sm:grid-cols-[6rem_1fr]">
		{#if chosen.attachmentID && !failed}
			<img
				src={api.attachmentPreviewURL(chosen.attachmentID)}
				alt={t('cc.review.variants.imageAlt', { name: variantName(chosen.id), label: chosen.label })}
				class="bg-muted aspect-video w-full rounded-lg border object-cover"
				onerror={() => (failed = true)}
			/>
		{:else}
			<div class="bg-muted text-muted-foreground flex aspect-video w-full items-center justify-center rounded-lg border" aria-hidden="true"><ImageOff class="size-5" /></div>
		{/if}
		<div class="min-w-0">
			<p class="text-ui-accent-ink text-xs font-semibold">{t('cc.review.variants.tag', { name: variantName(chosen.id) })}</p>
			<p class="font-semibold break-words">{chosen.label}</p>
			{#if chosen.description}<p class="text-muted-foreground text-sm break-words whitespace-pre-wrap">{chosen.description}</p>{/if}
		</div>
	</div>
	{#if others.length > 0}
		<div class="flex flex-wrap items-center gap-1.5 text-xs">
			<span class="text-muted-foreground">{t('cc.review.variants.others')}</span>
			{#each others as v (v.id)}
				<span class="bg-muted text-muted-foreground rounded-full px-2 py-0.5 break-words">{t('cc.review.variants.other', { name: variantName(v.id), label: v.label })}</span>
			{/each}
		</div>
	{/if}
</div>
