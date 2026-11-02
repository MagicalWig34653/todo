import { expect, test, type Page } from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';

// Server settings in the PWA (ADR 0025). Needs a fresh backend database, a local SMTP sink and a backend that has
//   SETTINGS_ENCRYPTION_KEY set, CLEANUP_INTERVAL_MINUTES=0 (the "locked by environment" case) and NO MAIL_*/S3_* variables:
//   python3 web/scripts/smtp-sink.py 2525 $MAIL_SINK_FILE &
//   MAIL_SINK_FILE=... [SMTP_SINK_PORT=2525] [SETTINGS_SHOTS=<dir>] npx playwright test e2e/server-settings.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SINK = process.env.MAIL_SINK_FILE;
const SINK_PORT = process.env.SMTP_SINK_PORT ?? '2525';
const SHOTS = process.env.SETTINGS_SHOTS;
const json = { headers: { 'Content-Type': 'application/json' } };

test.describe.configure({ mode: 'serial' });
let admin: Page;
let member: Page;

type Mail = { to: string[]; subject: string; text: string };
const mails = (): Mail[] => (SINK && existsSync(SINK) ? readFileSync(SINK, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);

async function authenticator(page: Page) {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
}
const shot = async (page: Page, name: string) => {
	if (!SHOTS) return;
	await page.evaluate(() => {
		if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
		window.scrollTo(0, 0);
	});
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: true });
};
async function noOverflow(page: Page, label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}
const field = (page: Page, key: string) => page.getByTestId(`srv-field-${key}`);

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium' || !SINK, 'needs Chromium (virtual authenticator) and MAIL_SINK_FILE');
	admin = await (await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'de-DE' })).newPage();
	await authenticator(admin);
	await admin.goto('/setup');
	await admin.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await admin.getByLabel('Anzeigename').fill('Anna Admin');
	await admin.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(admin.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await admin?.context().close();
	await member?.context().close();
});

test('overview: key present, environment-only values read-only, empty change log', async () => {
	await admin.goto('/settings/admin-server');
	await expect(admin.getByTestId('server-key')).toHaveAttribute('data-configured', 'true');
	const fixed = admin.getByTestId('server-fixed');
	await expect(fixed).toContainText('Datenbank-Verbindung');
	await expect(fixed).toContainText('localhost');
	await expect(admin.getByTestId('server-audit')).toHaveCount(0);
	await shot(admin, 'server-ueberblick');
});

test('mail: dependency errors are explained, then mail is switched on without restart and the test mail arrives', async () => {
	test.setTimeout(90_000);
	await admin.goto('/settings/admin-mail');
	await expect(admin.getByTestId('server-settings-mail')).toBeVisible();
	await expect(field(admin, 'mail.enabled')).toHaveAttribute('data-origin', 'default');
	// Not enabled yet: the test says so.
	await admin.getByTestId('srv-test').click();
	await expect(admin.getByTestId('srv-message')).toHaveAttribute('data-kind', 'error');
	await expect(admin.getByTestId('srv-message')).toContainText('nicht eingeschaltet');

	// Switching on without a server is rejected with a message naming the setting.
	await admin.getByTestId('srv-input-mail.enabled').check();
	await admin.getByTestId('srv-save').click();
	await expect(admin.getByTestId('srv-message')).toHaveAttribute('data-kind', 'error');
	await expect(admin.getByTestId('srv-message')).toContainText('SMTP-Server');
	await expect(field(admin, 'mail.enabled')).toHaveAttribute('data-origin', 'default');

	await admin.getByTestId('srv-input-mail.smtpHost').fill('127.0.0.1');
	await admin.getByTestId('srv-input-mail.smtpSecurity').selectOption('none');
	await admin.getByTestId('srv-input-mail.smtpPort').fill(SINK_PORT);
	await admin.getByTestId('srv-input-mail.from').fill('todolino@example.org');
	await admin.getByTestId('srv-input-mail.fromName').fill('Todolino E2E');
	await admin.getByTestId('srv-save').click();
	await expect(admin.getByTestId('srv-message')).toHaveAttribute('data-kind', 'ok');
	await expect(field(admin, 'mail.enabled')).toHaveAttribute('data-origin', 'db');
	await expect(field(admin, 'mail.smtpHost')).toHaveAttribute('data-origin', 'db');
	await expect(admin.getByTestId('srv-input-mail.enabled')).toBeChecked();

	// Hot reload: the very next test already uses the new configuration.
	const before = mails().length;
	await admin.getByTestId('srv-test-to').fill('empfaenger@example.org');
	await admin.getByTestId('srv-test').click();
	await expect(admin.getByTestId('srv-test-result')).toHaveAttribute('data-ok', 'true');
	await expect(admin.getByTestId('srv-test-result')).toContainText('empfaenger@example.org');
	await expect.poll(() => mails().slice(before).filter((m) => m.to.includes('empfaenger@example.org')).length, { timeout: 15_000 }).toBeGreaterThan(0);
	await shot(admin, 'server-mail');

	// Persisted: a fresh load shows the stored values.
	await admin.reload();
	await expect(admin.getByTestId('srv-input-mail.smtpHost')).toHaveValue('127.0.0.1');
	await expect(admin.getByTestId('srv-input-mail.fromName')).toHaveValue('Todolino E2E');
});

test('secrets: set, shown only as "gesetzt" with fingerprint, never in the page or the API', async () => {
	await admin.goto('/settings/admin-storage');
	await expect(admin.getByTestId('server-no-key')).toHaveCount(0);
	await expect(admin.getByTestId('srv-secret-attachments.s3AccessKey')).toContainText('nicht gesetzt');
	await admin.getByTestId('srv-secret-change-attachments.s3AccessKey').click();
	await admin.getByTestId('srv-input-attachments.s3AccessKey').fill('AKIAE2ESECRETKEY01');
	await admin.getByTestId('srv-secret-change-attachments.s3SecretKey').click();
	await admin.getByTestId('srv-input-attachments.s3SecretKey').fill('e2e-secret-value-9f3a');
	await admin.getByTestId('srv-save').click();
	await expect(admin.getByTestId('srv-message')).toHaveAttribute('data-kind', 'ok');
	await expect(admin.getByTestId('srv-secret-attachments.s3AccessKey')).toContainText('gesetzt');
	await expect(field(admin, 'attachments.s3SecretKey')).toContainText('Fingerabdruck');
	await expect(admin.locator('body')).not.toContainText('AKIAE2ESECRETKEY01');
	await expect(admin.locator('body')).not.toContainText('e2e-secret-value-9f3a');
	const raw = await (await admin.request.get('/v1/admin/settings')).text();
	expect(raw).not.toContain('AKIAE2ESECRETKEY01');
	expect(raw).not.toContain('e2e-secret-value-9f3a');
	// Storage test: database storage is in use, so only the database is checked.
	await admin.getByTestId('srv-test').click();
	await expect(admin.getByTestId('srv-test-result')).toHaveAttribute('data-ok', 'true');
	await shot(admin, 'server-speicher');
});

test('environment wins: a variable locks the setting; restart-only settings are marked; reset returns to the default', async () => {
	await admin.goto('/settings/admin-cleanup');
	const locked = field(admin, 'maintenance.cleanupIntervalMinutes');
	await expect(locked).toHaveAttribute('data-locked', 'true');
	await expect(locked).toHaveAttribute('data-origin', 'env');
	await expect(admin.getByTestId('srv-input-maintenance.cleanupIntervalMinutes')).toHaveCount(0);
	await expect(admin.getByTestId('srv-locked-maintenance.cleanupIntervalMinutes')).toContainText('CLEANUP_INTERVAL_MINUTES');
	await expect(admin.getByTestId('srv-locked-maintenance.cleanupIntervalMinutes')).toContainText('nicht änderbar');
	const api = await admin.request.put('/v1/admin/settings/maintenance.cleanupIntervalMinutes', { ...json, data: { value: 5, version: 0 } });
	expect(api.status()).toBe(409);
	expect((await api.json()).reason).toBe('setting_locked');

	await expect(admin.getByTestId('srv-restart-maintenance.syncRetentionDays')).toContainText('wirkt nach Neustart');
	await admin.getByTestId('srv-input-maintenance.syncRetentionDays').fill('99999');
	await expect(admin.getByTestId('srv-hint-maintenance.syncRetentionDays')).toContainText('Höchstens 3650');
	await admin.getByTestId('srv-input-maintenance.syncRetentionDays').fill('30');
	await admin.getByTestId('srv-save').click();
	await expect(admin.getByTestId('srv-message')).toHaveAttribute('data-kind', 'ok');
	await expect(field(admin, 'maintenance.syncRetentionDays')).toHaveAttribute('data-origin', 'db');
	await admin.getByTestId('srv-reset-maintenance.syncRetentionDays').click();
	await expect(field(admin, 'maintenance.syncRetentionDays')).toHaveAttribute('data-origin', 'default');
	await expect(admin.getByTestId('srv-input-maintenance.syncRetentionDays')).toHaveValue('90');
	await shot(admin, 'server-aufraeumen');
});

test('conflict: a change by someone else is reported instead of overwritten', async () => {
	await admin.goto('/settings/admin-limits');
	await expect(admin.getByTestId('srv-input-limits.loginLimit')).toHaveValue('60');
	// Another admin session saves first.
	const other = await admin.request.put('/v1/admin/settings/limits.loginLimit', { ...json, data: { value: 70, version: 0 } });
	expect(other.status()).toBe(200);
	await admin.getByTestId('srv-input-limits.loginLimit').fill('80');
	await admin.getByTestId('srv-save').click();
	await expect(admin.getByTestId('srv-message')).toHaveAttribute('data-kind', 'conflict');
	await expect(admin.getByTestId('srv-input-limits.loginLimit')).toHaveValue('70');
	// With the fresh version the change goes through.
	await admin.getByTestId('srv-input-limits.loginLimit').fill('80');
	await admin.getByTestId('srv-save').click();
	await expect(admin.getByTestId('srv-message')).toHaveAttribute('data-kind', 'ok');
	await expect(admin.getByTestId('srv-input-limits.loginLimit')).toHaveValue('80');
});

test('change log lists who changed what, without values', async () => {
	await admin.goto('/settings/admin-server');
	const rows = admin.getByTestId('server-audit-row');
	await expect(rows.first()).toBeVisible();
	await expect(admin.getByTestId('server-audit')).toContainText('Anna Admin');
	await expect(admin.locator('[data-testid="server-audit-row"][data-key="mail.smtpHost"]')).toHaveCount(1);
	await expect(admin.locator('[data-testid="server-audit-row"][data-key="test.mail"]')).toHaveCount(1);
	await expect(admin.getByTestId('server-audit')).not.toContainText('127.0.0.1');
	await expect(admin.getByTestId('server-audit')).not.toContainText('e2e-secret-value-9f3a');
	await shot(admin, 'server-protokoll');
});

test('a non-admin does not see the area and the API refuses', async ({ browser }) => {
	const invite = await admin.request.post('/v1/invitations', json);
	const { token } = await invite.json();
	member = await (await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: 'de-DE' })).newPage();
	await authenticator(member);
	await member.goto(`/setup?token=${token}`);
	await member.getByLabel('Anzeigename').fill('Max Mitglied');
	await member.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(member.getByTestId('account-menu')).toBeVisible();
	await member.goto('/settings');
	await expect(member.getByTestId('settings-hub')).toBeVisible();
	await expect(member.getByTestId('settings-group-admin')).toHaveCount(0);
	await expect(member.getByTestId('settings-link-verwaltung-mail')).toHaveCount(0);
	await member.goto('/settings/admin-mail');
	await expect(member.getByTestId('admin-denied')).toBeVisible();
	await expect(member.getByTestId('server-settings-mail')).toHaveCount(0);
	expect((await member.request.get('/v1/admin/settings')).status()).toBe(403);
	expect((await member.request.put('/v1/admin/settings/limits.loginLimit', { ...json, data: { value: 5, version: 0 } })).status()).toBe(403);
});

test('mobile: the form fits the screen', async () => {
	await admin.setViewportSize({ width: 390, height: 844 });
	await admin.goto('/settings/admin-mail');
	await expect(admin.getByTestId('server-settings-mail')).toBeVisible();
	await noOverflow(admin, 'verwaltung-mail');
	await shot(admin, 'server-mail-mobil');
	await admin.goto('/settings/admin-storage');
	await expect(admin.getByTestId('server-settings-attachments')).toBeVisible();
	await noOverflow(admin, 'verwaltung-speicher');
	await admin.goto('/settings/admin-server');
	await expect(admin.getByTestId('server-overview')).toBeVisible();
	await noOverflow(admin, 'verwaltung-server');
	await admin.setViewportSize({ width: 1280, height: 900 });
});
