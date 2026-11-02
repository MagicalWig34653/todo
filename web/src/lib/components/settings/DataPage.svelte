<script lang="ts">
	import { ANONYMIZE_PHRASE, anonymizeMyAccount, downloadMyExport, phraseMatches } from '#lib/accountData.js';
	import { ApiError } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import Dialog from '../app/Dialog.svelte';
	import Panel from '../app/Panel.svelte';

	let exporting = $state(false);
	let exported = $state(false);

	async function exportData() {
		exporting = true;
		exported = false;
		exported = await attempt(downloadMyExport);
		exporting = false;
	}

	// Two steps: information first, then the typed confirmation.
	let open = $state(false);
	let step = $state<1 | 2>(1);
	let phrase = $state('');
	let busy = $state(false);

	function start() {
		notice.clear();
		step = 1;
		phrase = '';
		open = true;
	}

	async function anonymize() {
		if (!phraseMatches(phrase) || busy) return;
		busy = true;
		const ok = await attempt(async () => {
			try {
				await anonymizeMyAccount();
			} catch (e) {
				// The generic text talks about administrators in general; here it is about the person themselves.
				if (e instanceof ApiError && e.reason === 'last_admin_required') throw new ApiError(409, 'last_admin_self');
				throw e;
			}
		});
		busy = false;
		if (ok) {
			open = false;
			// The session is gone: the app returns to the sign-in page.
			auth.user = null;
		}
	}
</script>

<div class="flex flex-col gap-4">
	<Panel title={t('settings.data.export.title')} description={t('settings.data.export.text')}>
		<div class="flex flex-wrap items-center gap-3">
			<Button onclick={exportData} disabled={exporting} data-testid="data-export">
				{exporting ? t('settings.data.export.busy') : t('settings.data.export.button')}
			</Button>
			{#if exported}<span class="text-sm" role="status" data-testid="data-export-done">{t('settings.data.export.done')}</span>{/if}
		</div>
	</Panel>
	<Panel title={t('settings.data.lock.title')} description={t('settings.data.lock.text')}>
		<div><Button variant="destructive" onclick={start} data-testid="data-lock-start">{t('settings.data.lock.button')}</Button></div>
	</Panel>
</div>

<Dialog bind:open title={step === 1 ? t('settings.data.lock.step1.title') : t('settings.data.lock.step2.title')} testid="data-lock-dialog">
	<div class="flex flex-col gap-3 text-sm">
		{#if step === 1}
			<p>{t('settings.data.lock.step1.what')}</p>
			<p class="text-muted-foreground">{t('settings.data.lock.step1.kept')}</p>
			<div class="flex flex-wrap justify-end gap-2">
				<Button variant="ghost" onclick={() => (open = false)}>{t('settings.data.lock.cancel')}</Button>
				<Button variant="destructive" onclick={() => (step = 2)} data-testid="data-lock-next">{t('settings.data.lock.step1.next')}</Button>
			</div>
		{:else}
			<form
				class="flex flex-col gap-3"
				onsubmit={(e) => {
					e.preventDefault();
					anonymize();
				}}
			>
				<label class="flex flex-col gap-1.5">
					<span>{t('settings.data.lock.step2.text', { phrase: ANONYMIZE_PHRASE })}</span>
					<Input bind:value={phrase} autocomplete="off" aria-label={t('settings.data.lock.step2.label')} data-autofocus data-testid="data-lock-phrase" />
				</label>
				<div class="flex flex-wrap justify-end gap-2">
					<Button type="button" variant="ghost" onclick={() => (step = 1)}>{t('settings.data.lock.back')}</Button>
					<Button type="submit" variant="destructive" disabled={!phraseMatches(phrase) || busy} data-testid="data-lock-confirm">
						{t('settings.data.lock.step2.submit')}
					</Button>
				</div>
			</form>
		{/if}
	</div>
</Dialog>
