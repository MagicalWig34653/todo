<script lang="ts">
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { attempt } from '#lib/notice.svelte.js';
	import Dialog from '../app/Dialog.svelte';
	import CardDetailBody from './CardDetailBody.svelte';
	import CardHeader from './CardHeader.svelte';

	/** The one large, blurred card detail window of the app (rendered by the Workspace). */
	let { onopentask, onopenproject }: { onopentask: (projectID: string, taskID: string) => void; onopenproject: (projectID: string) => void } = $props();

	let title = $state('');
	const ref = $derived(cardDetail.ref);
	$effect(() => {
		void ref?.id;
		title = '';
	});
	/** Navigating away from the window (link to the task or project) closes it without a history step back. */
	const leaveTo = (go: () => void) => {
		cardDetail.leave();
		go();
	};
</script>

<Dialog
	bind:open={() => cardDetail.visible, (v) => { if (!v) cardDetail.close(); }}
	large
	title={cardDetail.invalid ? t('card.invalid.title') : title || t('card.loadingTitle')}
	testid="card-dialog"
>
	{#if ref}
		<CardDetailBody
			card={ref}
			bind:title
			onopentask={(p, id) => leaveTo(() => onopentask(p, id))}
			onopenproject={(p) => leaveTo(() => onopenproject(p))}
			onchanged={async () => {
				await attempt(() => workspace.refreshLive());
			}}
		/>
	{:else}
		<CardHeader />
		<div class="flex flex-col items-start gap-3 p-5" data-testid="card-invalid">
			<p class="font-medium">{t('card.invalid.title')}</p>
			<p class="text-muted-foreground text-sm">{t('card.invalid.hint')}</p>
		</div>
	{/if}
</Dialog>
