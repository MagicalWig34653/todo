<script lang="ts">
	import { api } from '#lib/api.js';
	import { confirmGate, failureKey, nameMatches, outcomeKey, type ActionRequest, type ForYouConfirmation } from '#lib/forYou.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import OptionButtons from './OptionButtons.svelte';

	/** Card of a confirmation request (ADR 0026): what would happen, two-step confirm for irreversible actions, outcome afterwards. */
	interface Props {
		item: ForYouConfirmation;
		/** Set once the request was decided; the card then shows only the outcome. */
		outcome?: ActionRequest | null;
		ondecided: (item: ForYouConfirmation, result: ActionRequest) => void;
	}
	let { item, outcome = null, ondecided }: Props = $props();

	let step = $state<'ask' | 'confirm'>('ask');
	let typed = $state('');
	let understood = $state(false);
	let busy = $state(false);

	const gate = $derived(confirmGate(item));
	const ready = $derived(!item.impact.destructive || (gate === 'name' ? nameMatches(typed, item.impact.targetName) : understood));
	const KNOWN = ['delete_project', 'delete_task', 'transfer_project_owner'];
	const kindKey = $derived(KNOWN.includes(item.tool) ? `confirm.kind.${item.tool}` : 'confirm.kind.other');

	async function decide(kind: 'confirm' | 'reject') {
		if (busy) return;
		busy = true;
		await attempt(async () => {
			try {
				const result = kind === 'confirm' ? await api.confirmActionRequest(item.id) : await api.rejectActionRequest(item.id);
				ondecided(item, result);
			} finally {
				busy = false;
			}
		});
	}
	function outcomeText(r: ActionRequest): string {
		const base = t(outcomeKey(r) as MessageKey, { reason: r.state === 'failed' ? t(failureKey(r.result?.code) as MessageKey) : '' });
		return base;
	}
</script>

<article class="bg-card flex min-w-0 flex-col gap-2 rounded-xl border p-3 [overflow-wrap:anywhere]" data-testid="confirm-card" data-tool={item.tool} data-state={outcome?.state ?? 'pending'}>
	<div class="flex min-w-0 flex-col gap-0.5">
		<span class="text-destructive text-xs font-semibold">{t(kindKey as MessageKey)}</span>
		<span class="text-muted-foreground text-xs">{t('confirm.by', { agent: item.agentLabel || t('confirm.agentFallback') })}</span>
		<span class="text-sm font-semibold" data-testid="confirm-summary">{item.summary}</span>
		<span class="text-muted-foreground text-xs">{t('confirm.expires', { when: formatWhen(item.expiresAt) })}</span>
	</div>

	{#if outcome}
		<p class={['text-sm', outcome.state === 'failed' ? 'text-destructive' : 'text-muted-foreground']} role="status" data-testid="confirm-outcome">{outcomeText(outcome)}</p>
	{:else if step === 'ask'}
		<OptionButtons
			class="gap-2"
			disabled={busy}
			items={[{ key: 'confirm', label: t('confirm.confirm') }, { key: 'reject', label: t('confirm.reject') }]}
			onpick={(k) => (k === 'confirm' ? (step = 'confirm') : void decide('reject'))}
		/>
	{:else}
		<div class="border-destructive/40 flex min-w-0 flex-col gap-2 rounded-lg border p-2" data-testid="confirm-step">
			{#if item.impact.destructive}
				{#if gate === 'name'}
					<label class="flex min-w-0 flex-col gap-1 text-sm">
						<span>{t('confirm.typeName', { name: item.impact.targetName })}</span>
						<Input bind:value={typed} aria-label={t('confirm.nameLabel')} autocomplete="off" data-testid="confirm-name" />
					</label>
				{:else}
					<label class="flex items-start gap-2 text-sm">
						<Checkbox bind:checked={understood} data-testid="confirm-understood" />
						<span>{t('confirm.understood')}</span>
					</label>
				{/if}
			{/if}
			<div class="flex flex-wrap gap-2">
				<Button variant="destructive" disabled={!ready || busy} onclick={() => decide('confirm')} data-testid="confirm-run">{busy ? t('confirm.busy') : t('confirm.run')}</Button>
				<Button variant="outline" disabled={busy} onclick={() => { step = 'ask'; typed = ''; understood = false; }}>{t('confirm.cancel')}</Button>
			</div>
		</div>
	{/if}
</article>
