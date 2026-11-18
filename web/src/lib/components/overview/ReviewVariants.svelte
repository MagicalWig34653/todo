<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { chooseLabel, variantName, type ReviewVariant } from '#lib/reviewVariants.js';
	import { REVIEW_UNDO_MINUTES } from '#lib/reviewUndo.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ImageOff from '@lucide/svelte/icons/image-off';

	/**
	 * The offered variants of a pending review (card 1D9C8B0C): one card per variant with image, label and description. One tap
	 * on "Wählen" accepts the review with that variant (no extra dialog). Plain buttons in a labelled list, not a radio group,
	 * because nothing is selected first and confirmed after. A missing or failing image becomes a placeholder; choosing stays possible.
	 */
	interface Props {
		variants: ReviewVariant[];
		/** A decision is running: all buttons wait, the chosen one says so. */
		busy?: boolean;
		/** Id of the variant being saved. */
		choosing?: string | null;
		onchoose: (variantID: string) => void;
	}
	let { variants, busy = false, choosing = null, onchoose }: Props = $props();

	const uid = $props.id();
	let failed = $state<Record<string, boolean>>({});
	const columns = $derived(variants.length === 3 ? '@lg:grid-cols-2 @2xl:grid-cols-3' : '@lg:grid-cols-2');
</script>

<div class="@container flex min-w-0 flex-col gap-2" data-testid="review-variants">
	<div>
		<h3 id="{uid}-title" class="text-sm font-semibold">{t('cc.review.variants.title')}</h3>
		<p class="text-muted-foreground text-xs" data-testid="review-variants-hint">{t('cc.review.variants.hint', { minutes: REVIEW_UNDO_MINUTES })}</p>
	</div>
	<ul class="grid grid-cols-1 gap-3 {columns}" aria-labelledby="{uid}-title">
		{#each variants as v (v.id)}
			<li class="min-w-0">
				<article class="bg-card focus-within:border-ui-accent focus-within:ring-ui-accent flex h-full flex-col gap-2 rounded-xl border p-2.5 shadow-xs focus-within:ring-1" aria-labelledby="{uid}-{v.id}-label" data-testid="review-variant" data-variant-id={v.id}>
					{#if v.attachmentID && !failed[v.id]}
						<img
							src={api.attachmentPreviewURL(v.attachmentID)}
							alt={t('cc.review.variants.imageAlt', { name: variantName(v.id), label: v.label })}
							loading="lazy"
							class="bg-muted aspect-video w-full rounded-lg border object-cover"
							data-testid="review-variant-image"
							onerror={() => (failed = { ...failed, [v.id]: true })}
						/>
					{:else}
						<div class="bg-muted text-muted-foreground flex aspect-video w-full flex-col items-center justify-center gap-1 rounded-lg border px-2 text-center text-xs" data-testid="review-variant-placeholder">
							<ImageOff class="size-5" aria-hidden="true" />
							<span class="font-medium break-words">{v.label}</span>
							<span>{t('cc.review.variants.noImage')}</span>
						</div>
					{/if}
					<div class="min-w-0">
						<span class="text-ui-accent-ink text-xs font-semibold" aria-hidden="true">{t('cc.review.variants.tag', { name: variantName(v.id) })}</span>
						<h4 id="{uid}-{v.id}-label" class="font-semibold break-words max-sm:text-base">
							<span class="sr-only">{t('cc.review.variants.tag', { name: variantName(v.id) })}: </span>{v.label}
						</h4>
					</div>
					{#if v.description}<p class="text-muted-foreground flex-1 text-[0.8125rem] leading-snug break-words whitespace-pre-wrap">{v.description}</p>{:else}<span class="flex-1"></span>{/if}
					<Button
						type="button"
						class="h-11 w-full text-sm max-sm:text-base"
						disabled={busy}
						aria-busy={choosing === v.id}
						aria-label={chooseLabel(v)}
						data-testid="review-variant-choose"
						onclick={() => onchoose(v.id)}>{choosing === v.id ? t('cc.review.variants.saving') : t('cc.review.variants.button')}</Button
					>
				</article>
			</li>
		{/each}
	</ul>
</div>
