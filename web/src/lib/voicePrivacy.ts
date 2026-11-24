/** Privacy of voice messages in the channel #brain (card T1-7, contracts/voice.yaml): consent, retention periods, delete. */
import { ApiError } from './api.js';
import { t } from './i18n/index.js';

/** Retention periods as the server states them; the UI never hard-codes the numbers. */
export interface VoiceRetention {
	/** An incoming voice message is deleted after processing, at the latest after this many hours. */
	inputHours: number;
	/** A voice reply is deleted after this many days. */
	replyDays: number;
	/** Audio kept on request is deleted after this many days. */
	keepDays: number;
}

export interface VoicePrivacy {
	consent: boolean;
	consentAt: string | null;
	keepAudio: boolean;
	retention: VoiceRetention;
	messageCount: number;
	audioCount: number;
}

export interface VoiceDeleteResult {
	deletedMessages: number;
	deletedAudio: number;
}

export type VoicePrivacyPatch = { consent?: boolean; keepAudio?: boolean };

export const hoursText = (n: number): string => t(n === 1 ? 'settings.data.voice.hours.one' : 'settings.data.voice.hours.other', { n });
export const daysText = (n: number): string => t(n === 1 ? 'settings.data.voice.days.one' : 'settings.data.voice.days.other', { n });
export const messageCountText = (n: number): string => t(n === 1 ? 'settings.data.voice.messages.one' : 'settings.data.voice.messages.other', { n });
export const audioCountText = (n: number): string => t(n === 1 ? 'settings.data.voice.audio.one' : 'settings.data.voice.audio.other', { n });

export function retentionTexts(r: VoiceRetention): { input: string; reply: string; keep: string } {
	return { input: hoursText(r.inputHours), reply: daysText(r.replyDays), keep: daysText(r.keepDays) };
}

/** `24.11.2026` (German, in the given time zone; default: the device's). Empty for a missing or invalid date. */
export function consentDateText(iso: string | null | undefined, timeZone?: string): string {
	if (!iso) return '';
	const d = new Date(iso);
	if (Number.isNaN(d.getTime())) return '';
	return new Intl.DateTimeFormat('de-DE', { day: '2-digit', month: '2-digit', year: 'numeric', timeZone }).format(d);
}

/** The switch needs consent to be turned on; switching it off stays possible whatever the state. */
export const keepAudioDisabled = (p: Pick<VoicePrivacy, 'consent' | 'keepAudio'>): boolean => !p.consent && !p.keepAudio;

export const nothingStored = (p: Pick<VoicePrivacy, 'messageCount' | 'audioCount'>): boolean => p.messageCount === 0 && p.audioCount === 0;

export function deleteResultText(r: VoiceDeleteResult): string {
	if (r.deletedMessages === 0 && r.deletedAudio === 0) return t('settings.data.voice.delete.nothing');
	return t('settings.data.voice.delete.done', { messages: messageCountText(r.deletedMessages), audio: audioCountText(r.deletedAudio) });
}

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;
const browserFetch: FetchFn = (i, init) => fetch(i, init);

async function call<T>(fetchFn: FetchFn, url: string, init: RequestInit): Promise<T> {
	let res: Response;
	try {
		res = await fetchFn(url, { credentials: 'same-origin', ...init, headers: { Accept: 'application/json', ...(init.body ? { 'Content-Type': 'application/json' } : {}) } });
	} catch {
		throw new ApiError(0, 'network');
	}
	if (!res.ok) {
		let reason: string | undefined;
		try {
			reason = ((await res.json()) as { reason?: string }).reason;
		} catch {
			/* not JSON */
		}
		throw new ApiError(res.status, reason);
	}
	return (await res.json()) as T;
}

/** GET /v1/me/voice-privacy */
export const fetchVoicePrivacy = (fetchFn: FetchFn = browserFetch): Promise<VoicePrivacy> => call(fetchFn, '/v1/me/voice-privacy', { method: 'GET' });

/** PUT /v1/me/voice-privacy; `keepAudio: true` without consent is answered with 409 `consent_required`. */
export const saveVoicePrivacy = (patch: VoicePrivacyPatch, fetchFn: FetchFn = browserFetch): Promise<VoicePrivacy> =>
	call(fetchFn, '/v1/me/voice-privacy', { method: 'PUT', body: JSON.stringify(patch) });

/** DELETE /v1/channels/brain/messages: messages, jobs and audio are gone for good; the settings stay. */
export const deleteVoiceHistory = (fetchFn: FetchFn = browserFetch): Promise<VoiceDeleteResult> =>
	call(fetchFn, '/v1/channels/brain/messages', { method: 'DELETE' });
