<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { Button } from '#lib/components/ui/button/index.js';

	/** Read-only command or value with a copy button (clipboard API, with a text-selection fallback). */
	let { value, label, testid }: { value: string; label: string; testid?: string } = $props();
	let copied = $state(false);
	let timer: ReturnType<typeof setTimeout> | undefined;

	async function copy() {
		try {
			await navigator.clipboard.writeText(value);
		} catch {
			const range = document.createRange();
			const node = document.querySelector(`[data-copy-value="${CSS.escape(testid ?? label)}"]`);
			if (node) {
				range.selectNodeContents(node);
				const sel = getSelection();
				sel?.removeAllRanges();
				sel?.addRange(range);
			}
		}
		copied = true;
		clearTimeout(timer);
		timer = setTimeout(() => (copied = false), 1800);
	}
</script>

<div class="flex flex-col gap-1">
	<span class="text-xs font-medium">{label}</span>
	<div class="flex items-stretch gap-2">
		<code class="bg-muted min-w-0 flex-1 rounded-lg px-3 py-2 font-mono text-xs break-all select-all" data-testid={testid} data-copy-value={testid ?? label}>{value}</code>
		<Button type="button" size="sm" variant="outline" class="shrink-0 self-start" aria-label="{t('claude.copy')}: {label}" onclick={copy}>
			{copied ? t('claude.copied') : t('claude.copy')}
		</Button>
	</div>
</div>
