<script lang="ts">
	import type { Snippet } from 'svelte';
	import { cn } from '#lib/utils.js';
	import { t } from '#lib/i18n/index.js';
	import X from '@lucide/svelte/icons/x';

	/** Modal dialog: backdrop click and Escape close it, focus moves in, Tab stays inside, focus returns on close. */
	let {
		open = $bindable(false),
		title,
		children,
		class: className,
		testid,
		sheet = false
	}: { open?: boolean; title: string; children: Snippet; class?: string; testid?: string; sheet?: boolean } = $props();

	let box = $state<HTMLDivElement | null>(null);
	let returnTo: HTMLElement | null = null;

	const focusables = () =>
		Array.from(box?.querySelectorAll<HTMLElement>('input,select,textarea,button,[href],[tabindex]:not([tabindex="-1"])') ?? []).filter(
			(e) => !(e as HTMLInputElement).disabled && e.offsetParent !== null
		);

	$effect(() => {
		if (!open || !box) return;
		returnTo = document.activeElement as HTMLElement | null;
		(box.querySelector<HTMLElement>('[data-autofocus]') ?? focusables()[0] ?? box).focus();
		const esc = (e: KeyboardEvent) => {
			if (e.key === 'Escape' && !e.defaultPrevented) open = false;
		};
		document.addEventListener('keydown', esc);
		return () => {
			document.removeEventListener('keydown', esc);
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
		class={[
			'fixed inset-0 z-[60] flex justify-center overflow-y-auto bg-black/50 backdrop-blur-[2px]',
			sheet ? 'items-end p-0 sm:items-start sm:p-4 sm:pt-[12vh]' : 'items-start p-4 pt-[12vh]'
		]}
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
			class={cn('bg-popover text-popover-foreground shadow-pop relative w-full max-w-lg rounded-2xl border p-4 sm:p-5', sheet && 'rounded-b-none pb-[max(1rem,env(safe-area-inset-bottom))] sm:rounded-b-2xl', className)}
			{onkeydown}
		>
			<div class="mb-3 flex items-center justify-between gap-2">
				<h2 class="text-base font-semibold">{title}</h2>
				<button type="button" class="text-muted-foreground hover:bg-muted inline-flex size-8 items-center justify-center rounded-lg" aria-label={t('common.close')} onclick={() => (open = false)}>
					<X class="size-4" aria-hidden="true" />
				</button>
			</div>
			{@render children()}
		</div>
	</div>
{/if}
