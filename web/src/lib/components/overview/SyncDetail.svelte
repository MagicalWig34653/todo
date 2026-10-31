<script lang="ts">
	import { api, type ProjectSync, type Role } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { canEditSync, parseStaleAfter } from '#lib/syncState.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import SyncChip from './SyncChip.svelte';

	/** Last sync summary, repository reference, author and the stale threshold of one project. */
	let { projectID, onchanged }: { projectID: string; onchanged?: () => unknown } = $props();

	let sync = $state<ProjectSync | null>(null);
	let role = $state<Role | null>(null);
	let threshold = $state('');
	let invalid = $state(false);
	let saved = $state(false);

	async function load() {
		const [s, v] = await Promise.all([api.getProjectSync(projectID), api.visibility(projectID).catch(() => null)]);
		sync = s;
		role = v?.role ?? null;
		threshold = String(s.staleAfterDays);
	}
	$effect(() => {
		void projectID;
		sync = null;
		saved = false;
		attempt(load);
	});

	const editable = $derived(canEditSync(role));

	async function save(e: Event) {
		e.preventDefault();
		saved = false;
		const days = parseStaleAfter(threshold);
		invalid = days === null;
		if (days === null) return;
		if (
			await attempt(async () => {
				sync = await api.putProjectSync(projectID, { staleAfterDays: days });
				threshold = String(sync.staleAfterDays);
			})
		) {
			saved = true;
			await onchanged?.();
		}
	}
</script>

<div class="bg-muted/30 flex flex-col gap-3 rounded-xl border p-3 text-sm" data-testid="sync-detail">
	{#if !sync}
		<p class="text-muted-foreground text-xs">{notice.text ? '' : t('sync.loading')}</p>
	{:else}
		<div class="flex flex-wrap items-center gap-2">
			<SyncChip sync={sync} />
			{#if sync.lastSyncedAt}
				<span class="text-muted-foreground text-xs" data-testid="sync-last">
					{t('sync.lastAt', { when: formatWhen(sync.lastSyncedAt) })}{#if sync.lastSyncedBy}{' '}{t('sync.lastBy', { who: sync.lastSyncedBy })}{/if}
				</span>
			{/if}
		</div>
		{#if !sync.bound}
			<p class="text-muted-foreground text-xs" data-testid="sync-unbound">{t('sync.unbound')}</p>
		{:else}
			<p class="text-xs"><span class="text-muted-foreground">{t('sync.repository')}:</span> <code class="break-all" data-testid="sync-repository">{sync.repository}</code></p>
		{/if}
		{#if sync.repoRef}<p class="text-xs break-all" data-testid="sync-ref">{t('sync.repoRef', { ref: sync.repoRef })}</p>{/if}
		<div>
			<p class="text-muted-foreground mb-0.5 text-xs font-semibold">{t('sync.summary')}</p>
			{#if sync.lastSummary}
				<p class="break-words whitespace-pre-wrap" data-testid="sync-summary">{sync.lastSummary}</p>
			{:else}
				<p class="text-muted-foreground text-xs">{t('sync.noSummary')}</p>
			{/if}
		</div>
		<form class="flex flex-col gap-1" onsubmit={save}>
			<label class="text-xs font-medium" for="sync-threshold-{projectID}">{t('sync.threshold')}</label>
			<div class="flex items-center gap-2">
				<Input
					id="sync-threshold-{projectID}"
					class="w-24"
					inputmode="numeric"
					bind:value={threshold}
					disabled={!editable}
					aria-invalid={invalid}
					data-testid="sync-threshold"
				/>
				<Button type="submit" size="sm" disabled={!editable} data-testid="sync-threshold-save">{t('sync.thresholdSave')}</Button>
			</div>
			<p class={['text-xs', invalid ? 'text-destructive' : 'text-muted-foreground']} role={invalid ? 'alert' : undefined}>
				{invalid ? t('sync.thresholdInvalid') : editable ? t('sync.thresholdHint') : t('sync.thresholdReadonly')}
			</p>
			{#if saved}<p class="text-success text-xs" role="status" data-testid="sync-saved">{t('sync.thresholdSaved')}</p>{/if}
		</form>
	{/if}
</div>
