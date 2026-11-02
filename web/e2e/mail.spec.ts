import { expect, test, type Page } from '@playwright/test';
import { readFileSync, existsSync } from 'node:fs';

// Needs a fresh backend database and a local SMTP sink (web/scripts/smtp-sink.py). Run on its own:
//   python3 web/scripts/smtp-sink.py 2525 $MAIL_SINK_FILE &
//   MAIL_ENABLED=true SMTP_HOST=127.0.0.1 SMTP_PORT=2525 SMTP_SECURITY=none MAIL_FROM=todolino@example.org \
//   APNS_ENABLED=true APNS_KEY_ID=ABCDE12345 APNS_TEAM_ID=TEAMID1234 APNS_KEY_FILE=<any P-256 .p8> ... (backend)
//   MAIL_SINK_FILE=... npx playwright test e2e/mail.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SINK = process.env.MAIL_SINK_FILE;
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

type Mail = { to: string[]; subject: string; text: string };
const mails = (): Mail[] =>
	SINK && existsSync(SINK)
		? readFileSync(SINK, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
		: [];
async function nextMail(subject: string, after: number): Promise<Mail> {
	await expect.poll(() => mails().slice(after).filter((m) => m.subject === subject).length, { timeout: 40_000 }).toBeGreaterThan(0);
	return mails().slice(after).filter((m) => m.subject === subject)[0];
}

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium' || !SINK, 'needs Chromium (virtual authenticator) and MAIL_SINK_FILE');
	page = await (await browser.newContext()).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Mail Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

test('notifications card: push status, test button and result per device', async () => {
	test.setTimeout(90_000);
	await page.setViewportSize({ width: 1280, height: 900 });
	await page.goto('/settings/notifications');
	const card = page.getByTestId('notify-settings');
	await expect(card).toBeVisible();
	await expect(card.getByTestId('notify-server')).toHaveAttribute('data-enabled', 'true');
	await expect(card.getByTestId('notify-no-devices')).toBeVisible();

	// Preferences are stored on the server.
	const reminders = card.getByTestId('pref-reminders');
	await expect(reminders).toBeChecked();
	await reminders.uncheck();
	await page.reload();
	await expect(page.getByTestId('pref-reminders')).not.toBeChecked();
	await page.getByTestId('pref-reminders').check();

	// No device yet: nothing is sent and the card says so.
	await page.getByTestId('push-test').click();
	await expect(page.getByTestId('push-test-result')).toContainText('Kein Gerät registriert');

	const reg = await page.request.post('/v1/push/devices', {
		...json,
		data: { token: 'ab'.repeat(32), platform: 'ios', environment: 'sandbox', bundleId: 'de.linolaske.todo', appVersion: '1.0' }
	});
	expect(reg.status()).toBe(201);
	await page.goto('/settings/notifications');
	await expect(page.getByTestId('notify-device')).toHaveCount(1);
	await expect(page.getByTestId('notify-device')).not.toContainText('abab');
	await page.waitForTimeout(10_500); // rate limit: one test per 10 s
	await page.getByTestId('push-test').click();
	// Apple is not reachable with a fake key: the device is reported as failed, never with its token.
	await expect(page.getByTestId('push-test-device')).toHaveAttribute('data-result', /failed|revoked/, { timeout: 40_000 });
	await expect(page.getByTestId('push-test-result')).not.toContainText('abab');
	await page.screenshot({ path: 'screenshots/notify-card.png', fullPage: true });

	await page.getByRole('button', { name: /Gerät iPhone\/iPad entfernen/ }).click();
	await page.getByRole('button', { name: 'Gerät entfernen', exact: true }).last().click();
	await expect(page.getByTestId('notify-device')).toHaveCount(0);
});

test('email: double opt-in, test mail, recovery mail with link', async () => {
	test.setTimeout(150_000); // the mail worker runs every few seconds
	await page.goto('/settings/email');
	const card = page.getByTestId('email-settings');
	await expect(card.getByTestId('email-server')).toHaveAttribute('data-enabled', 'true');
	let seen = mails().length;
	await card.getByTestId('email-input').fill('Tester@Example.org');
	await card.getByTestId('email-save').click();
	await expect(card.getByTestId('email-info')).toContainText('Bestätigungsmail');
	await expect(card.getByTestId('email-pending')).toContainText('tester@example.org');
	const verify = await nextMail('Todolino: E-Mail-Adresse bestätigen', seen);
	expect(verify.to).toEqual(['tester@example.org']);
	const link = verify.text.match(/https?:\/\/\S+\/confirm-email#token=\S+/)![0];
	expect(verify.text).not.toContain('Feedaufgabe');

	// Not confirmed yet: no active address.
	await expect(card.getByTestId('email-current')).toHaveCount(0);
	const url = new URL(link);
	await page.goto(url.pathname + url.hash);
	await expect(page.getByTestId('confirm-email-done')).toBeVisible();
	expect(page.url()).not.toContain('token=');
	await page.goto('/settings/email');
	await expect(page.getByTestId('email-current')).toHaveText('tester@example.org');

	// Link is single-use.
	await page.goto(url.pathname + url.hash);
	await expect(page.getByTestId('confirm-email-error')).toContainText('ungültig');

	await page.goto('/settings/email');
	seen = mails().length;
	await page.getByTestId('email-test').click();
	await expect(page.getByTestId('email-info')).toContainText('Test-Mail');
	const test1 = await nextMail('Todolino: Test-Mail', seen);
	expect(test1.to).toEqual(['tester@example.org']);
	await expect(page.getByTestId('email-last')).toBeVisible();
	await page.screenshot({ path: 'screenshots/email-card.png', fullPage: true });

	// Admin issues a recovery code and sends it by mail.
	await page.goto('/settings/admin-accounts');
	const me = await (await page.request.get('/v1/me')).json();
	seen = mails().length;
	await page.getByTestId('recovery-issue').getByPlaceholder('Konto-ID').fill(me.id);
	await page.getByTestId('recovery-send-email').check();
	await page.getByTestId('recovery-issue').getByRole('button', { name: 'Code ausstellen' }).click();
	await expect(page.getByTestId('recovery-mail-status')).toContainText('per E-Mail');
	const code = (await page.getByTestId('recovery-code').textContent())!.trim();
	const rec = await nextMail('Todolino: Recovery-Code', seen);
	expect(rec.to).toEqual(['tester@example.org']);
	expect(rec.text).toContain(code);
	expect(rec.text).toContain('kein sicherer Kanal');
	const recLink = new URL(rec.text.match(/https?:\/\/\S+\/recover#code=\S+/)![0]);
	await page.goto(recLink.pathname + recLink.hash);
	await expect(page.getByLabel('Recovery-Code')).toHaveValue(code);
});

test('mobile: cards fit at 390 px without horizontal scroll', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/settings/notifications');
	await expect(page.getByTestId('notify-settings')).toBeVisible();
	const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
	expect(overflow).toBeLessThanOrEqual(0);
	await page.screenshot({ path: 'screenshots/notify-mobile.png', fullPage: true });
});
