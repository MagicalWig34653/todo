<script lang="ts">
	import Check from '@lucide/svelte/icons/check';
	import { onMount } from 'svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { ACCENT_PRESETS, DEFAULT_ACCENT, GLOW_LEVELS, accentTokens } from '#lib/theme/accent.js';
	import { theme, type ThemeMode } from '#lib/theme.svelte.js';
	import Panel from './app/Panel.svelte';

	const names = t('appearance.accent.names').split(',');
	const modes: ThemeMode[] = ['system', 'light', 'dark'];
	let custom = $state(theme.accent);
	let invalid = $state(false);

	// another device may have changed the account's values since this session was loaded
	onMount(() => void theme.refresh());

	function applyCustom() {
		const v = custom.startsWith('#') ? custom : `#${custom}`;
		if (theme.setCustomAccent(v)) {
			custom = theme.accent;
			invalid = false;
		} else invalid = true;
	}
	const seg = 'min-h-9 flex-1 rounded-md px-3 text-sm font-medium transition-colors aria-checked:bg-ui-accent aria-checked:text-ui-accent-foreground aria-checked:glow-accent hover:bg-muted aria-checked:hover:bg-ui-accent';
</script>

<Panel title={t('appearance.title')} description={t('appearance.description')}>
	<div class="flex flex-col gap-5" data-testid="appearance">
		<p class="text-muted-foreground text-[13px]" role="status" aria-live="polite" data-testid="appearance-sync" data-state={theme.sync}>
			{t(`appearance.sync.${theme.sync}` as MessageKey)}
		</p>

		<div class="flex flex-col gap-2">
			<h4 class="text-sm font-medium">{t('appearance.mode')}</h4>
			<div class="bg-muted flex gap-1 rounded-lg p-1" role="radiogroup" aria-label={t('appearance.mode')}>
				{#each modes as m (m)}
					<button type="button" role="radio" class={seg} aria-checked={theme.mode === m} data-testid="mode-{m}" onclick={() => theme.setMode(m)}>
						{t(`appearance.mode.${m}` as MessageKey)}
					</button>
				{/each}
			</div>
		</div>

		<div class="flex flex-col gap-2">
			<h4 class="text-sm font-medium">{t('appearance.accent')}</h4>
			<p class="text-muted-foreground text-[13px]">{t('appearance.accent.hint')}</p>
			<div class="grid grid-cols-7 gap-2" role="radiogroup" aria-label={t('appearance.accent')}>
				{#each ACCENT_PRESETS as preset, i (preset.id)}
					<button
						type="button"
						role="radio"
						aria-checked={theme.accentId === preset.id}
						aria-label={names[i] ?? preset.id}
						title={names[i] ?? preset.id}
						data-testid="accent-{preset.id}"
						class="aria-checked:border-foreground aria-checked:glow-accent inline-flex aspect-square w-full max-w-9 items-center justify-center rounded-full border-2 border-transparent text-[11px] font-semibold"
						style="background: {preset.hex}; color: {accentTokens(preset.hex, false).foreground}"
						onclick={() => {
							theme.setPreset(preset.id);
							custom = theme.accent;
							invalid = false;
						}}
					>
						{#if theme.accentId === preset.id}<Check class="size-4" aria-hidden="true" />{:else}Aa{/if}
					</button>
				{/each}
			</div>
			<div class="flex items-end gap-2">
				<div class="flex min-w-0 flex-1 flex-col gap-1.5">
					<label for="accent-hex" class="text-sm font-medium">{t('appearance.accent.custom')}</label>
					<Input
						id="accent-hex"
						bind:value={custom}
						placeholder={DEFAULT_ACCENT}
						maxlength={7}
						autocomplete="off"
						spellcheck={false}
						aria-invalid={invalid ? true : undefined}
						onkeydown={(e) => e.key === 'Enter' && (e.preventDefault(), applyCustom())}
						data-testid="accent-hex"
					/>
				</div>
				<Button variant="outline" onclick={applyCustom} data-testid="accent-apply">{t('appearance.accent.apply')}</Button>
			</div>
			{#if invalid}<p class="text-destructive text-[13px]" role="alert" data-testid="accent-invalid">{t('appearance.accent.invalid')}</p>{/if}
			<p class="text-muted-foreground text-[13px]" data-testid="accent-current">{t('appearance.accent.current', { hex: theme.accent.toUpperCase() })}</p>
		</div>

		<div class="flex flex-col gap-2">
			<h4 class="text-sm font-medium">{t('appearance.glow')}</h4>
			<p class="text-muted-foreground text-[13px]">{t('appearance.glow.hint')}</p>
			<div class="bg-muted flex gap-1 rounded-lg p-1" role="radiogroup" aria-label={t('appearance.glow')}>
				{#each GLOW_LEVELS as g (g)}
					<button type="button" role="radio" class={seg} aria-checked={theme.glow === g} data-testid="glow-{g}" onclick={() => theme.setGlow(g)}>
						{t(`appearance.glow.${g}` as MessageKey)}
					</button>
				{/each}
			</div>
		</div>

		<div class="flex flex-col gap-2">
			<h4 class="text-sm font-medium">{t('appearance.transparency')}</h4>
			<label class="flex items-center gap-3 text-sm">
				<Checkbox
					checked={theme.transparency === 'reduced'}
					onchange={(e) => theme.setTransparency(e.currentTarget.checked ? 'reduced' : 'system')}
					data-testid="transparency-toggle"
				/>
				{t('appearance.transparency.reduced')}
			</label>
			<p class="text-muted-foreground text-[13px]">{t('appearance.transparency.hint')}</p>
		</div>

		<div class="flex flex-col gap-2" data-testid="accent-preview">
			<h4 class="text-sm font-medium">{t('appearance.preview')}</h4>
			<div class="flex flex-wrap items-center gap-2">
				<Button>{t('appearance.preview.primary')}</Button>
				<Button variant="outline">{t('appearance.preview.secondary')}</Button>
				<span class="text-ui-accent-ink text-sm font-medium">{t('appearance.preview.text')}</span>
			</div>
		</div>

		<div><Button variant="ghost" size="sm" onclick={() => { theme.resetAll(); custom = theme.accent; invalid = false; }} data-testid="appearance-reset">{t('appearance.reset')}</Button></div>
	</div>
</Panel>
