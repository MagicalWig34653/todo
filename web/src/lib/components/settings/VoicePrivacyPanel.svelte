<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { t } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import {
		audioCountText,
		consentDateText,
		deleteResultText,
		deleteVoiceHistory,
		fetchVoicePrivacy,
		keepAudioDisabled,
		messageCountText,
		nothingStored,
		retentionTexts,
		saveVoicePrivacy,
		type VoicePrivacy,
		type VoicePrivacyPatch
	} from '#lib/voicePrivacy.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import Dialog from '../app/Dialog.svelte';
	import Panel from '../app/Panel.svelte';

	/**
	 * Privacy of voice messages in the channel #brain (card T1-7): consent, retention periods, keep audio, counters, delete the history.
	 * Only shows and requests; the backend decides (keep audio without consent is answered with 409 consent_required).
	 */
	let data = $state<VoicePrivacy | null>(null);
	let loadFailed = $state(false);
	let busy = $state(false);
	let status = $state('');
	let statusEl = $state<HTMLElement | null>(null);

	async function load() {
		loadFailed = false;
		try {
			data = await fetchVoicePrivacy();
		} catch {
			loadFailed = true;
		}
	}
	onMount(() => {
		void load();
	});

	const periods = $derived(data ? retentionTexts(data.retention) : null);
	const consentDate = $derived(consentDateText(data?.consentAt));

	function savedMessage(patch: VoicePrivacyPatch, saved: VoicePrivacy): string {
		if (patch.consent !== undefined) return t(patch.consent ? 'settings.data.voice.status.consentOn' : 'settings.data.voice.status.consentOff');
		return saved.keepAudio ? t('settings.data.voice.status.keepOn', { span: retentionTexts(saved.retention).keep }) : t('settings.data.voice.status.keepOff');
	}

	// Saves run one after the other, so a second click while the first is on its way is neither lost nor lets the box lose keyboard focus.
	let queue: Promise<unknown> = Promise.resolve();
	/** Saves one change; on failure the notice explains and the box returns to the state the server still has. */
	function save(patch: VoicePrivacyPatch, el: HTMLInputElement) {
		queue = queue.then(() => persist(patch, el));
	}
	async function persist(patch: VoicePrivacyPatch, el: HTMLInputElement) {
		busy = true;
		status = '';
		let saved: VoicePrivacy | undefined;
		const ok = await attempt(async () => {
			saved = await saveVoicePrivacy(patch);
		});
		busy = false;
		if (ok && saved) {
			data = saved;
			status = savedMessage(patch, saved);
		}
		await tick();
		if (data) el.checked = patch.consent !== undefined ? data.consent : data.keepAudio;
	}

	let open = $state(false);
	function startDelete() {
		notice.clear();
		status = '';
		open = true;
	}
	async function confirmDelete() {
		if (busy) return;
		busy = true;
		let result: Awaited<ReturnType<typeof deleteVoiceHistory>> | undefined;
		const ok = await attempt(async () => {
			result = await deleteVoiceHistory();
		});
		busy = false;
		if (!ok || !result) return;
		open = false;
		status = deleteResultText(result);
		if (data) data = { ...data, messageCount: 0, audioCount: 0 };
		await load();
		// The delete button is disabled now (nothing left): the result is announced and focus goes there instead of getting lost.
		await tick();
		statusEl?.focus();
	}

	const wrap = 'h-auto min-h-9 max-w-full py-1.5 text-center whitespace-normal';
</script>

<Panel title={t('settings.data.voice.title')} description={t('settings.data.voice.text')} class="min-w-0">
	<div class="flex min-w-0 flex-col gap-4 text-sm" data-testid="voice-privacy">
		{#if loadFailed}
			<div class="flex flex-col items-start gap-2" data-testid="voice-load-error">
				<p class="text-destructive" role="alert">{t('settings.data.voice.loadFailed')}</p>
				<Button variant="outline" class={wrap} onclick={load} data-testid="voice-retry">{t('settings.data.voice.retry')}</Button>
			</div>
		{:else if !data}
			<p class="text-muted-foreground" role="status">{t('common.loading')}</p>
		{:else}
			<div class="flex flex-col gap-1.5">
				<label class="flex items-start gap-2.5 font-medium">
					<Checkbox class="mt-0.5" checked={data.consent} aria-describedby="voice-consent-at" data-testid="voice-consent" onchange={(e) => save({ consent: e.currentTarget.checked }, e.currentTarget)} />
					<span class="min-w-0 [overflow-wrap:anywhere]">{t('settings.data.voice.consent.label')}</span>
				</label>
				<p id="voice-consent-at" class="text-muted-foreground pl-[28px] text-[13px]" data-testid="voice-consent-at">
					{data.consent && consentDate ? t('settings.data.voice.consent.at', { date: consentDate }) : t('settings.data.voice.consent.none')}
				</p>
			</div>

			<section class="flex flex-col gap-1.5" aria-labelledby="voice-periods-title" data-testid="voice-periods">
				<h4 id="voice-periods-title" class="font-semibold">{t('settings.data.voice.periods.title')}</h4>
				<ul class="text-muted-foreground flex list-disc flex-col gap-1 pl-5 [overflow-wrap:anywhere]">
					<li>{t('settings.data.voice.periods.input', { span: periods?.input ?? '' })}</li>
					<li>{t('settings.data.voice.periods.reply', { span: periods?.reply ?? '' })}</li>
					<li>{t('settings.data.voice.periods.transcripts')}</li>
				</ul>
			</section>

			<div class="flex flex-col gap-1.5">
				<label class="flex items-start gap-2.5 font-medium">
					<Checkbox
						class="mt-0.5"
						checked={data.keepAudio}
						disabled={keepAudioDisabled(data)}
						aria-describedby="voice-keep-hint"
						data-testid="voice-keep-audio"
						onchange={(e) => save({ keepAudio: e.currentTarget.checked }, e.currentTarget)}
					/>
					<span class="min-w-0 [overflow-wrap:anywhere]">{t('settings.data.voice.keep.label', { span: periods?.keep ?? '' })}</span>
				</label>
				<p id="voice-keep-hint" class="text-muted-foreground pl-[28px] text-[13px]" data-testid="voice-keep-hint">
					{data.consent ? t('settings.data.voice.keep.hint', { span: periods?.keep ?? '' }) : t('settings.data.voice.keep.hintNeedsConsent')}
				</p>
			</div>

			<div class="flex flex-col items-start gap-2 border-t pt-4">
				<p data-testid="voice-count" data-messages={data.messageCount} data-audio={data.audioCount} class="[overflow-wrap:anywhere]">
					{t('settings.data.voice.count')}
					<strong data-testid="voice-count-messages">{messageCountText(data.messageCount)}</strong>,
					{t('settings.data.voice.count.of')}
					<strong data-testid="voice-count-audio">{audioCountText(data.audioCount)}</strong>
				</p>
				<Button variant="destructive" class={wrap} onclick={startDelete} disabled={busy || nothingStored(data)} aria-describedby={nothingStored(data) ? 'voice-nothing' : undefined} data-testid="voice-delete-start">
					{t('settings.data.voice.delete.button')}
				</Button>
				{#if nothingStored(data)}<p id="voice-nothing" class="text-muted-foreground text-[13px]">{t('settings.data.voice.delete.nothingStored')}</p>{/if}
			</div>
		{/if}
		<p bind:this={statusEl} tabindex="-1" role="status" aria-live="polite" class={['min-h-5 outline-none', status && 'bg-success-soft text-success rounded-lg px-3 py-2']} data-testid="voice-status">{status}</p>
	</div>
</Panel>

<Dialog bind:open title={t('settings.data.voice.delete.title')} testid="voice-delete-dialog">
	<div class="flex flex-col gap-3 text-sm">
		<p>{t('settings.data.voice.delete.text')}</p>
		<p class="text-muted-foreground">{t('settings.data.voice.delete.export')}</p>
		<div class="flex flex-wrap justify-end gap-2">
			<Button variant="ghost" class={wrap} onclick={() => (open = false)} data-autofocus data-testid="voice-delete-cancel">{t('settings.data.voice.delete.cancel')}</Button>
			<Button variant="destructive" class={wrap} disabled={busy} onclick={confirmDelete} data-testid="voice-delete-confirm">
				{busy ? t('settings.data.voice.delete.busy') : t('settings.data.voice.delete.confirm')}
			</Button>
		</div>
	</div>
</Dialog>
