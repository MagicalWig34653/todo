<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { startLiveRefresh } from '#lib/liveRefresh.js';
	import { ageMinutes, summarize, toneOf, type Ampel, type SystemStatusResponse } from '#lib/systemStatus.js';
	import { Badge } from '#lib/components/ui/badge/index.js';

	/** Situation lights of the watcher (Claude quota, Codex, disk). Live via the live token, plus a 60 s poll as fallback. */
	let data = $state<SystemStatusResponse | null>(null);
	let fetchedAt = $state(Date.now());
	let tick = $state(Date.now());

	async function load() {
		try {
			const res = await api.systemStatus();
			data = res;
			fetchedAt = Date.now();
			tick = fetchedAt;
		} catch {
			// Background widget: a failed load keeps the last answer (it turns grey by age); a lost session is handled by the page.
		}
	}

	onMount(() => {
		void load();
		const stopLive = startLiveRefresh(load);
		const poll = setInterval(load, 60_000);
		const clock = setInterval(() => (tick = Date.now()), 15_000);
		return () => {
			stopLive();
			clearInterval(poll);
			clearInterval(clock);
		};
	});

	const rows = $derived(
		(data?.items ?? []).map((item) => ({ item, s: summarize(item, ageMinutes(item, data!.now, fetchedAt, tick)) }))
	);
	const ampelText = (a: Ampel | null) => (a ? t(`lage.ampel.${a}` as 'lage.ampel.rot') : '');
	const ago = (min: number) => (min < 1 ? t('lage.agoNow') : t('lage.ago', { min }));
	const num = (n: number) => String(Math.round(n * 10) / 10).replace('.', ',');
</script>

{#if data}
	<div class="flex flex-col gap-1" role="status" aria-label={t('lage.label')} data-testid="system-status">
		{#each rows as { item, s } (item.source)}
			<div class={['flex flex-wrap items-center gap-x-3 gap-y-1 text-xs', s.stale && 'opacity-60']} data-testid="system-status-row" data-stale={s.stale}>
				{#if s.claude}
					<span class="inline-flex items-center gap-1.5" data-testid="lage-claude">
						<span class="text-muted-foreground">{t('lage.claude')}</span>
						<Badge variant={s.stale ? 'default' : toneOf(s.claude.ampel)}>{ampelText(s.claude.ampel) || '–'}</Badge>
						<span class="text-muted-foreground">{s.claude.accounts.length ? t('lage.accounts', { list: s.claude.accounts.join(', ') }) : t('lage.noAccounts')}</span>
					</span>
				{/if}
				{#if s.codex}
					<span class="inline-flex items-center gap-1.5" data-testid="lage-codex">
						<span class="text-muted-foreground">{t('lage.codex')}</span>
						<Badge variant={s.stale ? 'default' : s.codex.tone}>
							{s.codex.allowed !== null ? t('lage.codexUsed', { used: num(s.codex.used), allowed: num(s.codex.allowed) }) : t('lage.codexUsedOnly', { used: num(s.codex.used) })}
						</Badge>
					</span>
				{/if}
				{#if s.disk}
					<span class="inline-flex items-center gap-1.5" data-testid="lage-disk">
						<span class="text-muted-foreground">{t('lage.disk')}</span>
						<Badge variant={s.stale ? 'default' : toneOf(s.disk.ampel)}>{s.disk.freeGb !== null ? t('lage.diskFree', { gb: num(s.disk.freeGb) }) : ampelText(s.disk.ampel)}</Badge>
					</span>
				{/if}
				<span class="text-muted-foreground" data-testid="lage-age">{ago(s.ageMin)}{#if s.stale}<Badge class="ml-1.5" data-testid="lage-stale">{t('lage.stale')}</Badge>{/if}</span>
			</div>
		{:else}
			<p class="text-muted-foreground text-xs" data-testid="system-status-empty">{t('lage.none')}</p>
		{/each}
	</div>
{/if}
