<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { chooseLabel, previewState, roveFocus, variantName, type ReviewVariant } from '#lib/reviewVariants.js';
	import { REVIEW_UNDO_MINUTES } from '#lib/reviewUndo.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ImageOff from '@lucide/svelte/icons/image-off';

	/**
	 * The offered variants of a pending review (card 1D9C8B0C): one card per variant with image, label and description. One tap
	 * on "Wählen" accepts the review with that variant (no extra dialog). Plain buttons in a labelled group, not a radio group,
	 * because nothing is selected first and confirmed after. Keyboard: the group is ONE tab stop (the last focused button, roving
	 * tabindex); arrow keys move between the buttons (stopping at the ends), Home/End jump, Enter/Space choose. A variant without
	 * attachment has no picture area at all (compact card); an attachment whose preview fails gets a small fallback with the label.
	 * Focus: the primary button's own ring is replaced by the accent glow (layout.css), only a faint halo, so the button turns on the
	 * real outline (`focus-visible:outline-solid`; colour from the global focus rule, 5:1 on the card in dark).
	 */
	interface Props {
		variants: ReviewVariant[];
		/** A decision is running: all buttons wait, the chosen one says so. */
		busy?: boolean;
		/** Id of the variant being saved. */
		choosing?: string | null;
		onchoose: (variantID: string) => void;
		/** Somebody else decides (named review, ADR 0043): the variants are shown without "Wählen". */
		readonly?: boolean;
	}
	let { variants, busy = false, choosing = null, onchoose, readonly = false }: Props = $props();

	const uid = $props.id();
	let failed = $state<Record<string, boolean>>({});
	let group = $state<HTMLElement>();
	/** Index of the button that is the tab stop (last focused). */
	let active = $state(0);
	const current = $derived(Math.min(active, variants.length - 1));
	function buttons(): HTMLButtonElement[] {
		return group ? Array.from(group.querySelectorAll<HTMLButtonElement>('[data-variant-choose]')) : [];
	}
	function onkeydown(e: KeyboardEvent) {
		const list = buttons();
		const from = list.indexOf(e.target as HTMLButtonElement);
		if (from < 0) return;
		const to = roveFocus(e, from, list.length);
		if (to === null) return;
		e.preventDefault();
		list[to]?.focus();
	}
	const columns = $derived(variants.length === 3 ? '@lg:grid-cols-2 @xl:grid-cols-3' : '@lg:grid-cols-2');
</script>

<!-- Key handling is delegated from the real buttons inside (roving focus); the group itself is not interactive. -->
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div
	bind:this={group}
	class="@container flex min-w-0 flex-col gap-2"
	role="group"
	aria-labelledby="{uid}-title"
	aria-describedby={readonly ? undefined : `${uid}-hint`}
	data-testid="review-variants"
	{onkeydown}
>
	<div>
		<h3 id="{uid}-title" class="text-sm font-semibold">{t('cc.review.variants.title')}</h3>
		{#if !readonly}<p id="{uid}-hint" class="text-muted-foreground text-xs" data-testid="review-variants-hint">{t('cc.review.variants.hint', { minutes: REVIEW_UNDO_MINUTES })}</p>{/if}
	</div>
	<ul class="grid grid-cols-1 gap-3 {columns}">
		{#each variants as v, i (v.id)}
			<li class="min-w-0">
				<article class="bg-card focus-within:border-ui-accent focus-within:ring-ui-accent flex h-full flex-col gap-2 rounded-xl border p-2.5 shadow-xs focus-within:ring-1" aria-labelledby="{uid}-{v.id}-label" data-testid="review-variant" data-variant-id={v.id}>
					{#if previewState(v, !!failed[v.id]) === 'image'}
						<img
							src={api.attachmentPreviewURL(v.attachmentID!)}
							alt={t('cc.review.variants.imageAlt', { name: variantName(v.id), label: v.label })}
							loading="lazy"
							class="bg-muted aspect-video w-full rounded-lg border object-cover"
							data-testid="review-variant-image"
							onerror={() => (failed = { ...failed, [v.id]: true })}
						/>
					{:else if previewState(v, !!failed[v.id]) === 'fallback'}
						<div class="bg-muted text-muted-foreground flex items-center gap-2 rounded-lg border px-2.5 py-1.5 text-xs" data-testid="review-variant-placeholder">
							<ImageOff class="size-4 shrink-0" aria-hidden="true" />
							<span class="min-w-0 break-words"><span class="font-medium">{v.label}</span> · {t('cc.review.variants.noPreview')}</span>
						</div>
					{/if}
					<div class="min-w-0">
						<span class="text-ui-accent-ink text-xs font-semibold" aria-hidden="true">{t('cc.review.variants.tag', { name: variantName(v.id) })}</span>
						<h4 id="{uid}-{v.id}-label" class="font-semibold break-words max-sm:text-base">
							<span class="sr-only">{t('cc.review.variants.tag', { name: variantName(v.id) })}: </span>{v.label}
						</h4>
					</div>
					{#if v.description}<p class="text-muted-foreground flex-1 text-[0.8125rem] leading-snug break-words whitespace-pre-wrap">{v.description}</p>{:else}<span class="flex-1"></span>{/if}
					{#if !readonly}<Button
						type="button"
						class="h-11 w-full text-sm focus-visible:outline-solid max-sm:text-base"
						disabled={busy}
						aria-busy={choosing === v.id}
						aria-label={chooseLabel(v)}
						data-testid="review-variant-choose"
						data-variant-choose
						tabindex={i === current ? 0 : -1}
						onfocus={() => (active = i)}
						onclick={() => onchoose(v.id)}>{choosing === v.id ? t('cc.review.variants.saving') : t('cc.review.variants.button')}</Button
					>{/if}
				</article>
			</li>
		{/each}
	</ul>
</div>
