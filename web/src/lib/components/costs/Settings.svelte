<script lang="ts">
	import { tick } from 'svelte';
	import { api } from '#lib/api.js';
	import { describeError } from '#lib/errors.js';
	import { t } from '#lib/i18n/index.js';
	import {
		DEFAULT_THRESHOLDS, PRICE_FIELDS, THRESHOLD_KEYS, addPriceRow, buildSettingsUpdate, settingsDraft,
		type Price, type SettingsDraft, type Thresholds, type UsageSettings
	} from '#lib/usage.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';

	let {
		settings,
		failed,
		onretry,
		onsaved
	}: { settings: UsageSettings | null; failed: boolean; onretry: () => void; onsaved: (s: UsageSettings) => void } = $props();

	let open = $state(false);
	let draft = $state<SettingsDraft | null>(null);
	let error = $state('');
	let savedNote = $state(false);
	let busy = $state(false);
	let root = $state<HTMLDetailsElement>();

	/** The form follows what the server stores; edits live in the draft until saved. */
	$effect.pre(() => {
		draft = settings ? settingsDraft(settings) : null;
	});

	const price = (v: number) => new Intl.NumberFormat('de-DE', { maximumFractionDigits: 6 }).format(v);
	const defaults: Thresholds = DEFAULT_THRESHOLDS;

	/** Opens the section with an own price row for `model` ('' = empty row) and moves the focus there. */
	export async function addModel(model: string, from?: Price) {
		open = true;
		savedNote = false;
		if (!draft) return;
		draft = addPriceRow(draft, model, from);
		await tick();
		const rows = Array.from(root?.querySelectorAll<HTMLElement>('[data-testid="costs-price-row"]') ?? []);
		const row = (model ? rows.find((r) => r.dataset.model?.toLowerCase() === model.toLowerCase()) : null) ?? rows.at(-1);
		row?.scrollIntoView({ block: 'center' });
		row?.querySelectorAll('input')[model ? 1 : 0]?.focus({ preventScroll: true });
	}

	async function save(e: Event) {
		e.preventDefault();
		if (!draft || busy) return;
		savedNote = false;
		const update = buildSettingsUpdate(draft);
		if (!update.ok) {
			error = update.error;
			return;
		}
		error = '';
		busy = true;
		try {
			onsaved(await api.putUsageSettings(update.body));
			savedNote = true;
		} catch (err) {
			error = t('usage.settings.saveError', { reason: describeError(err) });
		} finally {
			busy = false;
		}
	}
</script>

<details bind:this={root} bind:open class="bg-card min-w-0 rounded-xl border" data-testid="costs-settings">
	<summary class="cursor-pointer px-4 py-3 text-base font-semibold">{t('usage.settings.title')}</summary>
	<div class="border-t p-4">
		{#if failed}
			<div role="alert" class="flex flex-col items-start gap-2">
				<p class="text-sm">{t('usage.settings.error')}</p>
				<Button variant="outline" onclick={onretry}>{t('usage.retry')}</Button>
			</div>
		{:else if !settings || !draft}
			<p class="text-muted-foreground text-sm" role="status">{t('common.loading')}</p>
		{:else}
			<h4 class="mb-1 text-sm font-semibold">{t('usage.settings.prices')}</h4>
			<ul class="divide-border mb-5 flex flex-col divide-y">
				{#each settings.prices as p (p.model)}
					<li class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 py-2">
						<div class="min-w-0">
							<p class="flex flex-wrap items-center gap-2 text-sm">
								<span class="font-mono [overflow-wrap:anywhere]">{p.model}</span>
								<Badge variant={p.custom ? 'accent' : 'default'}>{p.custom ? t('usage.settings.custom') : t('usage.settings.default')}</Badge>
							</p>
							<p class="text-muted-foreground text-xs" data-tabular>
								{PRICE_FIELDS.map((f) => `${t(`usage.price.${f}`)} ${price(p[f])}`).join(' · ')}
							</p>
						</div>
						{#if !p.custom}
							<Button variant="ghost" size="sm" class="max-menu:h-10" aria-label={t('usage.settings.overrideLabel', { model: p.model })} onclick={() => addModel(p.model, p)}>
								{t('usage.settings.override')}
							</Button>
						{/if}
					</li>
				{/each}
			</ul>

			<form onsubmit={save} oninput={() => (savedNote = false)} novalidate>
				<h4 class="text-sm font-semibold">{t('usage.settings.own')}</h4>
				<p class="text-muted-foreground mb-2 text-[13px]">{t('usage.settings.ownHint')}</p>
				{#if draft.prices.length === 0}<p class="text-muted-foreground mb-2 text-sm">{t('usage.settings.noOwn')}</p>{/if}
				{#each draft.prices as row, i (i)}
					<fieldset class="mb-3 min-w-0 rounded-lg border p-3" data-testid="costs-price-row" data-model={row.model}>
						<div class="grid grid-cols-2 gap-2 sm:grid-cols-5">
							<label class="col-span-2 flex min-w-0 flex-col gap-1 text-xs font-medium sm:col-span-5">
								<span>{t('usage.settings.model')}</span>
								<Input bind:value={row.model} class="font-mono" autocomplete="off" autocapitalize="off" spellcheck="false" />
							</label>
							{#each PRICE_FIELDS as f (f)}
								<label class="flex min-w-0 flex-col gap-1 text-xs font-medium">
									<span>{t(`usage.price.${f}`)}</span>
									<Input bind:value={row[f]} inputmode="decimal" autocomplete="off" />
								</label>
							{/each}
						</div>
						<Button variant="ghost" size="sm" class="max-menu:h-10 mt-2" aria-label={t('usage.settings.removeLabel', { model: row.model })} onclick={() => draft && draft.prices.splice(i, 1)}>
							{t('usage.settings.remove')}
						</Button>
					</fieldset>
				{/each}
				<Button variant="outline" size="sm" class="max-menu:h-10" onclick={() => addModel('')}>{t('usage.settings.add')}</Button>

				<h4 class="mt-6 text-sm font-semibold">{t('usage.settings.thresholds')}</h4>
				<p class="text-muted-foreground mb-2 text-[13px]">{t('usage.settings.thresholdsHint')}</p>
				<div class="grid grid-cols-1 items-end gap-3 sm:grid-cols-2">
					{#each THRESHOLD_KEYS as key (key)}
						<label class="flex min-w-0 flex-col gap-1 text-xs font-medium">
							<span>{t(`usage.threshold.${key}`)}</span>
							<Input
								bind:value={draft.thresholds[key]}
								inputmode={key.startsWith('costTrend') ? 'text' : 'decimal'}
								autocomplete="off"
								placeholder={defaults[key] === undefined ? t('usage.settings.noDefault') : String(defaults[key])}
							/>
						</label>
					{/each}
				</div>

				{#if error}<p class="text-destructive mt-3 text-sm" role="alert" data-testid="costs-settings-error">{error}</p>{/if}
				<div class="mt-4 flex flex-wrap items-center gap-3">
					<Button type="submit" class="max-menu:h-10" disabled={busy} data-testid="costs-save">{t('usage.settings.save')}</Button>
					<span class="text-success text-sm" role="status" data-testid="costs-saved">{savedNote ? t('usage.settings.saved') : ''}</span>
				</div>
			</form>
		{/if}
	</div>
</details>
