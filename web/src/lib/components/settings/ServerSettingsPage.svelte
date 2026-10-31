<script lang="ts">
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { describeError } from '#lib/errors.js';
	import {
		adminSettings, draftOf, isDirty, saveOrder, toValue, SettingsApiError, TEST_FOR_CATEGORY,
		type ServerSettingsOverview, type SettingValue, type TestResult
	} from '#lib/adminSettings.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import Panel from '../app/Panel.svelte';
	import ServerSettingField from './ServerSettingField.svelte';

	/**
	 * Form of one server settings category, generated from GET /v1/admin/settings (ADR 0025). Saving sends only the
	 * changed fields, each with the version it was loaded with; a conflict reloads and tells the admin.
	 */
	let { category }: { category: string } = $props();

	let overview = $state<ServerSettingsOverview | null>(null);
	let drafts = $state<Record<string, SettingValue>>({});
	let secretOpen = $state<Record<string, boolean>>({});
	let message = $state<{ kind: 'ok' | 'error' | 'conflict'; text: string } | null>(null);
	let busy = $state(false);
	let failedToLoad = $state(false);
	let testTo = $state('');
	let testing = $state(false);
	let result = $state<TestResult | null>(null);

	const settings = $derived((overview?.settings ?? []).filter((s) => s.category === category));
	const meta = $derived(overview?.categories.find((c) => c.id === category));
	const dirty = $derived(settings.filter((s) => isDirty(s, drafts[s.key])));
	const hasSecrets = $derived(settings.some((s) => s.secret && !s.locked));
	const testKind = $derived(TEST_FOR_CATEGORY[category]);

	function fail(e: unknown) {
		if (e instanceof SettingsApiError && e.isUnauthorized) {
			auth.user = null;
			return;
		}
		message = { kind: e instanceof SettingsApiError && e.isVersionConflict ? 'conflict' : 'error', text: e instanceof SettingsApiError && e.isVersionConflict ? t('admin.server.conflict') : e instanceof SettingsApiError && e.serverMessage ? e.serverMessage : describeError(e) };
	}

	function resetDrafts() {
		const next: Record<string, SettingValue> = {};
		for (const s of overview?.settings ?? []) next[s.key] = draftOf(s);
		drafts = next;
		secretOpen = Object.fromEntries((overview?.settings ?? []).map((s) => [s.key, false]));
	}
	async function load(keepMessage = false) {
		try {
			overview = await adminSettings.overview();
			failedToLoad = false;
			resetDrafts();
			if (!keepMessage) message = null;
		} catch (e) {
			failedToLoad = true;
			fail(e);
		}
	}
	$effect(() => {
		category;
		result = null;
		void load();
	});

	async function save() {
		if (dirty.length === 0) {
			message = { kind: 'ok', text: t('admin.server.nothing') };
			return;
		}
		busy = true;
		message = null;
		const typed = dirty.map((s) => s.key);
		const changes = dirty.flatMap((s) => {
			const value = toValue(s, drafts[s.key]);
			return value === undefined ? [] : [{ setting: s, value }];
		});
		try {
			for (const c of saveOrder(changes)) await adminSettings.put(c.setting.key, c.value, c.setting.version);
			await load(true);
			message = { kind: 'ok', text: t('admin.server.saved') };
		} catch (e) {
			fail(e);
			// Reload either way: some fields may have been saved before the failing one, or someone else changed them.
			try {
				const keep = message;
				overview = await adminSettings.overview();
				const open = { ...secretOpen };
				const kept = { ...drafts };
				resetDrafts();
				if (!(e instanceof SettingsApiError && e.isVersionConflict)) {
					// keep what the admin typed so the correction is one edit away
					for (const key of typed) if (kept[key] !== undefined) drafts[key] = kept[key];
					secretOpen = open;
				}
				message = keep;
			} catch {
				/* the message above already tells what happened */
			}
		} finally {
			busy = false;
		}
	}

	async function reset(key: string, version: number) {
		busy = true;
		message = null;
		try {
			await adminSettings.reset(key, version);
			await load(true);
			message = { kind: 'ok', text: t('admin.server.resetDone') };
		} catch (e) {
			fail(e);
			await load(true).catch(() => {});
		} finally {
			busy = false;
		}
	}

	async function runTest() {
		if (!testKind) return;
		testing = true;
		result = null;
		message = null;
		try {
			result = await adminSettings.test(testKind, testKind === 'mail' && testTo.trim() ? { to: testTo.trim() } : undefined);
		} catch (e) {
			fail(e);
		} finally {
			testing = false;
		}
	}
</script>

<div class="flex flex-col gap-4" data-testid="server-settings-{category}">
	{#if !overview && !failedToLoad}
		<p class="text-muted-foreground text-sm">{t('admin.server.loading')}</p>
	{/if}
	{#if overview}
		{#if overview.lastError}<p class="bg-warning-soft text-warning rounded-lg px-3 py-2 text-sm" role="status" data-testid="server-last-error">{t('admin.server.lastError')}</p>{/if}
		{#if hasSecrets && !overview.encryptionKeyConfigured}
			<p class="bg-warning-soft text-warning rounded-lg px-3 py-2 text-sm" role="status" data-testid="server-no-key">{t('admin.server.noKey')}</p>
		{/if}
		<Panel title={meta?.label} description={meta?.help}>
			<form
				class="flex flex-col"
				onsubmit={(e) => {
					e.preventDefault();
					void save();
				}}
			>
				{#each settings as s (s.key)}
					<ServerSettingField
						setting={s}
						bind:draft={drafts[s.key]}
						bind:secretOpen={secretOpen[s.key]}
						{busy}
						keyAvailable={overview.encryptionKeyConfigured}
						onreset={() => reset(s.key, s.version)}
					/>
				{/each}
				<div class="flex flex-wrap items-center gap-3 pt-3">
					<Button type="submit" size="lg" disabled={busy || dirty.length === 0} data-testid="srv-save">{t('admin.server.save')}</Button>
					{#if message}
						<p
							class={['text-sm', message.kind === 'ok' ? 'text-success' : 'text-destructive']}
							role={message.kind === 'ok' ? 'status' : 'alert'}
							data-testid="srv-message"
							data-kind={message.kind}
						>
							{message.text}
						</p>
					{/if}
				</div>
			</form>
		</Panel>

		{#if testKind}
			<Panel title={t('admin.server.test.title')} description={t(`admin.server.test.${testKind === 'apns' ? 'apns' : testKind}.hint`)}>
				{#if testKind === 'mail'}
					<Input type="email" bind:value={testTo} placeholder={t('admin.server.test.mail.to')} aria-label={t('admin.server.test.mail.to')} autocomplete="off" class="max-w-md" data-testid="srv-test-to" />
				{/if}
				<div>
					<Button variant="outline" disabled={testing || busy} onclick={runTest} data-testid="srv-test">
						{testing ? t('admin.server.test.running') : t(`admin.server.test.${testKind === 'apns' ? 'apns' : testKind}`)}
					</Button>
				</div>
				{#if result}
					<div class={['rounded-lg px-3 py-2 text-sm', result.ok ? 'bg-success-soft text-success' : 'bg-destructive/10 text-destructive']} role="status" data-testid="srv-test-result" data-ok={result.ok}>
						<p>{result.message}{#if result.durationMs !== undefined}&nbsp;{t('admin.server.test.duration', { ms: result.durationMs })}{/if}</p>
						{#if result.details}
							<ul class="mt-1 list-disc pl-5 text-xs">
								{#each Object.entries(result.details) as [k, v] (k)}<li>{k}: {v}</li>{/each}
							</ul>
						{/if}
					</div>
				{/if}
			</Panel>
		{/if}
	{:else if failedToLoad && message}
		<p class="text-destructive text-sm" role="alert" data-testid="srv-message">{message.text}</p>
	{/if}
</div>
