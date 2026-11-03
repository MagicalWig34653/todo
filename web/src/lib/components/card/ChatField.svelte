<script lang="ts">
	import type { Snippet } from 'svelte';
	import SendHorizontal from '@lucide/svelte/icons/send-horizontal';

	/**
	 * One rounded message field: growing textarea with the actions (paperclip) and the round send button inside the
	 * container, at the right and aligned with the last line. The send button is always visible; it is muted while the
	 * field is empty. Cmd/Ctrl+Enter sends, plain Enter sends when `enterSends` (Shift+Enter always inserts a line break).
	 * Lives inside a form: the button submits it, the keys call `onsend`.
	 */
	interface Props {
		value: string;
		placeholder: string;
		label: string;
		sendLabel: string;
		onsend: () => void;
		/** Disabled while a request runs. */
		busy?: boolean;
		/** Sending is allowed (not empty, valid); defaults to a non-blank value. */
		canSend?: boolean;
		enterSends?: boolean;
		maxlength?: number;
		fieldTestid?: string;
		sendTestid?: string;
		actions?: Snippet;
	}
	let { value = $bindable(''), placeholder, label, sendLabel, onsend, busy = false, canSend, enterSends = true, maxlength, fieldTestid, sendTestid, actions }: Props = $props();
	const ready = $derived((canSend ?? value.trim().length > 0) && !busy);

	function key(e: KeyboardEvent) {
		if (e.key !== 'Enter' || e.isComposing) return;
		if (e.metaKey || e.ctrlKey || (enterSends && !e.shiftKey)) {
			e.preventDefault();
			if (ready) onsend();
		}
	}
</script>

<div class="bg-background border-input focus-within:border-ring focus-within:ring-ring/40 flex min-w-0 flex-1 items-end gap-1 rounded-3xl border py-1 pr-1 pl-4 transition-colors focus-within:ring-2" data-testid="chat-field">
	<textarea
		bind:value
		rows="1"
		{maxlength}
		class="placeholder:text-muted-foreground field-sizing-content max-h-40 min-h-9 min-w-0 flex-1 resize-none bg-transparent py-2 text-sm shadow-none! outline-none"
		{placeholder}
		aria-label={label}
		disabled={busy}
		data-testid={fieldTestid}
		onkeydown={key}
	></textarea>
	{@render actions?.()}
	<button
		type="submit"
		class="hit-area relative inline-flex size-9 shrink-0 items-center justify-center rounded-full transition-colors {ready ? 'bg-ui-accent text-ui-accent-foreground hover:opacity-90' : 'bg-muted text-muted-foreground'}"
		aria-label={sendLabel}
		title={sendLabel}
		disabled={!ready}
		data-testid={sendTestid}
	>
		<SendHorizontal class="size-4" aria-hidden="true" />
	</button>
</div>
