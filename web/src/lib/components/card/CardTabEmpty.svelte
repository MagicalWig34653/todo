<script lang="ts">
	/** Honest empty state of a card tab: says what will appear here and when, never shows invented content. */
	let { title, text }: { title: string; text: string } = $props();
</script>

<div class="flex flex-col items-center gap-1.5 rounded-xl border border-dashed px-4 py-10 text-center" data-testid="tab-empty">
	<h3 class="font-semibold">{title}</h3>
	<p class="text-muted-foreground max-w-md">{text}</p>
</div>
