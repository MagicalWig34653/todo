<script lang="ts">
	import { api, type Activity } from '#lib/api.js';
	import { de } from '#lib/i18n/de.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';

	let { taskID, refreshKey = 0 }: { taskID: string; refreshKey?: number } = $props();

	let items = $state<Activity[]>([]);
	let next = $state<string | null>(null);

	async function load(more = false) {
		const page = await api.activity(taskID, more ? next : null);
		items = more ? [...items, ...page.items] : page.items;
		next = page.nextCursor ?? null;
	}
	$effect(() => {
		void taskID;
		void refreshKey;
		attempt(() => load());
	});

	function label(kind: string): string {
		const key = `activity.kind.${kind}`;
		return key in de ? t(key as MessageKey) : kind;
	}
</script>

{#if items.length === 0}
	<p class="text-muted-foreground text-xs">{t('activity.empty')}</p>
{/if}
<ol class="flex flex-col gap-1 text-xs">
	{#each items as a (a.id)}
		<li class="flex flex-wrap gap-x-2" data-testid="activity">
			<span class="text-muted-foreground">{a.createdAt ? formatWhen(a.createdAt) : ''}</span>
			<span>{label(a.kind)}</span>
			<span class="text-muted-foreground">({t(`activity.actor.${a.actorType}` as MessageKey)})</span>
		</li>
	{/each}
</ol>
{#if next}
	<Button size="sm" variant="ghost" onclick={() => attempt(() => load(true))}>{t('activity.more')}</Button>
{/if}
