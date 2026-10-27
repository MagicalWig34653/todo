<script lang="ts">
	import { api, type DirectoryUser } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { MIN_SEARCH_LENGTH } from '#lib/people.js';
	import { Input } from '#lib/components/ui/input/index.js';

	/** `value` is the chosen account ID: either picked from the restricted directory or typed in. */
	let { value = $bindable(''), idLabel }: { value: string; idLabel: string } = $props();

	let term = $state('');
	let results = $state<DirectoryUser[]>([]);
	let searched = $state(false);
	let pickedName = $state<string | null>(null);
	let timer: ReturnType<typeof setTimeout> | undefined;
	let seq = 0;

	function onsearch() {
		clearTimeout(timer);
		const q = term.trim();
		if (q.length < MIN_SEARCH_LENGTH) {
			results = [];
			searched = false;
			return;
		}
		const mine = ++seq;
		timer = setTimeout(() => {
			attempt(async () => {
				const found = await api.searchUsers(q);
				// A newer query supersedes this answer.
				if (mine !== seq) return;
				results = found;
				searched = true;
			});
		}, 250);
	}
	function pick(u: DirectoryUser) {
		value = u.id;
		pickedName = u.displayName;
		results = [];
		term = '';
		searched = false;
	}
	function clear() {
		value = '';
		pickedName = null;
	}
</script>

<div class="flex min-w-0 flex-1 flex-col gap-1" data-testid="person-picker">
	{#if pickedName}
		<div class="flex items-center gap-2 text-sm">
			<span class="bg-secondary rounded-full px-2 py-0.5" data-testid="picked-person">{pickedName}</span>
			<button type="button" class="text-muted-foreground text-xs underline" onclick={clear}>{t('people.change')}</button>
		</div>
	{:else}
		<Input value={term} oninput={(e) => { term = e.currentTarget.value; onsearch(); }} placeholder={t('people.search')} aria-label={t('people.search')} autocomplete="off" />
		{#if results.length > 0}
			<ul class="flex flex-col rounded-md border" data-testid="person-results">
				{#each results as u (u.id)}
					<li>
						<button type="button" class="hover:bg-muted w-full px-2 py-1.5 text-left text-sm" onclick={() => pick(u)}>{u.displayName}</button>
					</li>
				{/each}
			</ul>
		{:else if searched}
			<p class="text-muted-foreground text-xs">{t('people.noResults')}</p>
		{/if}
		<Input bind:value class="font-mono text-xs" placeholder={idLabel} aria-label={idLabel} />
		<p class="text-muted-foreground text-xs">{t('people.hint')}</p>
	{/if}
</div>
