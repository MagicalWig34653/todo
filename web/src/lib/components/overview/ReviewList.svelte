<script lang="ts">
	import { tick } from 'svelte';
	import { api, type Review } from '#lib/api.js';
	import { decisionNeedsNote } from '#lib/commandCenter.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import {
		BATCH_MAX,
		failureCodes,
		pruneSelection,
		selectAllVisible,
		selectionState,
		toggleSelection,
		type BatchItem,
		type BatchResponse
	} from '#lib/reviewBulk.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import EmptyState from '../app/EmptyState.svelte';
	import ReviewDecision from './ReviewDecision.svelte';
	import Gauge from '@lucide/svelte/icons/gauge';
	import X from '@lucide/svelte/icons/x';

	/** Pending reviews with multi-select and a bulk action bar (card 9791E2C3). The single decision per row is unchanged. */
	interface Props {
		reviews: Review[];
		onopen: (taskID: string, title: string) => void;
		onrefresh: () => void | Promise<void>;
	}
	let { reviews, onopen, onrefresh }: Props = $props();

	type Decision = 'accept' | 'changes_requested';
	let filter = $state<'all' | 'brain'>('all');
	let selected = $state<Set<string>>(new Set());
	let note = $state('');
	let confirming = $state<Decision | null>(null);
	let needNote = $state(false);
	let busy = $state(false);
	let outcome = $state<{ decision: Decision; response: BatchResponse; titles: Record<string, string> } | null>(null);
	let confirmButton = $state<HTMLButtonElement | null>(null);
	let resultBox = $state<HTMLElement | null>(null);

	const brainCount = $derived(reviews.filter((r) => r.brainRecommended).length);
	const listed = $derived(filter === 'brain' ? reviews.filter((r) => r.brainRecommended) : reviews);
	const listedIDs = $derived(listed.map((r) => r.id));
	const selState = $derived(selectionState(selected, listedIDs));
	const capped = $derived(listedIDs.length > BATCH_MAX);

	// Rows that vanish (decided elsewhere, refreshed away, filtered out) leave the selection, and an open confirmation
	// never refers to a different count than the one shown.
	$effect(() => {
		const kept = pruneSelection(selected, listedIDs);
		if (kept.size !== selected.size) {
			selected = kept;
			confirming = null;
		}
	});

	// The list may be scrolled far from the top when the batch returns: bring the report into view.
	$effect(() => {
		if (outcome && resultBox) resultBox.scrollIntoView({ block: 'center', behavior: 'instant' });
	});

	function toggle(id: string) {
		selected = toggleSelection(selected, id);
		confirming = null;
	}
	function toggleAll() {
		selected = selState === 'all' ? new Set() : selectAllVisible(listedIDs);
		confirming = null;
	}
	function clear() {
		selected = new Set();
		confirming = null;
		needNote = false;
	}
	async function ask(decision: Decision) {
		if (busy || selected.size === 0) return;
		if (decision === 'changes_requested' && decisionNeedsNote('request_changes', note)) {
			needNote = true;
			return;
		}
		needNote = false;
		outcome = null;
		confirming = decision;
		await tick();
		confirmButton?.focus();
	}
	async function run() {
		if (!confirming || busy) return;
		const decision = confirming;
		const ids = listedIDs.filter((id) => selected.has(id));
		const titles = Object.fromEntries(reviews.filter((r) => selected.has(r.id)).map((r) => [r.id, r.taskTitle ?? '']));
		busy = true;
		let response: BatchResponse | undefined;
		const ok = await attempt(async () => {
			response = await api.decideReviewsBatch(ids, decision, note.trim());
		});
		busy = false;
		confirming = null;
		if (ok && response) {
			outcome = { decision, response, titles };
			selected = new Set();
			note = '';
		}
		// Always reload: after a failed request the real state is what counts.
		await onrefresh();
	}
	function barKey(e: KeyboardEvent) {
		if (e.key !== 'Escape' || busy) return;
		e.preventDefault();
		if (confirming) confirming = null;
		else clear();
	}
	/** Stable result code, refined by the single-decision reason where the UI has a plainer wording for it. */
	function reasonLabel(f: BatchItem): string {
		const known = f.result === 'forbidden' && (f.reason === 'not_the_reviewer' || f.reason === 'cannot_decide_own_review');
		return t(`cc.review.bulk.reason.${known ? f.reason : f.result}` as MessageKey);
	}
	const failures = $derived(outcome ? failureCodes(outcome.response) : []);
	const doneCount = $derived(outcome?.response.summary.ok ?? 0);
</script>

<div class="flex max-w-3xl flex-col gap-3">
	{#if reviews.length > 0}
		<div class="flex flex-wrap items-center gap-x-4 gap-y-2" data-testid="review-toolbar">
			<label class="flex min-h-9 cursor-pointer items-center gap-2 text-sm">
				<Checkbox
					checked={selState === 'all'}
					aria-checked={selState === 'some' ? 'mixed' : selState === 'all'}
					disabled={listed.length === 0 || busy}
					onchange={toggleAll}
					data-testid="review-select-all"
				/>
				{t('cc.review.bulk.selectAll')}
			</label>
			<div class="flex flex-wrap gap-1.5" role="group" aria-label={t('cc.review.filter.label')}>
				<Button
					variant={filter === 'all' ? 'secondary' : 'outline'}
					size="sm"
					class="rounded-full"
					aria-pressed={filter === 'all'}
					data-testid="review-filter-all"
					onclick={() => (filter = 'all')}>{t('cc.review.filter.all', { count: reviews.length })}</Button
				>
				<Button
					variant={filter === 'brain' ? 'secondary' : 'outline'}
					size="sm"
					class="rounded-full"
					aria-pressed={filter === 'brain'}
					data-testid="review-filter-brain"
					onclick={() => (filter = 'brain')}>{t('cc.review.filter.brain', { count: brainCount })}</Button
				>
			</div>
		</div>
		{#if capped && selState === 'all'}<p class="text-muted-foreground text-xs" data-testid="review-capped">{t('cc.review.bulk.capped', { max: BATCH_MAX })}</p>{/if}
	{/if}

	{#if outcome}
		<div
			class="flex flex-col gap-2 rounded-lg border p-3 text-sm {failures.length ? 'border-warning/50 bg-warning-soft/60' : 'border-success/40 bg-success-soft/60'}"
			role={failures.length ? 'alert' : 'status'}
			bind:this={resultBox}
			data-testid="review-bulk-result"
		>
			<div class="flex items-start justify-between gap-2">
				<p class="font-medium">
					{#if failures.length === 0}
						{t(outcome.decision === 'accept' ? 'cc.review.bulk.doneAccept' : 'cc.review.bulk.doneChanges', { count: doneCount })}
					{:else if doneCount === 0}
						{t('cc.review.bulk.allFailed', { failed: failures.length })}
					{:else}
						{t('cc.review.bulk.partial', { ok: doneCount, total: outcome.response.results.length, failed: failures.length })}
					{/if}
				</p>
				<Button variant="ghost" size="icon" class="-mt-1 -mr-1 size-8" aria-label={t('cc.review.bulk.dismiss')} onclick={() => (outcome = null)}><X class="size-4" aria-hidden="true" /></Button>
			</div>
			{#if failures.length > 0}
				<ul class="flex flex-col gap-1" data-testid="review-bulk-failures">
					{#each failures as f (f.reviewID)}
						<li class="flex flex-wrap gap-x-2" data-result={f.result}>
							<span class="font-medium break-words">{outcome.titles[f.reviewID] || f.reviewID}</span>
							<span class="text-muted-foreground">{reasonLabel(f)}</span>
						</li>
					{/each}
				</ul>
			{/if}
		</div>
	{/if}

	{#if reviews.length === 0}
		<EmptyState title={t('cc.review.empty')} icon={Gauge}><p>{t('cc.review.emptyHint')}</p></EmptyState>
	{:else if listed.length === 0}
		<EmptyState title={t('cc.review.filter.empty')} icon={Gauge}><p></p></EmptyState>
	{/if}

	<ul class="flex flex-col gap-3" data-testid="cc-reviews">
		{#each listed as r (r.id)}
			<li class="flex items-start gap-2" data-testid="review-row" data-review-id={r.id}>
				<label class="flex min-h-9 min-w-9 shrink-0 cursor-pointer items-center justify-center">
					<Checkbox
						checked={selected.has(r.id)}
						disabled={busy || (!selected.has(r.id) && selected.size >= BATCH_MAX)}
						aria-label={t('cc.review.bulk.select', { title: r.taskTitle ?? '' })}
						onchange={() => toggle(r.id)}
						data-testid="review-select"
					/>
				</label>
				<div class="min-w-0 flex-1">
					<ReviewDecision
						taskID={r.taskID}
						summary={r.summary}
						requestedBy={r.requestedByLabel}
						brainRecommended={r.brainRecommended}
						context={t('cc.question.in', { task: r.taskTitle ?? '', project: r.projectName ?? '' })}
						onopen={() => onopen(r.taskID, r.taskTitle ?? '')}
						ondecided={onrefresh}
					/>
				</div>
			</li>
		{/each}
	</ul>

	{#if selected.size > 0}
		<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
		<section
			class="bg-card sticky bottom-[calc(4.75rem+env(safe-area-inset-bottom))] z-40 flex flex-col gap-2 rounded-xl border p-3 shadow-lg menu:bottom-3 menu:z-10"
			aria-label={t('cc.review.bulk.region')}
			data-testid="review-bulk-bar"
			onkeydown={barKey}
		>
			<div class="flex flex-wrap items-center justify-between gap-2">
				<p class="text-sm font-medium" aria-live="polite" data-testid="review-bulk-count">{t('cc.review.bulk.selected', { count: selected.size })}</p>
				<Button variant="ghost" size="sm" disabled={busy} data-testid="review-bulk-clear" onclick={clear}>{t('cc.review.bulk.clear')}</Button>
			</div>
			{#if confirming}
				<div class="flex flex-col gap-2 rounded-lg border border-warning/50 bg-warning-soft/60 p-2.5" role="alertdialog" aria-labelledby="bulk-confirm-title" aria-describedby="bulk-confirm-hint" data-testid="review-bulk-confirm">
					<p id="bulk-confirm-title" class="text-sm font-medium">
						{#if confirming === 'accept'}
							{selected.size === 1 ? t('cc.review.bulk.confirmAcceptOne') : t('cc.review.bulk.confirmAccept', { count: selected.size })}
						{:else}
							{selected.size === 1 ? t('cc.review.bulk.confirmChangesOne') : t('cc.review.bulk.confirmChanges', { count: selected.size })}
						{/if}
					</p>
					<p id="bulk-confirm-hint" class="text-muted-foreground text-xs">{t('cc.review.bulk.confirmHint')}</p>
					<div class="flex flex-wrap gap-2 max-sm:flex-col">
						<Button bind:ref={confirmButton} disabled={busy} data-testid="review-bulk-confirm-go" onclick={run}>
							{busy ? t('cc.review.bulk.busy') : t(confirming === 'accept' ? 'cc.review.bulk.confirmGoAccept' : 'cc.review.bulk.confirmGoChanges', { count: selected.size })}
						</Button>
						<Button variant="outline" disabled={busy} data-testid="review-bulk-confirm-cancel" onclick={() => (confirming = null)}>{t('cc.review.bulk.cancel')}</Button>
					</div>
				</div>
			{:else}
				<label class="flex flex-col gap-1 text-xs">
					<span class="text-muted-foreground">{t('cc.review.bulk.note')} · {t('cc.review.bulk.noteHint')}</span>
					<Textarea bind:value={note} rows={2} maxlength={4000} class="min-h-16" data-testid="review-bulk-note" />
				</label>
				{#if needNote}<p class="text-destructive text-xs" role="alert">{t('cc.review.bulk.noteRequired')}</p>{/if}
				<div class="flex flex-wrap gap-2 max-sm:flex-col">
					<Button disabled={busy} data-testid="review-bulk-accept" onclick={() => ask('accept')}>{t('cc.review.bulk.accept')}</Button>
					<Button variant="outline" disabled={busy} data-testid="review-bulk-changes" onclick={() => ask('changes_requested')}>{t('cc.review.bulk.changes')}</Button>
				</div>
			{/if}
		</section>
	{/if}
</div>
