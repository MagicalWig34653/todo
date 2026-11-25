<script lang="ts">
	import { untrack } from 'svelte';
	import { onMount } from 'svelte';
	import { api, type Activity } from '#lib/api.js';
	import { de } from '#lib/i18n/de.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt, attemptLoad } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { personName } from '#lib/people.js';
	import { newerThan, startLiveRefresh } from '#lib/liveRefresh.js';
	import { Button } from '#lib/components/ui/button/index.js';

	import { choiceActivity, type VariantReview } from '#lib/reviewVariants.js';

	/** `review`: the card's current review; its chosen variant is named on the entry of the accepting decision. */
	let { taskID, refreshKey = 0, review = null }: { taskID: string; refreshKey?: number; review?: VariantReview | null } = $props();

	let items = $state<Activity[]>([]);
	let next = $state<string | null>(null);
	const choice = $derived(choiceActivity(items, review));
	/** The first page arrived: until then no "no events" text (it would flash on every open). */
	let loaded = $state(false);

	async function load(more = false) {
		const page = await api.activity(taskID, more ? next : null);
		items = more ? [...items, ...page.items] : page.items;
		next = page.nextCursor ?? null;
		loaded = true;
	}
	/** Silent refetch of the newest page; new entries are put in front, loaded older pages stay in place. */
	async function refresh() {
		const page = await api.activity(taskID, null);
		const { fresh, gap } = newerThan(items, page.items);
		if (gap) {
			items = page.items;
			next = page.nextCursor ?? null;
		} else if (fresh.length > 0) items = [...fresh, ...items];
	}
	onMount(() => startLiveRefresh(refresh));
	/** Primitive on purpose: `taskID={task.id}` reads `task`, so a reloaded task list would rerun the effect (a needless refetch). */
	const taskKey = $derived(taskID);
	$effect(() => {
		void taskKey;
		loaded = false;
		void refreshKey;
		untrack(() => attemptLoad(() => load()));
	});

	function label(kind: string): string {
		const key = `activity.kind.${kind}`;
		return key in de ? t(key as MessageKey) : kind;
	}
</script>

{#if loaded && items.length === 0}
	<p class="text-muted-foreground text-xs">{t('activity.empty')}</p>
{/if}
<ol class="flex flex-col gap-1 text-xs">
	{#each items as a (a.id)}
		<li class="flex flex-wrap gap-x-2" data-testid="activity">
			<span class="text-muted-foreground">{a.createdAt ? formatWhen(a.createdAt) : ''}</span>
			<span>{label(a.kind)}{#if choice?.id === a.id}: <strong class="font-semibold" data-testid="activity-choice">{choice.text}</strong>{/if}</span>
			<span class="text-muted-foreground" data-testid="activity-actor">
				({a.actorType === 'Person' ? personName(a.actorName, t('activity.actor.Person')) : t(`activity.actor.${a.actorType}` as MessageKey)})
			</span>
		</li>
	{/each}
</ol>
{#if next}
	<Button size="sm" variant="ghost" onclick={() => attempt(() => load(true))}>{t('activity.more')}</Button>
{/if}
