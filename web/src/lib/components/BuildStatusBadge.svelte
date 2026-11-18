<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { buildStatusOf, shortCommit } from '#lib/now.js';
	import LoaderCircle from '@lucide/svelte/icons/loader-circle';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import CircleX from '@lucide/svelte/icons/circle-x';

	/** Build status as text plus symbol (never colour alone), with the optional short commit. Renders nothing without status and commit. */
	let { status, commit }: { status?: string | null; commit?: string | null } = $props();
	const info = $derived(buildStatusOf(status));
	const short = $derived(shortCommit(commit));
	const tone = { info: 'text-muted-foreground', ok: 'text-green-700 dark:text-green-400', danger: 'text-red-700 dark:text-red-400 font-semibold' } as const;
</script>

{#if info}
	<span class={['inline-flex items-center gap-1 text-[13px]', tone[info.tone]]} data-testid="build-status" data-status={status}>
		{#if info.tone === 'danger'}<CircleX class="size-3.5" aria-hidden="true" />{:else if info.tone === 'ok'}<CircleCheck class="size-3.5" aria-hidden="true" />{:else}<LoaderCircle class="size-3.5" aria-hidden="true" />{/if}
		{t(info.key)}
	</span>
{/if}
{#if short}<code class="text-muted-foreground font-mono text-[12px]" title={commit} data-testid="build-commit">{short}</code>{/if}
