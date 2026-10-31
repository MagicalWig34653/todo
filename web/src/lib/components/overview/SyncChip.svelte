<script lang="ts">
	import type { SyncBrief } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import { syncChip } from '#lib/syncState.js';
	import { Badge } from '#lib/components/ui/badge/index.js';

	/** Freshness of the repository sync (ADR 0018): fresh / stale (n days) / never. */
	let { sync }: { sync: SyncBrief | null | undefined } = $props();

	const chip = $derived(syncChip(sync));
	const text = $derived(
		chip.state === 'fresh' ? t('sync.fresh') : chip.state === 'never' ? t('sync.never') : chip.days === 1 ? t('sync.stale.one') : t('sync.stale', { days: chip.days })
	);
</script>

<Badge variant={chip.tone} data-testid="sync-chip" data-state={chip.state}>{text}</Badge>
