<script lang="ts">
	import type { Snippet } from 'svelte';
	import { cn } from '#lib/utils.js';
	import { placePanel } from '#lib/floating.js';

	/**
	 * Button plus a floating panel. The panel is `position: fixed` so it is not clipped by scrolling containers
	 * (board columns, sidebar). Closes on outside click, Escape and when focus leaves via Tab.
	 */
	let {
		label,
		trigger,
		children,
		align = 'start',
		open = $bindable(false),
		class: className,
		panelClass,
		testid
	}: {
		label: string;
		trigger: Snippet;
		children: Snippet<[() => void]>;
		align?: 'start' | 'end';
		open?: boolean;
		class?: string;
		panelClass?: string;
		testid?: string;
	} = $props();

	let button = $state<HTMLButtonElement | null>(null);
	let panel = $state<HTMLDivElement | null>(null);
	let pos = $state({ top: 0, left: 0, maxHeight: 0, maxWidth: 0, placed: false });
	const close = () => {
		open = false;
		button?.focus();
	};

	/**
	 * The panel lives under <body>: ancestors with backdrop-filter/transform (sticky header, drawer) would otherwise
	 * become the containing block of `position: fixed` and shift the panel out of the viewport.
	 */
	function portal(node: HTMLElement) {
		document.body.appendChild(node);
		return { destroy: () => node.remove() };
	}

	const focusables = () =>
		Array.from(panel?.querySelectorAll<HTMLElement>('input,select,textarea,button,[href],[tabindex]:not([tabindex="-1"])') ?? []).filter(
			(e) => !(e as HTMLInputElement).disabled && e.offsetParent !== null
		);

	function place() {
		if (!button || !panel) return;
		const r = button.getBoundingClientRect();
		const vv = window.visualViewport;
		const viewport = { width: document.documentElement.clientWidth, height: Math.min(window.innerHeight, vv?.height ?? Infinity) };
		const border = panel.offsetHeight - panel.clientHeight;
		const p = placePanel(r, { width: panel.offsetWidth, height: panel.scrollHeight + border }, viewport, { align });
		pos = { top: p.top, left: p.left, maxHeight: p.maxHeight, maxWidth: p.maxWidth, placed: true };
	}

	$effect(() => {
		if (!open || !button || !panel) return;
		place();
		const returnFocus = document.activeElement;
		(focusables()[0] ?? panel).focus({ preventScroll: true });
		const away = (e: PointerEvent) => {
			const n = e.target as Node;
			if (!panel?.contains(n) && !button?.contains(n)) open = false;
		};
		const key = (e: KeyboardEvent) => {
			if (e.key === 'Escape') {
				e.stopPropagation();
				close();
			} else if (e.key === 'Tab' && panel?.contains(document.activeElement)) {
				const f = focusables();
				if (f.length === 0) return;
				const first = f[0];
				const last = f[f.length - 1];
				if (e.shiftKey && document.activeElement === first) (e.preventDefault(), last.focus());
				else if (!e.shiftKey && document.activeElement === last) (e.preventDefault(), first.focus());
			}
		};
		const ro = new ResizeObserver(place);
		ro.observe(panel);
		document.addEventListener('pointerdown', away, true);
		document.addEventListener('keydown', key, true);
		window.addEventListener('resize', place);
		window.addEventListener('scroll', place, true);
		window.visualViewport?.addEventListener('resize', place);
		return () => {
			ro.disconnect();
			document.removeEventListener('pointerdown', away, true);
			document.removeEventListener('keydown', key, true);
			window.removeEventListener('resize', place);
			window.removeEventListener('scroll', place, true);
			window.visualViewport?.removeEventListener('resize', place);
			// Closing by outside click keeps the new focus target; otherwise hand focus back to the trigger.
			if (returnFocus instanceof HTMLElement && document.activeElement === document.body) returnFocus.focus();
		};
	});
</script>

<button
	bind:this={button}
	type="button"
	class={className}
	aria-label={label}
	aria-haspopup="dialog"
	aria-expanded={open}
	data-testid={testid}
	onclick={() => (open = !open)}
>
	{@render trigger()}
</button>
{#if open}
	<div
		bind:this={panel}
		use:portal
		role="dialog"
		tabindex="-1"
		aria-label={label}
		class={cn('bg-popover text-popover-foreground shadow-pop fixed z-[70] w-max min-w-[min(12rem,calc(100vw-16px))] overflow-y-auto overscroll-contain rounded-xl border p-1.5', panelClass)}
		style:top="{pos.top}px"
		style:left="{pos.left}px"
		style:max-height={pos.placed ? `${pos.maxHeight}px` : null}
		style:max-width={pos.placed ? `${pos.maxWidth}px` : null}
		style:visibility={pos.placed ? 'visible' : 'hidden'}
	>
		{@render children(close)}
	</div>
{/if}
