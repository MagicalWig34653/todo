<script lang="ts">
	import { untrack, type Snippet } from 'svelte';
	import { cn } from '#lib/utils.js';
	import { t } from '#lib/i18n/index.js';
	import { notice } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import X from '@lucide/svelte/icons/x';

	/** Modal dialog: backdrop click and Escape close it, focus moves in, Tab stays inside, focus returns on close. */
	let {
		open = $bindable(false),
		title,
		children,
		class: className,
		testid,
		sheet = false,
		large = false
	}: { open?: boolean; title: string; children: Snippet; class?: string; testid?: string; sheet?: boolean; large?: boolean } = $props();

	let box = $state<HTMLDivElement | null>(null);
	let overlay = $state<HTMLDivElement | null>(null);
	let returnTo: HTMLElement | null = null;

	const focusables = () =>
		Array.from(box?.querySelectorAll<HTMLElement>('input,select,textarea,button,[href],[tabindex]:not([tabindex="-1"])') ?? []).filter(
			(e) => !(e as HTMLInputElement).disabled && e.offsetParent !== null
		);

	$effect(() => {
		if (!open || !box) return;
		returnTo = document.activeElement as HTMLElement | null;
		// Large window (card detail): rendered at the end of <body>, everything else becomes inert so neither Tab nor a
		// screen reader reaches the page behind the blurred backdrop. Moving and inerting happen before the focus moves in.
		const inerted: HTMLElement[] = [];
		if (large && overlay) {
			document.body.appendChild(overlay);
			for (const child of Array.from(document.body.children)) {
				if (child === overlay || !(child instanceof HTMLElement) || child.hasAttribute('inert') || ['SCRIPT', 'STYLE', 'LINK'].includes(child.tagName)) continue;
				child.setAttribute('inert', '');
				inerted.push(child);
			}
		}
		(box.querySelector<HTMLElement>('[data-autofocus]') ?? focusables()[0] ?? box).focus();
		untrack(() => notice.dialogs++);
		const esc = (e: KeyboardEvent) => {
			if (e.key === 'Escape' && !e.defaultPrevented) open = false;
		};
		document.addEventListener('keydown', esc);
		return () => {
			document.removeEventListener('keydown', esc);
			inerted.forEach((c) => c.removeAttribute('inert'));
			untrack(() => notice.dialogs--);
			returnTo?.focus?.();
		};
	});

	function onkeydown(e: KeyboardEvent) {
		if (e.key === 'Tab') {
			const f = focusables();
			if (f.length === 0) return;
			const first = f[0];
			const last = f[f.length - 1];
			if (e.shiftKey && document.activeElement === first) (e.preventDefault(), last.focus());
			else if (!e.shiftKey && document.activeElement === last) (e.preventDefault(), first.focus());
		}
	}
</script>

{#if open}
	<div
		bind:this={overlay}
		class={[
			'fixed inset-0 z-[60] flex justify-center',
			large
				? 'items-stretch bg-black/40 p-0 backdrop-blur-md md:items-center md:p-6 dark:bg-black/65'
				: ['overflow-y-auto bg-black/50 backdrop-blur-[2px]', sheet ? 'items-end p-0 sm:items-start sm:p-4 sm:pt-[12vh]' : 'items-start p-4 pt-[12vh]']
		]}
		data-large={large || undefined}
		role="presentation"
	>
		<button type="button" class="absolute inset-0 cursor-default" tabindex="-1" aria-label={t('common.close')} onclick={() => (open = false)}></button>
		<div
			bind:this={box}
			role="dialog"
			aria-modal="true"
			aria-label={title}
			tabindex="-1"
			data-testid={testid}
			class={cn(
				'bg-popover text-popover-foreground shadow-pop relative w-full max-w-lg rounded-2xl border p-4 sm:p-5',
				large && 'card-window flex max-w-none min-w-0 flex-col overflow-hidden rounded-none border-0 p-0 md:h-[min(88vh,840px)] md:max-w-[1080px] md:rounded-2xl md:border',
				sheet && 'rounded-b-none pb-[max(1rem,env(safe-area-inset-bottom))] sm:rounded-b-2xl', className)
			}
			{onkeydown}
		>
			{#if !large}
			<div class="mb-3 flex items-center justify-between gap-2">
				<h2 class="min-w-0 text-base font-semibold [overflow-wrap:anywhere]">{title}</h2>
				<button type="button" class="text-muted-foreground hover:bg-muted hit-area relative inline-flex size-8 shrink-0 items-center justify-center rounded-lg" aria-label={t('common.close')} onclick={() => (open = false)}>
					<X class="size-4" aria-hidden="true" />
				</button>
			</div>
			{/if}
			{#if notice.text}
				<div
					role={notice.conflict ? 'status' : 'alert'}
					class={['border-warning/30 bg-warning-soft text-foreground flex items-start justify-between gap-2 rounded-lg border px-3 py-2 text-sm', large ? 'mx-3 mt-2 md:mx-5' : 'mb-3']}
					data-testid="notice"
				>
					<span>
						{#if notice.conflict}<strong>{t('conflict.title')}.</strong>{/if}
						{notice.text}
					</span>
					<Button variant="ghost" size="xs" onclick={() => notice.clear()}>{t('common.cancel')}</Button>
				</div>
			{/if}
			{#if large}
				<div class="flex min-h-0 min-w-0 flex-1 flex-col">{@render children()}</div>
			{:else}
				{@render children()}
			{/if}
		</div>
	</div>
{/if}
