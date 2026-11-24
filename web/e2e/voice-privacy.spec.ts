import { expect, test, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { signedInPage } from './support/session';

// Card T1-7 (privacy of voice messages): Settings -> Daten & Datenschutz -> "Sprachnachrichten (Kanal #brain)": consent, periods,
// keep audio, counters, export, delete the voice history. Needs a fresh backend database (bootstrap happens here). Run on its own:
//   E2E_BASE_URL=... npx playwright test e2e/voice-privacy.spec.ts --project=chromium
// Screenshots (light and dark, 1280/390/320 px) go to E2E_SHOTS (default: voice-privacy in the system temp dir).
const SHOTS = process.env.E2E_SHOTS ?? join(tmpdir(), 'voice-privacy');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const TEXT_A = 'Datenschutz Seed eins';
const TEXT_B = 'Datenschutz Seed zwei';
const TRANSCRIPT = 'Datenschutz Transkript.';

/** A 1 s mono 16-bit 8 kHz WAV: valid container, small. */
function wav(seconds: number): Buffer {
	const rate = 8000;
	const n = rate * seconds;
	const buf = Buffer.alloc(44 + n * 2);
	buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write('WAVE', 8); buf.write('fmt ', 12);
	buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22); buf.writeUInt32LE(rate, 24);
	buf.writeUInt32LE(rate * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(n * 2, 40);
	for (let i = 0; i < n; i++) buf.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 2000), 44 + i * 2);
	return buf;
}

async function postMessage(body: Record<string, unknown>) {
	const r = await page.request.post('/v1/channels/brain/messages', { ...json, data: body });
	expect(r.status(), await r.text()).toBeLessThan(300);
	return r.json();
}
async function uploadVoice(): Promise<string> {
	const data = wav(1);
	const begin = await page.request.post('/v1/attachments/begin', {
		...json, data: { filename: 'memo.wav', role: 'voice', mediaType: 'audio/wav', size: data.length, checksum: createHash('sha256').update(data).digest('hex') }
	});
	expect(begin.status(), await begin.text()).toBeLessThan(300);
	const cap = (await begin.json()) as { attachmentID: string; uploadURL: string; token: string };
	const status = await page.evaluate(
		async ({ cap, bytes }) => (await fetch(cap.uploadURL, { method: 'PUT', credentials: 'omit', headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` }, body: new Uint8Array(bytes) })).status,
		{ cap, bytes: Array.from(data) }
	);
	expect(status).toBeLessThan(300);
	const done = await page.request.post(`/v1/attachments/${cap.attachmentID}/complete`, json);
	expect(done.status(), await done.text()).toBeLessThan(300);
	return cap.attachmentID;
}
type Privacy = { consent: boolean; consentAt: string | null; keepAudio: boolean; retention: { inputHours: number; replyDays: number; keepDays: number }; messageCount: number; audioCount: number };
async function serverState(): Promise<Privacy> {
	const r = await page.request.get('/v1/me/voice-privacy');
	expect(r.status(), await r.text()).toBe(200);
	return r.json();
}
const noOverflow = async () => expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
const consent = () => page.getByTestId('voice-consent');
const keepAudio = () => page.getByTestId('voice-keep-audio');

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Privacy Tester');
});
test.afterAll(async () => {
	await page?.context().close();
});

test('periods and counters are visible, nothing is consented yet', async () => {
	await postMessage({ kind: 'text', text: TEXT_A, clientUUID: crypto.randomUUID() });
	await postMessage({ kind: 'text', text: TEXT_B, clientUUID: crypto.randomUUID() });
	const attachmentID = await uploadVoice();
	// No runner device: the server answers a voice_in with a status message itself, so the counter is read from the server, not hard-coded.
	await postMessage({ kind: 'voice_in', attachmentID, text: TRANSCRIPT, clientUUID: crypto.randomUUID() });
	const s = await serverState();
	expect(s.messageCount).toBeGreaterThanOrEqual(3);
	expect(s.audioCount).toBe(1);

	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/settings/data');
	const panel = page.getByTestId('voice-privacy');
	await expect(panel).toBeVisible();
	await expect(page.getByRole('heading', { name: 'Sprachnachrichten (Kanal #brain)' })).toBeVisible();
	const periods = page.getByTestId('voice-periods');
	await expect(periods).toContainText('24 Stunden');
	await expect(periods).toContainText('7 Tage');
	await expect(periods).toContainText('bis du den Sprachverlauf löschst');
	await expect(page.getByTestId('voice-count')).toHaveAttribute('data-messages', String(s.messageCount));
	await expect(page.getByTestId('voice-count')).toHaveAttribute('data-audio', '1');
	await expect(page.getByTestId('voice-count-messages')).toHaveText(new RegExp(`^${s.messageCount} Nachrichten$`));
	await expect(page.getByTestId('voice-count-audio')).toHaveText('1 Audiodatei');
	// Without consent: the switch is not operable and says why; the date line says there is no consent yet.
	await expect(consent()).not.toBeChecked();
	await expect(keepAudio()).toBeDisabled();
	await expect(page.getByTestId('voice-keep-hint')).toContainText('Einwilligung');
	await expect(page.getByTestId('voice-consent-at')).toContainText('Noch keine Einwilligung');
	await noOverflow();
});

test('consent, keep audio (only with consent), withdrawal switches it off again, state survives a reload', async () => {
	await page.goto('/settings/data');
	await expect(consent()).toBeVisible();
	await expect(consent()).toHaveAccessibleName(/Ich willige ein, dass meine Sprachnachrichten zur Verarbeitung gespeichert werden/);
	await expect(keepAudio()).toHaveAccessibleName(/Audio behalten \(bis zu 30 Tage\)/);

	await consent().check();
	await expect(page.getByTestId('voice-status')).toContainText('Einwilligung gespeichert');
	await expect(page.getByTestId('voice-consent-at')).toContainText('Einwilligung erteilt am');
	await expect(keepAudio()).toBeEnabled();
	await keepAudio().check();
	await expect(page.getByTestId('voice-status')).toContainText('Audio wird behalten');
	expect((await serverState()).keepAudio).toBe(true);

	// Withdrawal: the server also switches keep audio off; the UI follows and disables the switch again.
	await consent().uncheck();
	await expect(page.getByTestId('voice-status')).toContainText('Einwilligung zurückgenommen');
	await expect(keepAudio()).not.toBeChecked();
	await expect(keepAudio()).toBeDisabled();
	let s = await serverState();
	expect([s.consent, s.keepAudio]).toEqual([false, false]);
	await page.reload();
	await expect(consent()).not.toBeChecked();
	await expect(keepAudio()).not.toBeChecked();
	await expect(keepAudio()).toBeDisabled();

	// Back to consent + keep audio for the following tests; the state must survive a reload.
	await consent().check();
	await expect(keepAudio()).toBeEnabled();
	await keepAudio().check();
	await expect(page.getByTestId('voice-status')).toContainText('Audio wird behalten');
	await page.reload();
	await expect(consent()).toBeChecked();
	await expect(keepAudio()).toBeChecked();
	await expect(page.getByTestId('voice-consent-at')).toContainText('Einwilligung erteilt am');
	s = await serverState();
	expect([s.consent, s.keepAudio]).toEqual([true, true]);
	expect(s.consentAt).toBeTruthy();
});

test('keyboard: the consent checkbox is reachable and operable without a mouse', async () => {
	await page.goto('/settings/data');
	await consent().focus();
	await expect(consent()).toBeFocused();
	await page.keyboard.press('Space');
	await expect(consent()).not.toBeChecked();
	await expect(keepAudio()).toBeDisabled();
	await page.keyboard.press('Space');
	await expect(consent()).toBeChecked();
	// The consent is saved first; "keep audio" becomes operable only afterwards.
	await expect(keepAudio()).toBeEnabled();
	await keepAudio().focus();
	await page.keyboard.press('Space');
	await expect(keepAudio()).toBeChecked();
});

test('export contains the channel messages and the voice privacy state', async () => {
	await page.goto('/settings/data');
	const [download] = await Promise.all([page.waitForEvent('download'), page.getByTestId('data-export').click()]);
	expect(download.suggestedFilename()).toMatch(/^todolino-export-\d{4}-\d{2}-\d{2}\.json$/);
	const data = JSON.parse(readFileSync(await download.path(), 'utf8')) as {
		channelMessages: { text?: string | null; hasAudio?: boolean }[];
		voicePrivacy: { consent: boolean; consentAt: string | null; keepAudio: boolean };
	};
	const texts = data.channelMessages.map((m) => m.text);
	expect(texts).toContain(TEXT_A);
	expect(texts).toContain(TEXT_B);
	expect(texts).toContain(TRANSCRIPT);
	expect(data.channelMessages.some((m) => m.hasAudio === true)).toBe(true);
	expect(data.voicePrivacy.consent).toBe(true);
	expect(data.voicePrivacy.keepAudio).toBe(true);
	expect(data.voicePrivacy.consentAt).toBeTruthy();
	await expect(page.getByTestId('data-export-done')).toBeVisible();
});

test('screenshots light and dark (1280, 390, 320, 320 at 200 % text) without overflow', async () => {
	const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
	const shoot = async (scheme: 'light' | 'dark', name: string) => {
		await page.emulateMedia({ colorScheme: scheme });
		await expect(page.getByTestId('voice-privacy')).toBeVisible();
		// Colour transitions must be finished: the background settles and stays the same.
		let last = '';
		await expect.poll(async () => { const now = await bg(); const same = now === last; last = now; return same; }, { intervals: [250, 250, 250] }).toBe(true);
		await page.screenshot({ path: join(SHOTS, name), fullPage: true });
		return bg();
	};
	for (const width of [1280, 390, 320]) {
		await page.setViewportSize({ width, height: width === 1280 ? 1000 : 844 });
		await page.goto('/settings/data');
		await expect(page.getByTestId('voice-count')).toBeVisible();
		await noOverflow();
		const light = await shoot('light', `voice-privacy-light-${width}.png`);
		const dark = await shoot('dark', `voice-privacy-dark-${width}.png`);
		expect(dark, 'dark scheme really changes the page background').not.toBe(light);
	}
	// 200 % text on the narrowest phone.
	await page.setViewportSize({ width: 320, height: 844 });
	await page.goto('/settings/data');
	await page.addStyleTag({ content: 'html { font-size: 200% !important; }' });
	await expect(page.getByTestId('voice-privacy')).toBeVisible();
	await noOverflow();
	await shoot('light', 'voice-privacy-light-320-200.png');
	await shoot('dark', 'voice-privacy-dark-320-200.png');
	// The confirmation dialog, narrow, both schemes.
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/settings/data');
	await page.getByTestId('voice-delete-start').click();
	await expect(page.getByTestId('voice-delete-dialog')).toBeVisible();
	await noOverflow();
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await page.waitForTimeout(400);
		await page.screenshot({ path: join(SHOTS, `voice-privacy-dialog-${scheme}-390.png`) });
	}
	await page.getByTestId('voice-delete-cancel').click();
	await expect(page.getByTestId('voice-delete-dialog')).toHaveCount(0);
	// Cancel deletes nothing.
	expect((await serverState()).messageCount).toBeGreaterThanOrEqual(3);
});

test('delete the voice history through the dialog: counters 0, #brain empty, settings stay', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/settings/data');
	const start = page.getByTestId('voice-delete-start');
	await expect(start).toBeEnabled();
	await start.click();
	const dialog = page.getByTestId('voice-delete-dialog');
	await expect(dialog).toBeVisible();
	await expect(dialog).toContainText('unwiderruflich');
	await expect(dialog).toContainText('Export');
	// Focus moved into the dialog; Escape closes it and focus returns to the button.
	await expect(dialog.locator(':focus')).toHaveCount(1);
	await page.keyboard.press('Escape');
	await expect(dialog).toHaveCount(0);
	await expect(start).toBeFocused();

	await start.click();
	await page.getByTestId('voice-delete-confirm').click();
	await expect(dialog).toHaveCount(0);
	await expect(page.getByTestId('voice-status')).toContainText('gelöscht');
	await expect(page.getByTestId('voice-count')).toHaveAttribute('data-messages', '0');
	await expect(page.getByTestId('voice-count')).toHaveAttribute('data-audio', '0');
	await expect(start).toBeDisabled();
	const s = await serverState();
	expect([s.messageCount, s.audioCount]).toEqual([0, 0]);

	// The settings stay (consent and keep audio), also after a reload.
	await page.reload();
	await expect(consent()).toBeChecked();
	await expect(keepAudio()).toBeChecked();
	expect([s.consent, s.keepAudio]).toEqual([true, true]);

	// The channel #brain shows the empty state.
	await page.goto('/brain');
	await expect(page.getByTestId('brain-empty')).toBeVisible();
	await expect(page.getByTestId('brain-message')).toHaveCount(0);
});
