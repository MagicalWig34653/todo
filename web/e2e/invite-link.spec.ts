import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   E2E_BASE_URL=... npx playwright test e2e/invite-link.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

async function virtualAuthenticator(page: Page) {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
}

test('invitation link prefills the code, strips it from the URL and registers; reuse shows a German message', async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	const adminCtx = await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: 'de-DE' });
	const admin = await adminCtx.newPage();
	await virtualAuthenticator(admin);
	await admin.goto('/setup');
	await admin.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await admin.getByLabel('Anzeigename').fill('Anna Admin');
	await admin.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(admin.getByTestId('account-menu')).toBeVisible();

	// Admin UI shows the link; the code is in the fragment, not in the query.
	await admin.goto('/settings/admin-invitations');
	await admin.getByTestId('invite-create').click();
	const code = ((await admin.getByTestId('invite-code').textContent()) ?? '').trim();
	const link = ((await admin.getByTestId('invite-link').textContent()) ?? '').trim();
	expect(link).toContain('/setup#code=');
	expect(new URL(link).search).toBe('');
	expect(new URL(link).hash).toContain(encodeURIComponent(code));

	// Open the link as a guest: code prefilled, removed from the address bar.
	const guestCtx = await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: 'de-DE' });
	const guest = await guestCtx.newPage();
	await virtualAuthenticator(guest);
	await guest.goto(link);
	await expect(guest.getByTestId('setup-code-prefilled')).toBeVisible();
	await expect(guest.getByLabel('Einrichtungs- oder Einladungscode')).toHaveValue(code);
	expect(guest.url()).not.toContain(code);
	await guest.getByLabel('Anzeigename').fill('Gabi Gast');
	await guest.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(guest.getByTestId('account-menu')).toBeVisible();

	// The used code shows a friendly message.
	const again = await (await browser.newContext({ locale: 'de-DE' })).newPage();
	await virtualAuthenticator(again);
	await again.goto(link);
	await again.getByLabel('Anzeigename').fill('Zweite Person');
	await again.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(again.getByRole('alert')).toContainText('ungültig, abgelaufen oder bereits verwendet');
});
