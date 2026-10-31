<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { hintFor, type ServerSetting, type SettingValue } from '#lib/adminSettings.js';
	import { formatWhen } from '#lib/planning.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';

	/**
	 * One setting, generated from the registry metadata of GET /v1/admin/settings: input by type, origin badge,
	 * lock notice (environment variable set), "wirkt nach Neustart", secret handling (never shown), reset.
	 */
	let {
		setting,
		draft = $bindable(),
		secretOpen = $bindable(false),
		busy = false,
		onreset,
		keyAvailable = true
	}: { setting: ServerSetting; draft: SettingValue; secretOpen?: boolean; busy?: boolean; onreset: () => void; keyAvailable?: boolean } = $props();

	const id = $derived(`srv-${setting.key}`);
	const hint = $derived(hintFor(setting, draft));
	const effective = $derived(setting.value === undefined ? '' : setting.type === 'bool' ? (setting.value ? t('admin.server.bool.on') : t('admin.server.bool.off')) : String(setting.value));
	const defaultText = $derived(
		setting.defaultValue === undefined
			? t('admin.server.default.none')
			: t('admin.server.default', { value: typeof setting.defaultValue === 'boolean' ? (setting.defaultValue ? t('admin.server.bool.on') : t('admin.server.bool.off')) : String(setting.defaultValue) })
	);
	const originVariant = $derived(setting.origin === 'env' ? 'warning' : setting.origin === 'db' ? 'accent' : 'default');
	const originText = $derived(t(`admin.server.origin.${setting.origin}`));
</script>

<div class="flex flex-col gap-1.5 border-b py-3 last:border-b-0" data-testid="srv-field-{setting.key}" data-origin={setting.origin} data-locked={setting.locked}>
	<div class="flex flex-wrap items-center gap-2">
		<label class="text-sm font-medium" for={id}>{setting.label}</label>
		<Badge variant={originVariant} data-testid="srv-origin-{setting.key}">{originText}</Badge>
		{#if setting.requiresRestart}<Badge variant="outline" data-testid="srv-restart-{setting.key}">{t('admin.server.restart')}</Badge>{/if}
	</div>
	<p class="text-muted-foreground text-[13px]">{setting.help}{#if setting.requiresRestart}&nbsp;{t('admin.server.restart.hint')}{/if}</p>

	{#if setting.locked}
		<div class="flex flex-col gap-1">
			{#if setting.secret}
				<p class="text-sm"><Badge variant="success">{t('admin.server.secret.set')}</Badge></p>
			{:else if setting.type === 'text'}
				<Textarea {id} value={effective} disabled rows={3} />
			{:else}
				<Input {id} value={effective} disabled />
			{/if}
			<p class="text-muted-foreground text-xs" data-testid="srv-locked-{setting.key}">{t('admin.server.locked', { env: setting.env })}</p>
		</div>
	{:else if setting.secret}
		<div class="flex flex-col gap-2">
			<div class="flex flex-wrap items-center gap-2">
				{#if setting.unreadable}
					<Badge variant="destructive" data-testid="srv-unreadable-{setting.key}">{t('admin.server.secret.unreadable')}</Badge>
				{:else if setting.isSet}
					<Badge variant="success" data-testid="srv-secret-{setting.key}">{t('admin.server.secret.set')}</Badge>
					{#if setting.fingerprint}<span class="text-muted-foreground font-mono text-xs">{t('admin.server.secret.fingerprint', { fp: setting.fingerprint })}</span>{/if}
				{:else}
					<Badge variant="default" data-testid="srv-secret-{setting.key}">{t('admin.server.secret.unset')}</Badge>
				{/if}
				{#if !secretOpen}
					<Button size="sm" variant="outline" disabled={busy || !keyAvailable} onclick={() => (secretOpen = true)} data-testid="srv-secret-change-{setting.key}">{t('admin.server.secret.change')}</Button>
				{:else}
					<Button size="sm" variant="ghost" onclick={() => { secretOpen = false; draft = ''; }}>{t('admin.server.secret.cancel')}</Button>
				{/if}
			</div>
			{#if secretOpen}
				{#if setting.type === 'text'}
					<Textarea {id} bind:value={draft as string} rows={5} autocomplete="off" spellcheck={false} placeholder={t('admin.server.secret.new')} data-testid="srv-input-{setting.key}" />
				{:else}
					<Input {id} type="password" bind:value={draft as string} autocomplete="new-password" placeholder={t('admin.server.secret.new')} data-testid="srv-input-{setting.key}" />
				{/if}
				<p class="text-muted-foreground text-xs">{t('admin.server.secret.never')}</p>
			{/if}
		</div>
	{:else if setting.type === 'bool'}
		<label class="flex w-fit items-center gap-2 text-sm">
			<Checkbox {id} bind:checked={draft as boolean} disabled={busy} data-testid="srv-input-{setting.key}" />
			<span>{draft === true ? t('admin.server.bool.on') : t('admin.server.bool.off')}</span>
		</label>
	{:else if setting.type === 'enum'}
		<Select {id} bind:value={draft as string} disabled={busy} class="max-w-xs" data-testid="srv-input-{setting.key}">
			{#each setting.options ?? [] as option (option)}<option value={option}>{option}</option>{/each}
		</Select>
	{:else if setting.type === 'text'}
		<Textarea {id} bind:value={draft as string} rows={4} disabled={busy} data-testid="srv-input-{setting.key}" />
	{:else if setting.type === 'int'}
		<Input {id} type="text" inputmode="numeric" bind:value={draft as string} disabled={busy} placeholder={setting.defaultValue === undefined ? '' : String(setting.defaultValue)} class="max-w-xs" aria-invalid={hint ? 'true' : undefined} data-testid="srv-input-{setting.key}" />
	{:else}
		<Input {id} type="text" bind:value={draft as string} disabled={busy} placeholder={setting.placeholder ?? ''} autocomplete="off" aria-invalid={hint ? 'true' : undefined} data-testid="srv-input-{setting.key}" />
	{/if}

	{#if hint}<p class="text-destructive text-xs" role="alert" data-testid="srv-hint-{setting.key}">{t(hint.key, hint.params)}</p>{/if}

	<div class="text-muted-foreground flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
		{#if !setting.secret}<span>{defaultText}</span>{/if}
		{#if setting.updatedAt && setting.origin === 'db'}<span>{t('admin.server.updated', { who: setting.updatedBy ?? '–', when: formatWhen(setting.updatedAt) })}</span>{/if}
		{#if setting.origin === 'db' && !setting.locked}
			<Button size="sm" variant="ghost" disabled={busy} title={t('admin.server.reset.title')} onclick={onreset} data-testid="srv-reset-{setting.key}">{t('admin.server.reset')}</Button>
		{/if}
	</div>
</div>
