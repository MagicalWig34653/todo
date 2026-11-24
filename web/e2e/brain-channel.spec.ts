import { expect, test, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { signedInPage } from './support/session';

// Card T1-8 (ADR 0030): the PWA reads the own channel #brain: text, voice messages with playback and visible transcript,
// status messages, empty state, keyboard use. Needs a fresh backend database (bootstrap happens here). Run on its own, any project:
//   E2E_BASE_URL=... npx playwright test e2e/brain-channel.spec.ts --project=webkit
// Screenshots (light and dark) go to E2E_SHOTS (default: brain-channel in the system temp dir).
const SHOTS = process.env.E2E_SHOTS ?? join(tmpdir(), 'brain-channel');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

/** A 2 s mono 16-bit 8 kHz WAV with a quiet 440 Hz tone: valid container, long enough to still be playing after a click. */
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
	const data = wav(2);
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
const noOverflow = async () => expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Brain Tester');
});
test.afterAll(async () => {
	await page?.context().close();
});

test('empty channel: reachable from the sidebar, friendly empty state', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	const nav = page.locator('#main-nav:visible');
	await page.getByRole('button', { name: 'Mehr', exact: true }).first().click();
	await nav.getByRole('button', { name: 'Brain', exact: true }).click();
	await expect(page).toHaveURL(/\/brain$/);
	await expect(page.getByTestId('view-heading')).toHaveText('Brain');
	await expect(page.getByTestId('brain-empty')).toBeVisible();
	await expect(page.getByTestId('brain-message')).toHaveCount(0);
	await noOverflow();
});

test('messages: text, voice message with visible transcript, automatic status, oldest first', async () => {
	await postMessage({ kind: 'text', text: 'Hallo Brain, bist du da?', clientUUID: crypto.randomUUID() });
	const attachmentID = await uploadVoice();
	// No runner device: the server answers a voice_in itself with a status message ("nur per Text erreichbar").
	await postMessage({ kind: 'voice_in', attachmentID, text: 'Das ist mein Transkript.', clientUUID: crypto.randomUUID() });
	await page.goto('/brain');
	const rows = page.getByTestId('brain-message');
	await expect(rows).toHaveCount(3);
	await expect(rows.nth(0)).toHaveAttribute('data-kind', 'text');
	await expect(rows.nth(0)).toContainText('Hallo Brain, bist du da?');
	await expect(rows.nth(1)).toHaveAttribute('data-kind', 'voice_in');
	await expect(rows.nth(1).getByTestId('brain-transcript')).toHaveText('Das ist mein Transkript.');
	await expect(rows.nth(1).getByTestId('brain-play')).toBeVisible();
	await expect(rows.nth(2)).toHaveAttribute('data-kind', 'status');
	await expect(rows.nth(2)).toContainText('nur per Text erreichbar');
	await expect(rows.nth(0).getByTestId('brain-play')).toHaveCount(0);
	await noOverflow();
});

test('playback is operated with the keyboard and the audio element really plays', async () => {
	await page.goto('/brain');
	const voice = page.getByTestId('brain-message').nth(1);
	const play = voice.getByTestId('brain-play');
	const audio = voice.locator('audio');
	await expect(play).toHaveAccessibleName(/abspielen/i);
	await expect(play).toHaveAttribute('data-playing', 'false');
	await play.focus();
	await page.keyboard.press('Enter');
	await expect(play).toHaveAttribute('data-playing', 'true');
	await expect(play).toHaveAccessibleName(/pausieren/i);
	await expect.poll(() => audio.evaluate((a: HTMLAudioElement) => !a.paused && a.currentTime > 0)).toBe(true);
	await page.keyboard.press('Space');
	await expect(play).toHaveAttribute('data-playing', 'false');
	await expect.poll(() => audio.evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);
	// The recording is served by the real download route with the session (no signed link in the page).
	const src = await audio.getAttribute('src');
	expect(src).toMatch(/^\/v1\/attachments\/[0-9A-Fa-f-]{36}\/download$/);
	const r = await page.request.get(src!);
	expect(r.status()).toBe(200);
});

test('narrow viewport and both colour schemes: no overflow, screenshots for the review', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/brain');
	await expect(page.getByTestId('brain-message')).toHaveCount(3);
	await noOverflow();
	const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
	const shoot = async (scheme: 'light' | 'dark', name: string) => {
		await page.emulateMedia({ colorScheme: scheme });
		await expect(page.getByTestId('brain-view')).toBeVisible();
		// Colour transitions must be finished: the background settles and stays the same.
		let last = '';
		await expect.poll(async () => { const now = await bg(); const same = now === last; last = now; return same; }, { intervals: [250, 250, 250] }).toBe(true);
		await page.screenshot({ path: join(SHOTS, name) });
		return bg();
	};
	const light = await shoot('light', 'brain-light-390.png');
	const dark = await shoot('dark', 'brain-dark-390.png');
	expect(dark, 'dark scheme really changes the page background').not.toBe(light);
	await page.setViewportSize({ width: 1280, height: 800 });
	await shoot('light', 'brain-light-1280.png');
	await shoot('dark', 'brain-dark-1280.png');
});

test('older pages load on demand (50 per page)', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	for (let i = 0; i < 52; i++) await postMessage({ kind: 'text', text: `Verlauf ${i}`, clientUUID: crypto.randomUUID() });
	await page.goto('/brain');
	const rows = page.getByTestId('brain-message');
	await expect(rows).toHaveCount(50);
	// Newest at the bottom, the page ends at the oldest message already loaded.
	await expect(rows.last()).toContainText('Verlauf 51');
	await page.getByTestId('brain-load-older').click();
	await expect(rows).toHaveCount(55);
	await expect(rows.first()).toContainText('Hallo Brain');
	await expect(page.getByTestId('brain-load-older')).toHaveCount(0);
});
