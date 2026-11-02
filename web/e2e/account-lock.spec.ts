import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   E2E_BASE_URL=... npx playwright test e2e/account-lock.spec.ts --project=chromium
// A (administrator) locks, unlocks and anonymizes B; C anonymizes themselves; A, the last administrator, cannot.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

test.describe.configure({ mode: 'serial' });
let a: Page;
let b: Page;
let c: Page;
let bID = '';

async function virtualAuthenticator(page: Page) {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
}
async function api(page: Page, method: 'post' | 'put' | 'get', url: string, data?: unknown) {
	const res = await page.request[method](url, method === 'get' ? undefined : { data: data ?? {}, headers: { 'Content-Type': 'application/json' } });
	expect(res.ok(), `${method} ${url}: ${await res.text()}`).toBeTruthy();
	return res.status() === 204 ? null : res.json();
}
async function join(browser: import('@playwright/test').Browser, name: string, token: string): Promise<Page> {
	const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
	await virtualAuthenticator(page);
	await page.goto(`/setup?token=${token}`);
	await page.getByLabel('Anzeigename').fill(name);
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
	return page;
}

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	a = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
	await virtualAuthenticator(a);
	await a.goto('/setup');
	await a.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await a.getByLabel('Anzeigename').fill('Anna Admin');
	await a.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(a.getByTestId('account-menu')).toBeVisible();
	b = await join(browser, 'Ben Gesperrt', ((await api(a, 'post', '/v1/invitations')) as { token: string }).token);
	bID = ((await (await b.request.get('/v1/me')).json()) as { id: string }).id;
	c = await join(browser, 'Cleo Selbst', ((await api(a, 'post', '/v1/invitations')) as { token: string }).token);
});
test.afterAll(async () => {
	await a?.context().close();
	await b?.context().close();
	await c?.context().close();
});

test('admin disables B: status chip, B is signed out and sees a clear message on sign-in', async () => {
	await a.goto('/settings/admin-accounts');
	await expect(a.getByTestId(`admin-status-${bID}`)).toHaveText('Aktiv');
	// The own account offers no lock actions.
	await expect(a.locator('[data-testid^="admin-disable-"]')).toHaveCount(2);
	await a.getByTestId(`admin-disable-${bID}`).click();
	const dialog = a.getByTestId('admin-lock-dialog');
	await expect(dialog).toContainText('Ben Gesperrt');
	await expect(dialog).toContainText('Du kannst das Konto jederzeit wieder entsperren');
	await dialog.getByTestId('admin-lock-confirm').click();
	await expect(a.getByTestId('admin-accounts-locked').getByTestId(`admin-status-${bID}`)).toHaveText('Gesperrt');
	await expect(a.getByTestId('admin-accounts').getByTestId(`admin-account-${bID}`)).toHaveCount(0);

	// B's session is invalid immediately.
	expect((await b.request.get('/v1/me')).status()).toBe(401);
	await b.reload();
	await expect(b.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
	// Signing in with the (still stored) passkey is refused with a clear message.
	await b.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
	await expect(b.getByText('Dieses Konto ist gesperrt. Wende dich an einen Administrator.')).toBeVisible();
	await expect(b.getByTestId('account-menu')).toHaveCount(0);
});

test('admin enables B again; B can sign in', async () => {
	await a.getByTestId(`admin-enable-${bID}`).click();
	await a.getByTestId('admin-lock-confirm').click();
	await expect(a.getByTestId('admin-accounts').getByTestId(`admin-status-${bID}`)).toHaveText('Aktiv');
	await b.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
	await expect(b.getByTestId('account-menu')).toBeVisible();
});

test('admin anonymizes B: irreversible, name replaced, no actions left', async () => {
	await a.getByTestId(`admin-anonymize-${bID}`).click();
	const dialog = a.getByTestId('admin-lock-dialog');
	await expect(dialog).toContainText('unwiderruflich');
	await dialog.getByTestId('admin-lock-confirm').click();
	const row = a.getByTestId('admin-accounts-locked').getByTestId(`admin-account-${bID}`);
	await expect(row).toContainText('Anonymisiert');
	await expect(row).toContainText('Ehemaliges Mitglied');
	await expect(a.getByText('Ben Gesperrt')).toHaveCount(0);
	await expect(row.getByRole('button')).toHaveCount(0);
	expect((await b.request.get('/v1/me')).status()).toBe(401);
});

test('the last administrator cannot anonymize their own account', async () => {
	await a.goto('/settings/data');
	await a.getByTestId('data-lock-start').click();
	await a.getByTestId('data-lock-next').click();
	const confirm = a.getByTestId('data-lock-confirm');
	await expect(confirm).toBeDisabled();
	await a.getByTestId('data-lock-phrase').fill('ANONYMISIEREN');
	await confirm.click();
	await expect(a.getByTestId('data-lock-dialog')).toContainText('Du bist der letzte Administrator');
	expect((await a.request.get('/v1/me')).status()).toBe(200);
});

test('C downloads the export, then anonymizes themselves in two steps', async () => {
	await api(c, 'post', '/v1/projects', { name: 'Cleos Projekt' });
	await c.goto('/settings/data');
	const download = c.waitForEvent('download');
	await c.getByTestId('data-export').click();
	const file = await download;
	expect(file.suggestedFilename()).toMatch(/^todolino-export-\d{4}-\d{2}-\d{2}\.json$/);
	await expect(c.getByTestId('data-export-done')).toBeVisible();

	await c.getByTestId('data-lock-start').click();
	const dialog = c.getByTestId('data-lock-dialog');
	await expect(dialog).toContainText('Du wirst abgemeldet');
	await expect(dialog).toContainText('Das lässt sich nicht rückgängig machen');
	await c.getByTestId('data-lock-next').click();
	await expect(c.getByTestId('data-lock-confirm')).toBeDisabled();
	await c.getByTestId('data-lock-phrase').fill('anonymisieren');
	await c.getByTestId('data-lock-confirm').click();
	await expect(c.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
	expect((await c.request.get('/v1/me')).status()).toBe(401);

	// The administrator sees the account as anonymized, without the name.
	await a.goto('/settings/admin-accounts');
	await expect(a.getByTestId('admin-accounts-locked').locator('li[data-status="anonymized"]')).toHaveCount(2);
	await expect(a.getByText('Cleo Selbst')).toHaveCount(0);
});
