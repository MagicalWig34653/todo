<script lang="ts">
	import { api, type RecoveryToken } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	let accountID = $state('');
	// The code is held in memory only and cleared on dismiss; it is never persisted.
	let issued = $state<RecoveryToken | null>(null);

	async function issue(e: Event) {
		e.preventDefault();
		const id = accountID.trim();
		if (!id) return;
		issued = null;
		await attempt(async () => {
			issued = await api.issueRecovery(id);
			accountID = '';
		});
	}
</script>

<div class="bg-card flex flex-col gap-3 rounded-xl border p-4 shadow-card sm:p-5" data-testid="recovery-issue">
	<h3 class="text-base font-semibold">{t('account.recovery')}</h3>
	<p class="text-muted-foreground text-xs">{t('account.recovery.hint')}</p>
	<form class="flex gap-2" onsubmit={issue}>
		<Input bind:value={accountID} placeholder={t('account.recovery.accountID')} aria-label={t('account.recovery.accountID')} />
		<Button type="submit" size="lg">{t('account.recovery.issue')}</Button>
	</form>
	{#if issued}
		<div class="flex flex-col gap-1 rounded-lg border p-2.5 text-sm" role="status">
			<span class="text-xs">{t('account.recovery.codeLabel')}</span>
			<code class="bg-muted w-fit rounded px-2 py-1 text-xs break-all" data-testid="recovery-code">{issued.token}</code>
			<span class="text-muted-foreground text-xs">{t('account.recovery.expires', { when: formatWhen(issued.expiresAt) })}</span>
			<div><Button size="sm" variant="ghost" onclick={() => (issued = null)}>{t('account.recovery.dismiss')}</Button></div>
		</div>
	{/if}
</div>
