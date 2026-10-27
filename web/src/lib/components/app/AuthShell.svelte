<script lang="ts">
	import type { Snippet } from 'svelte';
	import CircleCheckBig from '@lucide/svelte/icons/circle-check-big';
	import { t } from '#lib/i18n/index.js';
	import { cn } from '#lib/utils.js';

	/** Centered card for login, setup, recovery and consent. */
	let { title, testid, wide = false, children }: { title: string; testid?: string; wide?: boolean; children?: Snippet } = $props();
</script>

<main class="from-ui-accent-soft/60 to-background flex min-h-dvh flex-col items-center justify-center bg-gradient-to-b px-4 py-10">
	<div class={cn('flex w-full flex-col gap-6', wide ? 'max-w-xl' : 'max-w-sm')}>
		<div class="flex items-center justify-center gap-2.5">
			<span class="bg-ui-accent text-ui-accent-foreground inline-flex size-9 items-center justify-center rounded-xl">
				<CircleCheckBig class="size-5" aria-hidden="true" />
			</span>
			<span class="text-xl font-semibold tracking-tight">{t('app.name')}</span>
		</div>
		<div class="bg-card flex flex-col gap-5 rounded-2xl border p-6 shadow-pop">
			<h1 class="text-2xl font-semibold tracking-tight" data-testid={testid}>{title}</h1>
			{@render children?.()}
		</div>
	</div>
</main>
