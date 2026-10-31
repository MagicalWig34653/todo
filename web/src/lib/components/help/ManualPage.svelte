<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { instance, type ManualDoc } from '#lib/instance.js';
	import { parseMarkdown, type MdInline } from '#lib/miniMarkdown.js';
	import { Select } from '#lib/components/ui/select/index.js';

	let doc = $state<ManualDoc | null>(null);
	let failed = $state(false);
	let section = $state('');

	$effect(() => {
		const s = section;
		failed = false;
		instance.manual(s || undefined).then(
			(d) => (doc = d),
			() => (failed = true)
		);
	});
	const blocks = $derived(doc ? parseMarkdown(doc.content) : []);
</script>

{#snippet inline(parts: MdInline[])}
	{#each parts as p, i (i)}
		{#if p.kind === 'code'}<code class="bg-muted rounded px-1 text-[0.85em]">{p.text}</code>
		{:else if p.kind === 'strong'}<strong>{p.text}</strong>
		{:else}{p.text}{/if}
	{/each}
{/snippet}

<div class="flex flex-col gap-4" data-testid="agent-manual">
	<p class="text-muted-foreground text-sm">{t('manual.intro')}</p>
	{#if failed}
		<p class="bg-muted/60 rounded-lg px-3 py-2 text-sm" role="alert">{t('manual.failed')}</p>
	{:else if !doc}
		<p class="text-muted-foreground text-sm">{t('manual.loading')}</p>
	{:else}
		<div class="flex flex-wrap items-center gap-3 text-sm">
			<span class="text-muted-foreground" data-testid="manual-version">{t('manual.version', { version: String(doc.version) })}</span>
			<label class="flex items-center gap-2">{t('manual.section')}
				<Select bind:value={section} class="w-auto">
					<option value="">{t('manual.all')}</option>
					{#each doc.sections as s (s.id)}<option value={s.id}>{s.title}</option>{/each}
				</Select>
			</label>
		</div>
		<article class="bg-card flex flex-col gap-3 rounded-xl border p-4 text-sm shadow-card sm:p-5" data-testid="manual-content">
			{#each blocks as b, i (i)}
				{#if b.kind === 'heading'}
					<h3 class={b.level === 1 ? 'text-lg font-semibold' : 'text-base font-semibold'}>{@render inline(b.inline)}</h3>
				{:else if b.kind === 'paragraph'}
					<p>{@render inline(b.inline)}</p>
				{:else if b.kind === 'list'}
					<ul class="list-disc pl-5">{#each b.items as it, j (j)}<li>{@render inline(it)}</li>{/each}</ul>
				{:else}
					<pre class="bg-muted overflow-x-auto rounded-lg p-3 text-xs"><code>{b.text}</code></pre>
				{/if}
			{/each}
		</article>
	{/if}
</div>
