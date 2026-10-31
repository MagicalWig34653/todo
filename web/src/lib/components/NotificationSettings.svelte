<script lang="ts">
	import { api, type PushDevice, type PushPrefs, type PushTestResult } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { PUSH_CATEGORIES, PUSH_DEFAULTS, summarizeTest } from '#lib/notify.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';

	let serverEnabled = $state<boolean | null>(null);
	let devices = $state<PushDevice[]>([]);
	let prefs = $state<PushPrefs>({ categories: { ...PUSH_DEFAULTS }, showContent: false, badge: true });
	let revokingID = $state<string | null>(null);
	let info = $state<string | null>(null);
	let testing = $state(false);
	let result = $state<PushTestResult | null>(null);

	async function load() {
		[serverEnabled, devices, prefs] = await Promise.all([api.pushServerEnabled(), api.listPushDevices(), api.getPushPrefs()]);
	}
	$effect(() => {
		attempt(load);
	});

	async function setCategory(key: string, value: boolean) {
		await attempt(async () => { prefs = await api.setPushPrefs({ categories: { [key]: value } }); }, load);
	}
	async function setFlag(patch: { showContent?: boolean; badge?: boolean }) {
		await attempt(async () => { prefs = await api.setPushPrefs(patch); }, load);
	}
	async function revoke(d: PushDevice) {
		info = null;
		if (await attempt(async () => { await api.revokePushDevice(d.id); await load(); }, load)) {
			revokingID = null;
			info = t('notify.devices.revoked');
		}
	}
	async function sendTest() {
		testing = true;
		result = null;
		info = null;
		try {
			await attempt(async () => {
				result = await api.sendPushTest();
				devices = await api.listPushDevices();
			});
		} finally {
			testing = false;
		}
	}
	const deviceName = (d: PushDevice) => t(`notify.devices.platform.${d.platform}` as MessageKey);
	const summary = $derived(result ? summarizeTest(result) : null);
</script>

<div class="bg-card flex flex-col gap-4 rounded-xl border p-4 shadow-card sm:p-5" data-testid="notify-settings">
	<div>
		<h3 class="text-base font-semibold">{t('notify.title')}</h3>
		<p class="text-muted-foreground mt-1 text-xs">{t('notify.intro')}</p>
	</div>

	{#if serverEnabled !== null}
		<p class={['rounded-lg px-3 py-2 text-sm', serverEnabled ? 'bg-success-soft text-success' : 'bg-muted text-muted-foreground']} role="status" data-testid="notify-server" data-enabled={serverEnabled}>
			{serverEnabled ? t('notify.server.on') : t('notify.server.off')}
		</p>
	{/if}
	{#if info}<p class="text-sm" role="status" data-testid="notify-info">{info}</p>{/if}

	<section class="flex flex-col gap-2" aria-labelledby="notify-devices-h">
		<h4 id="notify-devices-h" class="text-sm font-medium">{t('notify.devices')}</h4>
		{#if devices.length === 0}
			<p class="text-muted-foreground text-sm" data-testid="notify-no-devices">{t('notify.devices.empty')}</p>
		{/if}
		<ul class="flex flex-col gap-2">
			{#each devices as d (d.id)}
				<li class="rounded-lg border p-2.5 text-sm" data-testid="notify-device">
					<div class="flex flex-wrap items-center gap-2">
						<span class="flex-1">
							<strong>{deviceName(d)}</strong>
							<span class="text-muted-foreground text-xs">· {t(`notify.devices.env.${d.environment}` as MessageKey)}{d.appVersion ? ` · ${d.appVersion}` : ''}</span>
							<span class="text-muted-foreground block text-xs">{t('notify.devices.lastSeen', { when: formatWhen(d.lastSeenAt) })}</span>
						</span>
						<Button size="xs" variant="destructive" aria-label={t('notify.devices.revokeLabel', { name: deviceName(d) })} onclick={() => (revokingID = d.id)}>{t('notify.devices.revoke')}</Button>
					</div>
					{#if revokingID === d.id}
						<div class="mt-2 flex flex-wrap items-center gap-2">
							<span>{t('notify.devices.revokeConfirm')}</span>
							<Button size="sm" variant="destructive" onclick={() => revoke(d)}>{t('notify.devices.revoke')}</Button>
							<Button size="sm" variant="ghost" onclick={() => (revokingID = null)}>{t('common.cancel')}</Button>
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	</section>

	<fieldset class="flex flex-col gap-2">
		<legend class="mb-1 text-sm font-medium">{t('notify.prefs')}</legend>
		{#each PUSH_CATEGORIES as key (key)}
			<label class="flex min-h-9 items-center gap-2.5 text-sm">
				<Checkbox checked={prefs.categories[key] ?? PUSH_DEFAULTS[key]} onchange={(e) => setCategory(key, e.currentTarget.checked)} data-testid="pref-{key}" />
				<span>{t(`notify.prefs.${key}` as MessageKey)}</span>
			</label>
		{/each}
		<label class="flex min-h-9 items-start gap-2.5 text-sm">
			<Checkbox class="mt-0.5" checked={prefs.showContent} onchange={(e) => setFlag({ showContent: e.currentTarget.checked })} data-testid="pref-showContent" aria-describedby="pref-showContent-hint" />
			<span>{t('notify.prefs.showContent')}<span id="pref-showContent-hint" class="text-muted-foreground block text-xs">{t('notify.prefs.showContent.hint')}</span></span>
		</label>
		<label class="flex min-h-9 items-center gap-2.5 text-sm">
			<Checkbox checked={prefs.badge} onchange={(e) => setFlag({ badge: e.currentTarget.checked })} data-testid="pref-badge" />
			<span>{t('notify.prefs.badge')}</span>
		</label>
	</fieldset>

	<div class="flex flex-col gap-2">
		<div class="flex flex-wrap items-center gap-3">
			<Button size="lg" variant="outline" disabled={testing || serverEnabled === false} onclick={sendTest} data-testid="push-test">
				{testing ? t('notify.test.busy') : t('notify.test')}
			</Button>
			<span class="text-muted-foreground text-xs">{t('notify.test.hint')}</span>
		</div>
		<div aria-live="polite" data-testid="push-test-result">
			{#if result && summary}
				{#if summary.none}
					<p class="text-sm">{t('notify.test.none')}</p>
				{:else}
					<p class="text-sm font-medium">{t('notify.test.summary', { sent: summary.sent, total: summary.total })}</p>
					<ul class="mt-1 flex flex-col gap-1">
						{#each result.devices as d (d.id)}
							<li class="text-sm" data-testid="push-test-device" data-result={d.result}>
								{t(`notify.devices.platform.${d.platform}` as MessageKey)} ·
								{d.result === 'sent' ? t('notify.test.sent') : d.result === 'revoked' ? t('notify.test.revoked') : t('notify.test.failed')}{d.detail ? ` (${d.detail})` : ''}
							</li>
						{/each}
					</ul>
				{/if}
			{/if}
		</div>
	</div>
</div>
