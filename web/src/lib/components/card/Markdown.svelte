<script lang="ts">
	import { parseMarkdown, type MdInline } from '#lib/miniMarkdown.js';

	/** Renders the safe Markdown subset (paragraphs, bullet lists, headings, code) as text nodes only. */
	let { text, class: className = '' }: { text: string; class?: string } = $props();
	const blocks = $derived(parseMarkdown(text));
</script>

{#snippet inline(parts: MdInline[])}
	{#each parts as p}
		{#if p.kind === 'strong'}<strong>{p.text}</strong>{:else if p.kind === 'code'}<code class="bg-muted rounded px-1 py-0.5 text-[0.85em]">{p.text}</code>{:else}{p.text}{/if}
	{/each}
{/snippet}

<div class={['flex min-w-0 flex-col gap-2 text-sm [overflow-wrap:anywhere]', className]} data-testid="markdown">
	{#each blocks as b}
		{#if b.kind === 'heading'}
			<p class="font-semibold">{@render inline(b.inline)}</p>
		{:else if b.kind === 'paragraph'}
			<p>{@render inline(b.inline)}</p>
		{:else if b.kind === 'list'}
			<ul class="flex list-disc flex-col gap-1 pl-5">
				{#each b.items as item}<li>{@render inline(item)}</li>{/each}
			</ul>
		{:else}
			<pre class="bg-muted overflow-x-auto rounded-lg p-2 text-xs whitespace-pre-wrap">{b.text}</pre>
		{/if}
	{/each}
</div>
