import { expect, test, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { mkdirSync } from 'node:fs';

const PNG_1X1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

// Build status and commit (register_build status/commit, contract session-status 1.2.0) on "Jetzt" and in the card detail.
// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/build-status.spec.ts --project=chromium
// Screenshots go to $BUILD_SHOTS (default docs/screenshots/build-status).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.BUILD_SHOTS ?? '../docs/screenshots/build-status';
const COMMIT = 'abcdef0123456789abcdef0123456789abcdef01';
test.describe.configure({ mode: 'serial' });
let page: Page;
let taskID = '';
const projectName = 'Build-Status Projekt';
const json = { headers: { 'Content-Type': 'application/json' } };
// Set when the backend does not return status itself (older binary): the response is rewritten in the browser instead.
let backendReportsStatus = true;

async function api<T>(method: 'post' | 'put' | 'get', path: string, data?: unknown): Promise<T> {
	const r = await page.request[method](path, method === 'get' ? undefined : { ...json, data });
	expect(r.status(), `${method} ${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'de-DE', timezoneId: 'Europe/Berlin' })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Build Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});

test('seed: builds with and without status are registered', async () => {
	const p = await api<{ id: string }>('post', '/v1/projects', { name: projectName });
	taskID = (await api<{ id: string }>('post', '/v1/tasks', { projectID: p.id, title: 'Release-Build prüfen' })).id;
	for (const [i, extra] of [
		{ label: 'Web 41', status: 'succeeded', commit: COMMIT },
		{ label: 'iOS 42', status: 'building', commit: '1234567890abcdef' },
		{ label: 'Android 43', status: 'failed', commit: 'fedcba9876543210' },
		{ label: 'Alt 40' }
	].entries()) {
		const cap = await seedCapture(taskID, `shot-${i}.png`);
		const r = await page.request.post('/v1/builds', { ...json, data: { attachmentID: cap, buildID: `build-${i}`, platform: 'web', ...extra } });
		expect(r.status(), await r.text()).toBeLessThan(300);
		const body = (await r.json()) as { status?: string };
		if ('status' in extra && body.status !== extra.status) backendReportsStatus = false;
	}
	test.info().annotations.push({ type: 'backend-reports-status', description: String(backendReportsStatus) });
	await page.route('**/v1/overview/now', async (route) => {
		const res = await route.fetch();
		if (backendReportsStatus || res.status() !== 200) return route.fulfill({ response: res });
		const body = await res.json();
		const byLabel: Record<string, string> = { 'Web 41': 'succeeded', 'iOS 42': 'building', 'Android 43': 'failed' };
		for (const pr of body.projects) for (const b of pr.builds) if (b.label in byLabel) b.status = byLabel[b.label];
		await route.fulfill({ response: res, json: body });
	});
});

async function seedCapture(task: string, filename: string): Promise<string> {
	const sha = createHash('sha256').update(PNG_1X1).digest('hex');
	const cap = await api<{ attachmentID: string; uploadURL: string; token: string }>('post', '/v1/attachments/begin', {
		taskID: task, filename, role: 'result', mediaType: 'image/png', size: PNG_1X1.length, checksum: sha
	});
	const status = await page.evaluate(async ({ cap, png }) => {
		const r = await fetch(cap.uploadURL, { method: 'PUT', credentials: 'omit', headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` }, body: new Uint8Array(png) });
		return r.status;
	}, { cap, png: Array.from(PNG_1X1) });
	expect(status).toBeLessThan(300);
	await api('post', `/v1/attachments/${cap.attachmentID}/complete`, {});
	return cap.attachmentID;
}

test('Jetzt shows status badges as text, commit short with full title; no badge without status', async () => {
	await page.goto('/now');
	await page.getByTestId('now-project').locator('summary').click();
	const rows = page.getByTestId('now-build');
	await expect(rows).toHaveCount(4);
	const row = (label: string) => rows.filter({ hasText: label });
	await expect(row('Web 41').getByTestId('build-status')).toHaveText('Erfolgreich');
	await expect(row('iOS 42').getByTestId('build-status')).toHaveText('Baut');
	const failed = row('Android 43').getByTestId('build-status');
	await expect(failed).toHaveText('Fehlgeschlagen');
	await expect(failed.locator('svg')).toHaveCount(1);
	await expect(failed).toHaveClass(/text-red-700/);
	await expect(row('Alt 40').getByTestId('build-status')).toHaveCount(0);
	await expect(row('Web 41').getByTestId('now-build-commit')).toHaveText('abcdef0');
	await expect(row('Web 41').getByTestId('now-build-commit')).toHaveAttribute('title', COMMIT);
	mkdirSync(SHOTS, { recursive: true });
	await page.screenshot({ path: `${SHOTS}/jetzt-build-status-desktop.png`, fullPage: true });
});

test('card detail shows status and short commit at the build screenshot', async () => {
	await page.goto(`/?card=task:${taskID}`);
	const dialog = page.getByRole('dialog');
	await expect(dialog).toHaveAttribute('aria-label', 'Release-Build prüfen');
	const gallery = dialog.getByTestId('card-gallery');
	await expect(gallery).toBeVisible();
	// Thumbnails switch the large view; every build with a status shows it as text.
	const expected: Record<string, [string | null, string | null]> = {
		'Web 41': ['Erfolgreich', 'abcdef0'],
		'iOS 42': ['Baut', '1234567'],
		'Android 43': ['Fehlgeschlagen', 'fedcba9'],
		'Alt 40': [null, null]
	};
	for (const [label, [status, commit]] of Object.entries(expected)) {
		await gallery.getByRole('button', { name: new RegExp(label) }).click();
		if (status) await expect(gallery.getByTestId('build-status')).toHaveText(status);
		else await expect(gallery.getByTestId('build-status')).toHaveCount(0);
		if (commit) await expect(gallery.getByTestId('build-commit')).toHaveText(commit);
		else await expect(gallery.getByTestId('build-commit')).toHaveCount(0);
	}
	await gallery.getByRole('button', { name: /Web 41/ }).click();
	await expect(gallery.getByTestId('build-commit')).toHaveAttribute('title', COMMIT);
	await page.screenshot({ path: `${SHOTS}/kartendetail-build-status-desktop.png` });
});
