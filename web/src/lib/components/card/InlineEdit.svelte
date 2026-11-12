<script lang="ts">
	import { tick, untrack } from 'svelte';
	import { api, type Task } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import AlignLeft from '@lucide/svelte/icons/align-left';
	import Markdown from './Markdown.svelte';

	/**
	 * Inline editing of the task title (large heading) or description (Markdown text) in the card detail.
	 * A change saves on blur / Enter; Escape discards. Needs the current task for its version; failures use the global notice.
	 */
	let {
		task,
		field,
		editable = true,
		onchanged
	}: { task: Task; field: 'title' | 'description'; editable?: boolean; onchanged: () => unknown } = $props();

	const stored = $derived((field === 'title' ? task.title : (task.description ?? '')) as string);
	let draft = $state('');
	let focused = $state(false);
	let editing = $state(false);
	let box = $state<HTMLTextAreaElement | null>(null);
	let saving = false;

	// Follow the stored value (live refresh) unless the person is typing.
	$effect(() => {
		const v = stored;
		untrack(() => {
			if (!focused && !editing) draft = v;
		});
	});

	async function commit() {
		const v = draft.trim();
		focused = false;
		editing = false;
		if (saving) return;
		if (v === stored.trim() || (field === 'title' && !v)) {
			draft = stored;
			return;
		}
		saving = true;
		try {
			const ok = await attempt(async () => {
				await api.updateTask(task, field === 'title' ? { title: v } : { description: v });
				await onchanged();
			}, async () => { await onchanged(); });
			if (!ok) draft = stored;
		} finally {
			saving = false;
		}
	}
	function cancel() {
		draft = stored;
		focused = false;
		editing = false;
	}
	function keydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.preventDefault();
			e.stopPropagation();
			cancel();
			(e.currentTarget as HTMLElement).blur();
		} else if (e.key === 'Enter' && (field === 'title' ? !e.shiftKey : e.metaKey || e.ctrlKey)) {
			e.preventDefault();
			(e.currentTarget as HTMLElement).blur();
		}
	}
	async function startEdit() {
		if (!editable) return;
		editing = true;
		await tick();
		box?.focus();
	}
</script>

{#if field === 'title'}
	<textarea
		bind:value={draft}
		rows="1"
		class="field-sizing-content hover:bg-muted/50 focus:bg-background focus:border-input w-full min-w-0 resize-none rounded-lg border border-transparent px-2 py-1 text-2xl leading-tight font-semibold tracking-tight [overflow-wrap:anywhere] outline-none focus-visible:ring-2 focus-visible:ring-ring/40 md:text-[1.7rem]"
		aria-label={t('card.title.edit')}
		readonly={!editable}
		data-testid="card-title"
		onfocus={() => (focused = true)}
		onblur={commit}
		onkeydown={keydown}
	></textarea>
{:else if editing}
	<textarea
		bind:this={box}
		bind:value={draft}
		rows="4"
		class="field-sizing-content border-input bg-background focus-visible:border-ring min-h-24 w-full shrink-0 resize-y rounded-lg border px-3 py-2 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring/40"
		placeholder={t('card.description.placeholder')}
		aria-label={t('card.description.edit')}
		data-testid="card-description-input"
		onfocus={() => (focused = true)}
		onblur={commit}
		onkeydown={keydown}
	></textarea>
	<p class="text-muted-foreground text-xs">{t('card.description.hint')}</p>
{:else}
	<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
	<div
		class={['hover:bg-muted/50 -mx-2 flex min-h-9 shrink-0 items-start gap-3 rounded-lg px-2 py-1.5', editable && 'cursor-text']}
		role={editable ? 'button' : undefined}
		tabindex={editable ? 0 : undefined}
		aria-label={editable ? t('card.description.edit') : undefined}
		data-testid="card-description-view"
		onclick={startEdit}
		onkeydown={(e) => { if (editable && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); void startEdit(); } }}
	>
		<AlignLeft class="text-muted-foreground mt-0.5 size-4 shrink-0" aria-hidden="true" />
		{#if stored.trim()}
			<div class="min-w-0 flex-1" data-testid="card-description"><Markdown text={stored} /></div>
		{:else}
			<span class="text-muted-foreground text-sm">{t('card.description')}</span>
		{/if}
	</div>
{/if}
