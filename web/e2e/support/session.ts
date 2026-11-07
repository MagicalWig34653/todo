import { chromium, expect, test, type Browser, type Page } from '@playwright/test';

const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const VIRTUAL_AUTHENTICATOR = {
	protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true
};

/**
 * Registers the first account (bootstrap) through the real passkey UI and returns a signed-in page.
 *
 * Firefox and WebKit have no virtual authenticator, so the account is created in a throwaway Chromium (CDP virtual
 * authenticator) and its session cookies are handed to a context of the browser under test. Everything after the sign-in
 * (UI, API calls, uploads) then runs in the browser the project selected, with the project's emulation options.
 * The passkey ceremony itself is therefore NOT exercised in Firefox/WebKit.
 */
export async function signedInPage(browser: Browser, displayName: string): Promise<Page> {
	const baseURL = test.info().project.use.baseURL;
	if (browser.browserType().name() === 'chromium') {
		const page = await (await browser.newContext()).newPage();
		await addAuthenticator(page);
		await register(page, displayName);
		return page;
	}
	const helper = await chromium.launch();
	try {
		const ctx = await helper.newContext({ baseURL });
		const page = await ctx.newPage();
		await addAuthenticator(page);
		await register(page, displayName);
		const state = await ctx.storageState();
		const own = await (await browser.newContext({ storageState: state })).newPage();
		await own.goto('/');
		await expect(own.getByTestId('account-menu')).toBeVisible();
		return own;
	} finally {
		await helper.close();
	}
}

async function addAuthenticator(page: Page) {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', { options: VIRTUAL_AUTHENTICATOR });
}

async function register(page: Page, displayName: string) {
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill(displayName);
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
}
