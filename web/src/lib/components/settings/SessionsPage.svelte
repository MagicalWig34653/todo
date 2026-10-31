<script lang="ts">
	import { api, type SessionInfo } from '#lib/api.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '../app/Panel.svelte';

	let sessions = $state<SessionInfo[]>([]);
	let info = $state<string | null>(null);

	async function load() {
		sessions = await api.listSessions();
	}
	$effect(() => {
		attempt(load);
	});

	async function endSession(s: SessionInfo) {
		if (s.current) {
			await auth.logout();
			return;
		}
		await attempt(async () => { await api.revokeSession(s.id); await load(); }, load);
	}
	async function endOthers() {
		info = null;
		if (await attempt(async () => { await api.revokeOtherSessions(); await load(); }, load)) info = t('account.sessions.revokeOthersDone');
	}
</script>

{#if info}<p class="bg-success-soft text-success rounded-lg px-3 py-2 text-sm" role="status" data-testid="account-info">{info}</p>{/if}

<Panel title={t('account.sessions')}>
	<ul class="flex flex-col gap-2">
		{#each sessions as s (s.id)}
			<li class="flex flex-wrap items-center gap-2 rounded-lg border p-2.5 text-sm" data-testid="session-item">
				<span class="flex-1">
					{#if s.current}<strong>{t('account.sessions.current')}</strong>{/if}
					{#if s.createdAt}<span class="text-muted-foreground text-xs">{t('account.sessions.created', { when: formatWhen(s.createdAt) })}</span>{/if}
					<span class="text-muted-foreground text-xs">{t('account.sessions.expires', { when: formatWhen(s.expiresAt) })}</span>
				</span>
				<Button size="xs" variant="outline" onclick={() => endSession(s)}>{t('account.sessions.revoke')}</Button>
			</li>
		{/each}
	</ul>
	{#if sessions.length > 1}
		<div><Button size="sm" variant="outline" onclick={endOthers}>{t('account.sessions.revokeOthers')}</Button></div>
	{/if}
</Panel>
