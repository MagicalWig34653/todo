<script lang="ts">
	import { api } from '#lib/api.js';
	import { validateAnswer } from '#lib/commandCenter.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import ChatField from '../card/ChatField.svelte';
	import OptionButtons from './OptionButtons.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
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
		/** Button size of the options (the large card detail uses `default`). */
		size?: 'sm' | 'default';
		/** Opens the card detail; renders a footer button inside the card. */
		onopen?: () => void;
		onanswered: () => void | Promise<void>;
	}
	let { id, prompt, options, blocking = false, askedBy, context, size = 'sm', onopen, onanswered }: Props = $props();

	let text = $state('');
	let busy = $state(false);
	const valid = $derived(validateAnswer(options, text, true));

	/** `own`: the person's own text instead of one of the options. */
	async function send(answer: string, own = false) {
		const value = validateAnswer(options, answer, own || options.length === 0);
		if (!value || busy) return;
		busy = true;
		const ok = await attempt(() => api.answerQuestion(id, value, own && options.length > 0));
		busy = false;
		if (ok) text = '';
		// Also after a conflict (answered elsewhere first): show the real state.
		await onanswered();
	}
</script>

<div class="bg-ui-accent-soft/50 flex min-w-0 flex-col gap-2 rounded-lg border p-2.5 text-sm" data-testid="question" data-question-id={id}>
	<div class="flex items-start gap-2">
		<CircleHelp class="text-ui-accent-ink mt-0.5 size-4 shrink-0" aria-hidden="true" />
		<div class="min-w-0 flex-1">
			{#if context}<p class="text-muted-foreground mb-0.5 text-xs">{context}</p>{/if}
			{#if askedBy}<p class="text-muted-foreground text-xs">{t('cc.question.title', { who: askedBy })}{blocking ? ` · ${t('cc.question.blocking')}` : ''}</p>{/if}
			<p class="font-medium break-words whitespace-pre-wrap" data-testid="question-prompt">{prompt}</p>
		</div>
	</div>
	{#if options.length > 0}
		<OptionButtons {size} items={options.map((o) => ({ key: o, label: o }))} onpick={(o) => send(o)} disabled={busy} label={t('cc.question.pick')} testid="question-option" />
	{/if}
	<form
		class="flex"
		onsubmit={(e) => {
			e.preventDefault();
			send(text, true);
		}}
	>
		<ChatField bind:value={text} enterSends={false} maxlength={10000} busy={busy} canSend={!!valid} onsend={() => send(text, true)} placeholder={options.length > 0 ? t('cc.question.ownAnswer') : t('cc.question.answerPlaceholder')} label={t('cc.question.answerLabel')} sendLabel={t('cc.question.send')} fieldTestid="question-answer" sendTestid="question-send" />
	</form>
	{#if onopen}
		<div class="-mx-2.5 -mb-2.5 flex border-t px-1.5 py-1">
			<Button variant="ghost" size="sm" class="text-ui-accent-ink ml-auto max-sm:w-full max-sm:justify-between" data-testid="card-open" onclick={onopen}>{t('cc.card.open')}<ChevronRight class="size-4" aria-hidden="true" /></Button>
		</div>
	{/if}
</div>
