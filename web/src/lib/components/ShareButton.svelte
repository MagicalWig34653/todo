<script lang="ts">
	import { accessRows, can, participants, roleOf, type AccessRow } from '#lib/access.js';
	import { api, type Project } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { ui } from '#lib/ui.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Avatar from './app/Avatar.svelte';
	import UserPlus from '@lucide/svelte/icons/user-plus';

	/** "Teilen" button of the project header: avatar stack of the people involved plus their number; opens the share dialog. */
	let { project, onshare }: { project: Project; onshare: (p: Project) => void } = $props();

	let rows = $state<AccessRow[]>([]);
	/** Only the newest request may publish its result (an older, slower response must not overwrite newer grants). */
	let loadSeq = 0;
	const projectKey = $derived(project.id);
	const manage = $derived(can(roleOf(project), 'share'));
	$effect(() => {
		void projectKey;
		void ui.accessTick;
		const id = projectKey;
		const seq = ++loadSeq;
		if (!manage) {
			rows = [];
			return;
		}
		// Grants are only readable with the manage role; everyone else sees the owner and themselves at most.
		api.listGrants(id).then(
			(g) => {
				if (seq === loadSeq && id === project.id) rows = accessRows(g, [], (x) => x.principalID.slice(0, 8));
			},
			() => {
				if (seq === loadSeq) rows = [];
			}
		);
	});

	const people = $derived(participants(project.ownerID ? { id: project.ownerID, name: project.ownerName?.trim() || '?' } : undefined, rows));
	const shown = $derived(people.slice(0, 3));
	const count = $derived(Math.max(people.length, 1));
</script>

<Button
	variant="outline"
	size="sm"
	class="gap-2"
	data-testid="share-open"
	title={t('share.buttonTitle')}
	aria-label={`${t('share.button')}, ${t('share.count', { count })}`}
	onclick={() => onshare(project)}
>
	{#if shown.length > 0}
		<span class="flex -space-x-2" data-testid="share-avatars">
			{#each shown as p (p.id)}<Avatar name={p.name} team={p.team} size="sm" />{/each}
		</span>
	{:else}
		<UserPlus aria-hidden="true" />
	{/if}
	<span>{t('share.button')}</span>
	<span class="bg-muted text-muted-foreground rounded-full px-1.5 text-xs font-semibold" data-tabular data-testid="share-count">{count}</span>
</Button>
