<script lang="ts">
	import { api } from '#lib/api.js';
	import { validateAnswer } from '#lib/commandCenter.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import CircleHelp from '@lucide/svelte/icons/circle-help';

	/** One open question with its answer controls: options become buttons, otherwise free text. */
	interface Props {
		id: string;
		prompt: string;
		options: string[];
		blocking?: boolean;
		askedBy?: string | null;
		/** Where the question belongs (task and project), shown in aggregate lists. */
		context?: string;
		onanswered: () => void | Promise<void>;
	}
	let { id, prompt, options, blocking = false, askedBy, context, onanswered }: Props = $props();

	let text = $state('');
	let busy = $state(false);
	const valid = $derived(validateAnswer(options, text));

	async function send(answer: string) {
		const value = validateAnswer(options, answer);
		if (!value || busy) return;
		busy = true;
		const ok = await attempt(() => api.answerQuestion(id, value));
		busy = false;
		if (ok) text = '';
		// Also after a conflict (answered elsewhere first): show the real state.
		await onanswered();
	}
</script>

<div class="bg-ui-accent-soft/50 flex flex-col gap-2 rounded-lg border p-2.5 text-sm" data-testid="question" data-question-id={id}>
	<div class="flex items-start gap-2">
		<CircleHelp class="text-ui-accent-ink mt-0.5 size-4 shrink-0" aria-hidden="true" />
		<div class="min-w-0 flex-1">
			{#if context}<p class="text-muted-foreground mb-0.5 text-xs">{context}</p>{/if}
			{#if askedBy}<p class="text-muted-foreground text-xs">{t('cc.question.title', { who: askedBy })}{blocking ? ` · ${t('cc.question.blocking')}` : ''}</p>{/if}
			<p class="font-medium break-words whitespace-pre-wrap" data-testid="question-prompt">{prompt}</p>
		</div>
	</div>
	{#if options.length > 0}
		<div class="flex flex-wrap gap-1.5" role="group" aria-label={t('cc.question.pick')}>
			{#each options as option (option)}
				<Button size="sm" variant="outline" disabled={busy} data-testid="question-option" onclick={() => send(option)}>{option}</Button>
			{/each}
		</div>
	{:else}
		<form
			class="flex flex-col gap-1.5"
			onsubmit={(e) => {
				e.preventDefault();
				send(text);
			}}
		>
			<Textarea bind:value={text} rows={2} class="min-h-14" maxlength={10000} placeholder={t('cc.question.answerPlaceholder')} aria-label={t('cc.question.answerLabel')} data-testid="question-answer" />
			<div class="flex justify-end">
				<Button size="sm" type="submit" disabled={busy || !valid} data-testid="question-send">{t('cc.question.send')}</Button>
			</div>
		</form>
	{/if}
</div>
