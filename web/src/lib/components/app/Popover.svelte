<script lang="ts">
	import type { Snippet } from 'svelte';
	import { cn } from '#lib/utils.js';

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
	let pos = $state({ top: 0, left: 0 });
	const close = () => {
		open = false;
		button?.focus();
	};

	$effect(() => {
		if (!open || !button || !panel) return;
		const r = button.getBoundingClientRect();
		const w = panel.offsetWidth;
		const h = panel.offsetHeight;
		let left = align === 'end' ? r.right - w : r.left;
		left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
		let top = r.bottom + 4;
		if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 4);
		pos = { top, left };
		const away = (e: PointerEvent) => {
			const n = e.target as Node;
			if (!panel?.contains(n) && !button?.contains(n)) open = false;
		};
		const key = (e: KeyboardEvent) => {
			if (e.key === 'Escape') {
				e.stopPropagation();
				close();
			}
		};
		const dismiss = () => (open = false);
		document.addEventListener('pointerdown', away, true);
		document.addEventListener('keydown', key, true);
		window.addEventListener('resize', dismiss);
		return () => {
			document.removeEventListener('pointerdown', away, true);
			document.removeEventListener('keydown', key, true);
			window.removeEventListener('resize', dismiss);
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
		role="dialog"
		aria-label={label}
		class={cn('bg-popover text-popover-foreground shadow-pop fixed z-[70] max-h-[80dvh] min-w-48 max-w-[calc(100vw-16px)] overflow-y-auto rounded-xl border p-1.5', panelClass)}
		style:top="{pos.top}px"
		style:left="{pos.left}px"
	>
		{@render children(close)}
	</div>
{/if}
