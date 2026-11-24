import { describe, expect, it } from 'vitest';
import { de } from '../src/lib/i18n/de.js';
import { ApiError } from '../src/lib/api.js';
import {
	audioCountText,
	consentDateText,
	daysText,
	deleteResultText,
	deleteVoiceHistory,
	fetchVoicePrivacy,
	hoursText,
	keepAudioDisabled,
	messageCountText,
	nothingStored,
	retentionTexts,
	saveVoicePrivacy,
	type VoicePrivacy
} from '../src/lib/voicePrivacy.js';

const retention = { inputHours: 24, replyDays: 7, keepDays: 30 };
const state = (over: Partial<VoicePrivacy> = {}): VoicePrivacy => ({
	consent: false,
	consentAt: null,
	keepAudio: false,
	retention,
	messageCount: 0,
	audioCount: 0,
	...over
});
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

describe('retention texts (contracts/voice.yaml: retention)', () => {
	it('names hours and days in German with singular and plural', () => {
		expect(hoursText(24)).toBe('24 Stunden');
		expect(hoursText(1)).toBe('1 Stunde');
		expect(daysText(7)).toBe('7 Tage');
		expect(daysText(1)).toBe('1 Tag');
	});
	it('derives all three periods from the server values, not from constants', () => {
		expect(retentionTexts(retention)).toEqual({ input: '24 Stunden', reply: '7 Tage', keep: '30 Tage' });
		expect(retentionTexts({ inputHours: 12, replyDays: 1, keepDays: 14 })).toEqual({ input: '12 Stunden', reply: '1 Tag', keep: '14 Tage' });
	});
});

describe('counters and dates', () => {
	it('counts messages and audio files with the right plural', () => {
		expect(messageCountText(0)).toBe('0 Nachrichten');
		expect(messageCountText(1)).toBe('1 Nachricht');
		expect(messageCountText(12)).toBe('12 Nachrichten');
		expect(audioCountText(1)).toBe('1 Audiodatei');
		expect(audioCountText(3)).toBe('3 Audiodateien');
	});
	it('formats the consent date in German, in the given time zone', () => {
		expect(consentDateText('2026-11-24T09:30:00Z', 'Europe/Berlin')).toBe('24.11.2026');
		expect(consentDateText('2026-11-24T23:30:00Z', 'Europe/Berlin')).toBe('25.11.2026');
		expect(consentDateText(null)).toBe('');
		expect(consentDateText('not a date')).toBe('');
	});
	it('says what a delete removed', () => {
		expect(deleteResultText({ deletedMessages: 5, deletedAudio: 1 })).toBe('5 Nachrichten und 1 Audiodatei wurden gelöscht.');
		expect(deleteResultText({ deletedMessages: 0, deletedAudio: 0 })).toBe('Es war nichts zu löschen.');
	});
	it('knows when there is nothing to delete', () => {
		expect(nothingStored(state())).toBe(true);
		expect(nothingStored(state({ messageCount: 2 }))).toBe(false);
		expect(nothingStored(state({ audioCount: 1 }))).toBe(false);
	});
});

describe('keep audio switch', () => {
	it('is only operable with consent, but can always be switched off', () => {
		expect(keepAudioDisabled(state())).toBe(true);
		expect(keepAudioDisabled(state({ consent: true }))).toBe(false);
		expect(keepAudioDisabled(state({ consent: true, keepAudio: true }))).toBe(false);
		// keepAudio without consent cannot happen on the server; if it does, switching off must stay possible.
		expect(keepAudioDisabled(state({ consent: false, keepAudio: true }))).toBe(false);
	});
});

describe('API calls', () => {
	it('loads the state with the session cookie', async () => {
		let sent: { url: string; init?: RequestInit } | undefined;
		const body = state({ consent: true, consentAt: '2026-11-24T09:30:00Z', messageCount: 4, audioCount: 1 });
		const r = await fetchVoicePrivacy(async (url, init) => ((sent = { url, init }), json(body)));
		expect(sent?.url).toBe('/v1/me/voice-privacy');
		expect(sent?.init?.credentials).toBe('same-origin');
		expect(r).toEqual(body);
	});
	it('sends only the changed field with PUT', async () => {
		let sent: { url: string; init?: RequestInit } | undefined;
		const r = await saveVoicePrivacy({ consent: true }, async (url, init) => ((sent = { url, init }), json(state({ consent: true }))));
		expect(sent?.url).toBe('/v1/me/voice-privacy');
		expect(sent?.init?.method).toBe('PUT');
		expect(JSON.parse(String(sent?.init?.body))).toEqual({ consent: true });
		expect(r.consent).toBe(true);
	});
	it('surfaces consent_required as an ApiError with a German text', async () => {
		const failing = async () => json({ error: true, reason: 'consent_required' }, 409);
		await expect(saveVoicePrivacy({ keepAudio: true }, failing)).rejects.toMatchObject({ status: 409, reason: 'consent_required' });
		expect(de['error.consent_required' as keyof typeof de]).toBeTruthy();
	});
	it('maps network failures to ApiError status 0', async () => {
		const down = async () => {
			throw new TypeError('offline');
		};
		await expect(fetchVoicePrivacy(down)).rejects.toMatchObject({ status: 0, reason: 'network' });
		await expect(deleteVoiceHistory(down)).rejects.toBeInstanceOf(ApiError);
	});
	it('deletes the voice history with DELETE and returns the counts', async () => {
		let sent: { url: string; init?: RequestInit } | undefined;
		const r = await deleteVoiceHistory(async (url, init) => ((sent = { url, init }), json({ deletedMessages: 4, deletedAudio: 1 })));
		expect(sent?.url).toBe('/v1/channels/brain/messages');
		expect(sent?.init?.method).toBe('DELETE');
		// The backend refuses every state-changing request without a JSON content type (415 json_required), also without a body.
		expect((sent?.init?.headers as Record<string, string>)['Content-Type']).toBe('application/json');
		expect(r).toEqual({ deletedMessages: 4, deletedAudio: 1 });
	});
});

describe('German texts of the panel', () => {
	it('has every key the panel uses', () => {
		for (const key of [
			'title', 'text', 'consent.label', 'consent.at', 'consent.none', 'periods.title', 'periods.input', 'periods.reply', 'periods.transcripts',
			'keep.label', 'keep.hintNeedsConsent', 'keep.hint', 'count', 'delete.button', 'delete.title', 'delete.text', 'delete.confirm', 'delete.cancel',
			'delete.nothing', 'status.consentOn', 'status.consentOff', 'status.keepOn', 'status.keepOff', 'loadFailed', 'retry'
		]) {
			expect(de[`settings.data.voice.${key}` as keyof typeof de], key).toBeTruthy();
		}
	});
});
