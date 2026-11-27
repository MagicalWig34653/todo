import { expect, test } from '@playwright/test';

// Card A1A4690B: quick page changes must not make /v1/sync/wait answer 429 (limit of 8 waiting requests per account).
// Every full page load aborts the browser's pending long poll; the server kept each abandoned request as a waiter for up to
// 25 s, so the ninth page load in a row was refused. Needs a fresh backend database with BOOTSTRAP_TOKEN, real HTTP, no stubs:
//   E2E_BASE_URL=... npx playwright test e2e/live-wait-reload.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

test('twelve quick page loads in a row never get 429 on /v1/sync/wait', async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	test.setTimeout(120_000);
	const ctx = await browser.newContext();
	const page = await ctx.newPage();
	const cdp = await ctx.newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Reload Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();

	const statuses: number[] = [];
	page.on('response', (res) => {
		if (res.url().includes('/v1/sync/wait')) statuses.push(res.status());
	});

	let waitsStarted = 0;
	for (let i = 0; i < 12; i++) {
		const started = page.waitForRequest((r) => r.url().includes('/v1/sync/wait'), { timeout: 10_000 });
		await page.reload();
		await started; // the page has opened its long poll; the next load aborts it
		waitsStarted++;
		// The server registers the request right after it arrives; give it a moment so every load really leaves a waiter behind.
		await page.waitForTimeout(150);
	}
	expect(waitsStarted).toBe(12);
	expect(statuses.filter((s) => s === 429), `statuses: ${statuses.join(',')}`).toEqual([]);
	await ctx.close();
});
