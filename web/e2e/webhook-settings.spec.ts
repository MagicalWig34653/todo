import { randomUUID } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Needs a fresh backend database (first account via the bootstrap token) and a backend with SETTINGS_ENCRYPTION_KEY:
//   SETTINGS_ENCRYPTION_KEY=$(openssl rand -base64 32) ... ; npx playwright test e2e/webhook-settings.spec.ts --project=chromium
// Card 06EB19A3 (ADR 0035): settings page "Webhook". Everything runs against the real backend and the real UI.
// The address is a secret: the spec saves https://example.com/<random path> (reserved example domain, no real secret), then
// proves the random path appears nowhere (DOM text, attributes, input values, storage, console, API answers). The server
// resolves the host when saving; without DNS the saving error case is checked instead and reported (never a silent skip).
// Screenshots (docs/screenshots/webhook-einstellungen-*.png and webhook-seite-<state>-*.png) are written by the Chromium run only.
// Card F5D261AF: the page must be easy to find and to finish. Three states, one test each: "no key" (the server flag is faked for
// that view, because the shared test server has a key; the real case is proven by WebhookSettingsTests), "no address", "set up".
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots');
test.describe.configure({ mode: 'serial', timeout: 90_000 });

const json = { headers: { 'Content-Type': 'application/json' } };
const SECRET_PATH = `hook-${randomUUID()}`;
// WEBHOOK_E2E_HOST only exists to exercise the no-DNS branch (an unresolvable host); the other tests expect example.com in the mask.
const HOST = process.env.WEBHOOK_E2E_HOST ?? 'example.com';
const URL_OK = `https://${HOST}/${SECRET_PATH}`;
const SIGNING = `sign-${randomUUID()}`;

let page: Page;
let hasDNS = true;
const consoleLines: string[] = [];
const ids: Record<string, string> = {};

const shoots = () => test.info().project.name === 'chromium';
const urlField = () => page.getByLabel('Webhook-Adresse (https)');
const err = () => page.getByTestId('wh-error');
// One live region that is empty most of the time: the one with text is the message.
const msg = () => page.getByTestId('wh-message').filter({ hasText: /\S/ });

interface ApiWebhook { configured: boolean; maskedURL?: string; enabled: boolean; signingConfigured: boolean; excludedProjectIDs: string[]; consecutiveFailures: number; encryptionKeyAvailable?: boolean }
const apiWebhook = async () => (await (await page.request.get('/v1/settings/webhook')).json()) as ApiWebhook;
async function createProject(name: string, parentID: string | null = null) {
	const r = await page.request.post('/v1/projects', { ...json, data: { name, parentID } });
	expect(r.status(), await r.text()).toBeLessThan(300);
	return ((await r.json()) as { id: string }).id;
}
async function openPage() {
	await page.goto('/settings/webhook');
	await expect(page.getByTestId('webhook-page')).toBeVisible({ timeout: 20_000 });
	await expect(page.getByTestId('wh-status')).toBeVisible({ timeout: 20_000 });
}
/** The secret path is nowhere in what the person can see, copy or inspect, and nowhere the page stores. */
async function expectNoSecret(label: string, secret = SECRET_PATH) {
	const dom = await page.evaluate(() => ({
		html: document.documentElement.outerHTML,
		text: document.body.innerText,
		values: [...document.querySelectorAll('input,textarea')].map((e) => (e as HTMLInputElement).value),
		storage: JSON.stringify({ ...localStorage }) + JSON.stringify({ ...sessionStorage }),
		href: location.href
	}));
	expect(dom.html, `${label}: outerHTML`).not.toContain(secret);
	expect(dom.text, `${label}: visible text`).not.toContain(secret);
	expect(dom.values.join('|'), `${label}: input values`).not.toContain(secret);
	expect(dom.storage, `${label}: storage`).not.toContain(secret);
	expect(dom.href, `${label}: location`).not.toContain(secret);
	expect(await page.content(), `${label}: page.content()`).not.toContain(secret);
	expect(consoleLines.join('\n'), `${label}: console`).not.toContain(secret);
}
async function noOverflow(label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}
/** No element sticks out of a 320 px wide viewport (clipped text on the right edge). */
async function noWide(label: string) {
	const wide = await page.evaluate(() => [...document.querySelectorAll('[data-testid="webhook-page"] *')].filter((e) => e.getBoundingClientRect().right > window.innerWidth + 1).map((e) => e.tagName + '.' + String(e.className).slice(0, 40)));
	expect(wide, `elements wider than the viewport (${label})`).toEqual([]);
}
/** Light, dark and 320 px (and 320 px dark when asked) screenshots of one state; leaves the page light at 1280 px. */
async function shootState(state: string, extra: { dark320?: boolean } = {}) {
	for (const [mode, suffix] of [['light', 'hell'], ['dark', 'dunkel']] as const) {
		await page.setViewportSize({ width: 1280, height: 900 });
		await theme(mode);
		await noOverflow(`${state} desktop ${mode}`);
		await shot(`webhook-seite-${state}-${suffix}`);
	}
	await page.setViewportSize({ width: 320, height: 700 });
	for (const mode of extra.dark320 ? (['light', 'dark'] as const) : (['light'] as const)) {
		await theme(mode);
		await noOverflow(`${state} 320 px ${mode}`);
		await noWide(`${state} 320 px ${mode}`);
		await shot(mode === 'light' ? `webhook-seite-${state}-320` : `webhook-seite-${state}-320-dunkel`);
	}
	await page.setViewportSize({ width: 1280, height: 900 });
	await theme('light');
}
const KEY_ROUTE = '**/v1/settings/webhook';
const KEY_COMMAND = 'deploy/swarm/settings.sh --generate SETTINGS_ENCRYPTION_KEY';
const KONFIGURATION_URL = 'https://github.com/MagicalWig34653/todo/blob/main/docs/KONFIGURATION.md#einstellungsprogramm-settingssh-env-datei-per-menü-oder-kommandozeile';
const backdrop = () =>
	page.evaluate(() => {
		const ctx = document.createElement('canvas').getContext('2d')!;
		for (const el of [document.body, document.documentElement]) {
			const color = getComputedStyle(el).backgroundColor;
			ctx.clearRect(0, 0, 1, 1);
			ctx.fillStyle = '#000';
			ctx.fillStyle = color;
			ctx.fillRect(0, 0, 1, 1);
			const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
			if (a > 250) return { dark: document.documentElement.classList.contains('dark'), luminance: (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255, color };
		}
		return { dark: document.documentElement.classList.contains('dark'), luminance: -1, color: 'transparent' };
	});
/** The page really is in the claimed mode: the PWA's dark class and the painted background agree. */
async function assertMode(mode: 'light' | 'dark') {
	const look = await backdrop();
	expect(look.dark, `html.dark in ${mode} mode (${look.color})`).toBe(mode === 'dark');
	if (mode === 'light') expect(look.luminance, `background ${look.color}`).toBeGreaterThan(0.8);
	else expect(look.luminance, `background ${look.color}`).toBeLessThan(0.2);
}
/** The colour scheme belongs to the account (PUT /v1/me/preferences) and is cached in localStorage `todo.theme`. */
async function theme(mode: 'dark' | 'light') {
	const current = (await (await page.request.get('/v1/me/preferences')).json()) as { appearance: Record<string, unknown> };
	const put = await page.request.put('/v1/me/preferences', { ...json, data: { version: 1, appearance: { ...current.appearance, colorScheme: mode } } });
	expect(put.status(), await put.text()).toBeLessThan(300);
	await page.emulateMedia({ colorScheme: mode });
	await page.evaluate((m) => localStorage.setItem('todo.theme', m), mode);
	await openPage();
	await assertMode(mode);
}
/** One real frame with the whole page: the viewport is made as tall as the content (the app shell has fixed parts). */
async function shot(name: string) {
	if (!shoots()) return;
	mkdirSync(SHOTS, { recursive: true });
	await page.evaluate(() => {
		if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
	});
	const { width, height } = page.viewportSize()!;
	await page.setViewportSize({ width, height: 4000 });
	await page.waitForTimeout(300);
	const bottom = await page.evaluate(() => document.querySelector('[data-testid="webhook-page"]')?.getBoundingClientRect().bottom ?? 0);
	await page.setViewportSize({ width, height: Math.ceil(bottom) + (width < 600 ? 110 : 40) });
	await page.waitForTimeout(400);
	await page.evaluate(() => window.scrollTo(0, 0));
	await page.screenshot({ path: `${SHOTS}/${name}.png` });
	await page.setViewportSize({ width, height });
}

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Webhook Tester');
	page.on('console', (m) => consoleLines.push(m.text()));
	page.on('pageerror', (e) => consoleLines.push(String(e)));
	// The server resolves the host when saving (SSRF check). Without DNS only the error case can be proven; it is reported below.
	hasDNS = await lookup(HOST).then(() => true, () => false);
	ids.alpha = await createProject('Webhook Alpha');
	ids.alphaChild = await createProject('Webhook Alpha Kind', ids.alpha);
	ids.beta = await createProject('Webhook Beta');
	ids.gamma = await createProject('Webhook Gamma');
});
test.afterAll(async () => {
	await page?.context().close();
});

test('landing card and area: nothing is set up yet, the rest waits for an address', async () => {
	await page.goto('/settings');
	const card = page.getByTestId('settings-card-webhook');
	await expect(card).toContainText('Webhook');
	await expect(card).toContainText('Weckruf bei Aktionen von dir');
	await card.click();
	await expect(page).toHaveURL(/\/settings\/webhook$/);
	await expect(page.getByTestId('view-heading')).toHaveText('Webhook');
	await expect(page.getByTestId('wh-status')).toHaveText('Nicht eingerichtet');
	await expect(page.getByTestId('wh-masked')).toHaveCount(0);
	await expect(page.getByTestId('wh-exclusions')).toHaveCount(0);
	// Card F5D261AF: the test area is always there; without an address its button is disabled and says why.
	await expect(page.getByTestId('wh-test')).toBeDisabled();
	await expect(page.getByTestId('wh-test-needs-url')).toBeVisible();
	await expect(page.getByTestId('wh-deliveries-empty')).toBeVisible();
	await expect(page.getByTestId('wh-delivery')).toHaveCount(0);
	await noOverflow('empty page');
	// The settings menu lists the area in the group of the connections.
	await expect(page.getByTestId('settings-group-connected').getByTestId('settings-link-webhook')).toBeVisible();
});

test('state "no key": the server cannot store secrets, so the page says what to do and blocks saving (flag faked for this view)', async () => {
	// The shared test server has a key. The real case (no key on the server -> encryptionKeyAvailable false) is covered by
	// WebhookSettingsTests; here only the answer of GET is replaced, the page and everything else is real.
	expect(await apiWebhook()).toMatchObject({ encryptionKeyAvailable: true });
	await openPage();
	await expect(page.getByTestId('wh-nokey')).toHaveCount(0);
	await page.route(KEY_ROUTE, async (route) => {
		if (route.request().method() !== 'GET') return route.fallback();
		const real = await route.fetch();
		await route.fulfill({ response: real, json: { ...(await real.json()), encryptionKeyAvailable: false } });
	});
	try {
		await openPage();
		// The hint is the first thing on the page (first card), with the concrete step and the way to the documentation.
		const note = page.getByTestId('wh-intro').getByTestId('wh-nokey');
		await expect(note).toBeVisible();
		await expect(note).toContainText(KEY_COMMAND);
		await expect(note).toContainText('todo_settings_key');
		await expect(note).toContainText('SETTINGS_KEY_ENABLED=true');
		await expect(note).toContainText('neu ausrollen');
		const link = note.getByRole('link', { name: /Dokumentation/ });
		await expect(link).toHaveAttribute('href', KONFIGURATION_URL);
		await expect(link).toHaveAttribute('target', '_blank');
		await expect(link).toHaveAttribute('rel', 'noopener noreferrer');
		// Saving is blocked with a reason that assistive technology reads with the button; typing does not change that.
		const save = page.getByTestId('wh-url-save');
		await expect(save).toBeDisabled();
		await expect(save).toHaveAttribute('aria-describedby', 'wh-url-nokey-reason');
		await expect(page.locator('#wh-url-nokey-reason')).toContainText('Verschlüsselungsschlüssel');
		await urlField().fill('https://example.com/not-saved');
		await expect(save).toBeDisabled();
		await urlField().press('Enter');
		await expect(err()).toHaveCount(0);
		expect((await apiWebhook()).configured).toBe(false);
		await urlField().fill('');
		// The test area is there and says that the address comes first.
		await expect(page.getByTestId('wh-test')).toBeDisabled();
		await expect(page.getByTestId('wh-test-needs-url')).toBeVisible();
		await noOverflow('no key');
		await shootState('kein-schluessel');
	} finally {
		await page.unroute(KEY_ROUTE);
	}
	await openPage();
	await expect(page.getByTestId('wh-nokey')).toHaveCount(0);
});

test('state "no address": the test area is visible right below the address, disabled, and says why', async () => {
	await openPage();
	await expect(page.getByTestId('wh-nokey')).toHaveCount(0);
	await expect(page.getByTestId('wh-status')).toHaveText('Nicht eingerichtet');
	await expect(page.getByTestId('wh-last-test')).toHaveText(/Letzter Testaufruf:\s*Noch kein Testaufruf/);
	await expect(page.getByTestId('wh-test-card')).toBeVisible();
	// Directly below the address card, before signature and exclusions.
	expect(await page.getByTestId('wh-url-card').evaluate((el) => el.nextElementSibling?.getAttribute('data-testid'))).toBe('wh-test-card');
	const button = page.getByTestId('wh-test');
	await expect(button).toBeDisabled();
	await expect(button).toHaveAttribute('aria-describedby', 'wh-test-needs-url');
	await expect(page.getByTestId('wh-test-needs-url')).toHaveText('Erst die Adresse speichern.');
	// The test button next to "Adresse speichern" is disabled for the same reason.
	await expect(page.getByTestId('wh-test-inline')).toBeDisabled();
	await expect(page.getByTestId('wh-url-save')).toBeDisabled();
	await noOverflow('no address');
	await shootState('keine-adresse');
});

test('rejects http, private and malformed addresses with clear messages and stores nothing', async () => {
	await openPage();
	const cases: [string, string][] = [
		['http://example.com/hook-x', 'Nur https-Adressen sind erlaubt'],
		['https://127.0.0.1/hook-x', 'private oder lokale Ziele werden nicht aufgerufen'],
		['https://10.0.0.5/hook-x', 'private oder lokale Ziele werden nicht aufgerufen'],
		['https://[::1]/hook-x', 'private oder lokale Ziele werden nicht aufgerufen'],
		['https://user:pw@example.com/hook-x', 'keine gültige Adresse'],
		['ftp://example.com/hook-x', 'Nur https-Adressen sind erlaubt']
	];
	for (const [url, expected] of cases) {
		await urlField().fill(url);
		await page.getByTestId('wh-url-save').click();
		await expect(err(), url).toContainText(expected);
		// The message never repeats what was typed, and the field keeps it (masked) for a correction.
		await expect(err()).not.toContainText('hook-x');
		await expect(err()).not.toContainText('127.0.0.1');
		await expect(err()).not.toContainText('10.0.0.5');
		await expect(page.getByTestId('wh-status')).toHaveText('Nicht eingerichtet');
	}
	expect((await apiWebhook()).configured).toBe(false);
	// Empty input is refused before any request.
	await urlField().fill('   ');
	await expect(page.getByTestId('wh-url-save')).toBeDisabled();
	await noOverflow('error state');
});

test('the address field is masked and not remembered by the browser', async () => {
	await openPage();
	const f = urlField();
	await expect(f).toHaveAttribute('type', 'password');
	// "new-password" plus the opt-outs of the common password managers: the address is a secret and must not be offered or saved.
	await expect(f).toHaveAttribute('autocomplete', 'new-password');
	await expect(f).toHaveAttribute('data-1p-ignore', 'true');
	await expect(f).toHaveAttribute('data-lpignore', 'true');
	await expect(f).toHaveAttribute('data-form-type', 'other');
	await expect(f).toHaveAttribute('spellcheck', 'false');
	await expect(f).toHaveAttribute('autocapitalize', 'off');
	// The hint tells what happens with the address (secret, encrypted, never shown again).
	await expect(page.getByTestId('webhook-page')).toContainText('nie wieder angezeigt');
});

test('without DNS the save fails with a clear message and nothing is stored (reported, never skipped silently)', async () => {
	test.skip(hasDNS, 'DNS works: the saving case runs in the next test');
	test.info().annotations.push({ type: 'no-dns', description: 'example.com does not resolve in this run: only the saving error case is proven' });
	await openPage();
	await urlField().fill(URL_OK);
	await page.getByTestId('wh-url-save').click();
	// An unresolvable name answers like a blocked one (no oracle for internal names).
	await expect(err()).toContainText('nicht auflösen');
	await expect(err()).not.toContainText(SECRET_PATH);
	expect((await apiWebhook()).configured).toBe(false);
	// After a refusal the masked field keeps what was typed (for a correction); everything else must be free of it.
	await urlField().fill('');
	await expectNoSecret('no-dns error');
});

test('saves a public address and never shows it again, only the mask', async () => {
	test.skip(!hasDNS, 'no DNS in this run (reported by the previous test): the server cannot resolve example.com');
	await openPage();
	// Keyboard: Tab reaches the field with a visible focus ring, Enter in the field submits the form.
	for (let i = 0; i < 60; i++) {
		if (await urlField().evaluate((el) => el === document.activeElement)) break;
		await page.keyboard.press('Tab');
	}
	await expect(urlField()).toBeFocused();
	expect(await urlField().evaluate((el) => getComputedStyle(el).boxShadow), 'visible focus').not.toBe('none');
	await page.keyboard.type(URL_OK);
	await page.keyboard.press('Enter');
	await expect(msg()).toContainText('Adresse gespeichert');
	// Right after saving the next step is shown next to its button: send a test call.
	await expect(page.getByTestId('wh-saved-next')).toContainText('Gespeichert. Jetzt Testaufruf senden');
	await expect(page.getByTestId('wh-test-inline')).toBeEnabled();
	await expect(page.getByTestId('wh-status')).toHaveText('Aktiv');
	await expect(page.getByTestId('wh-masked')).toHaveText('https://example.com/…');
	await expect(page.getByTestId('wh-hinterlegt')).toContainText('Hinterlegt');
	await expect(urlField()).toHaveValue('');
	await expect(err()).toHaveCount(0);
	await expectNoSecret('after saving');
	// The API says the same: a mask and flags, never the address.
	const raw = await (await page.request.get('/v1/settings/webhook')).text();
	expect(raw).not.toContain(SECRET_PATH);
	expect(JSON.parse(raw)).toMatchObject({ configured: true, maskedURL: 'https://example.com/…', enabled: true, signingConfigured: false });
	// After a reload nothing has changed, and still no trace of the path.
	await openPage();
	await expect(page.getByTestId('wh-masked')).toHaveText('https://example.com/…');
	await expectNoSecret('after reload');
	// Replacing needs the full new address; a rejected one leaves the stored one in place.
	await urlField().fill('https://192.168.1.10/hook-x');
	await page.getByTestId('wh-url-save').click();
	await expect(err()).toContainText('nicht erlaubt');
	await expect(page.getByTestId('wh-masked')).toHaveText('https://example.com/…');
	expect((await apiWebhook()).configured).toBe(true);
	await urlField().fill('');
});

test('switching off and on', async () => {
	test.skip(!hasDNS, 'no DNS in this run: no address could be saved');
	await openPage();
	const toggle = page.getByLabel('Weckruf einschalten');
	await expect(toggle).toBeChecked();
	await toggle.uncheck();
	await expect(page.getByTestId('wh-status')).toHaveText('Ausgeschaltet');
	expect((await apiWebhook()).enabled).toBe(false);
	await toggle.check();
	await expect(page.getByTestId('wh-status')).toHaveText('Aktiv');
	expect((await apiWebhook()).enabled).toBe(true);
});

test('the notice after an automatic shut-off is shown and switching on again works (server state faked for this one view)', async () => {
	test.skip(!hasDNS, 'no DNS in this run: no address could be saved');
	// Ten failed bundles in a row cannot be produced quickly with a real receiver; the answer of the server is replaced for the
	// first read only (synthetic data, no address), the page is real.
	let faked = false;
	await page.route('**/v1/settings/webhook', async (route) => {
		if (route.request().method() !== 'GET' || faked) return route.fallback();
		faked = true;
		await route.fulfill({ json: { configured: true, maskedURL: 'https://example.com/…', enabled: false, signingConfigured: false, excludedProjectIDs: [], consecutiveFailures: 10 } });
	});
	await openPage();
	await page.unroute('**/v1/settings/webhook');
	await expect(page.getByTestId('wh-status')).toHaveText('Automatisch abgeschaltet');
	await expect(page.getByTestId('wh-auto-disabled')).toContainText('mehrfach nicht erreicht');
	await page.getByTestId('wh-reenable').click();
	await expect(page.getByTestId('wh-status')).toHaveText('Aktiv');
	await expect(page.getByTestId('wh-auto-disabled')).toHaveCount(0);
	expect((await apiWebhook()).enabled).toBe(true);
});

test('exclusions: all projects with hierarchy, sub-project aid, saved and found again after reloading', async () => {
	test.skip(!hasDNS, 'no DNS in this run: no address could be saved');
	await openPage();
	const rows = page.getByTestId('wh-project');
	await expect(rows.filter({ hasText: 'Webhook Alpha Kind' })).toHaveCount(1);
	const box = (name: string) => page.getByTestId('wh-exclusions').getByRole('checkbox', { name, exact: true });
	await expect(box('Webhook Alpha')).not.toBeChecked();
	await expect(page.getByTestId('wh-exclusions-save')).toBeDisabled();
	// Aid on: ticking the parent takes the child with it; ticking Beta alone stays single.
	await page.getByLabel('Unterprojekte mit auswählen').check();
	await box('Webhook Alpha').check();
	await expect(box('Webhook Alpha › Webhook Alpha Kind')).toBeChecked();
	await box('Webhook Beta').check();
	await expect(box('Webhook Gamma')).not.toBeChecked();
	await expect(page.getByTestId('wh-exclusions-count')).toContainText('3 Projekte ausgeschlossen');
	await page.getByTestId('wh-exclusions-save').click();
	await expect(msg()).toContainText('Ausschlüsse gespeichert');
	await expect(page.getByTestId('wh-exclusions-save')).toBeDisabled();
	// Single projects are stored: the child is listed itself.
	expect((await apiWebhook()).excludedProjectIDs.map((i) => i.toLowerCase()).sort()).toEqual([ids.alpha, ids.alphaChild, ids.beta].map((i) => i.toLowerCase()).sort());
	await openPage();
	await expect(box('Webhook Alpha')).toBeChecked();
	await expect(box('Webhook Alpha › Webhook Alpha Kind')).toBeChecked();
	await expect(box('Webhook Beta')).toBeChecked();
	await expect(box('Webhook Gamma')).not.toBeChecked();
	// Aid off: a child can be released alone; the parent stays excluded.
	await box('Webhook Alpha › Webhook Alpha Kind').uncheck();
	await expect(page.getByTestId('wh-exclusions-count')).toContainText('2 Projekte ausgeschlossen');
	await page.getByTestId('wh-exclusions-save').click();
	await expect(msg()).toContainText('Ausschlüsse gespeichert');
	expect((await apiWebhook()).excludedProjectIDs.map((i) => i.toLowerCase()).sort()).toEqual([ids.alpha, ids.beta].map((i) => i.toLowerCase()).sort());
	await noOverflow('exclusions');
});

test('send a test call: the result is shown clearly and the protocol gets an entry', async () => {
	test.skip(!hasDNS, 'no DNS in this run: no address could be saved');
	await openPage();
	await expect(page.getByTestId('wh-deliveries-empty')).toBeVisible();
	const started = Date.now();
	await page.getByTestId('wh-test').click();
	const result = page.getByTestId('wh-test-result');
	// example.com answers 4xx for an unknown path, or the network is closed: both end as sent or failed, which is all that is asserted.
	await expect(result).toContainText(/Testaufruf (zugestellt|fehlgeschlagen)/, { timeout: 30_000 });
	const took = Date.now() - started;
	// The same outcome is on top of the page (own line, with the time).
	await expect(page.getByTestId('wh-last-test')).toHaveText(/Letzter Testaufruf:\s*(Zugestellt|Fehlgeschlagen)/);
	await expect(page.getByTestId('wh-last-test').locator('time')).toHaveCount(1);
	await expect(page.getByTestId('wh-saved-next')).toHaveCount(0);
	const item = page.getByTestId('wh-delivery').first();
	await expect(item).toBeVisible();
	await expect(item).toContainText('Testaufruf');
	await expect(item).toHaveAttribute('data-state', /^(sent|failed)$/);
	await expect(item.getByTestId('wh-delivery-state')).toHaveText(/Zugestellt|Fehlgeschlagen/);
	await expect(item.locator('time')).toHaveCount(1);
	await expect(item.getByTestId('wh-delivery-attempts')).toContainText(/\d+ Versuch/);
	if ((await item.getAttribute('data-state')) === 'failed') await expect(item.getByTestId('wh-delivery-result')).not.toBeEmpty();
	await expectNoSecret('after the test call');
	// A second test right away is refused by the server (one per 10 s): a clear message, not an error page. Only checked when the
	// first call was quick; after a slow one (timeout) the window may have passed.
	if (took < 7_000) {
		await page.getByTestId('wh-test').click();
		await expect(err()).toContainText('10 Sekunden');
		await expect(page.getByTestId('wh-delivery')).toHaveCount(1);
	}
	await page.getByTestId('wh-refresh').click();
	await expect(page.getByTestId('wh-delivery')).toHaveCount(1);
	await noOverflow('protocol');
});

test('state "set up": test next to save, result of the last test on top, test area active (also after reloading)', async () => {
	test.skip(!hasDNS, 'no DNS in this run (reported by an earlier test): no address could be saved, so this state cannot be reached');
	await openPage();
	await expect(page.getByTestId('wh-status')).toHaveText('Aktiv');
	await expect(page.getByTestId('wh-nokey')).toHaveCount(0);
	// The previous test sent a call: the protocol knows it, so the top line shows it after a reload as well.
	const top = page.getByTestId('wh-last-test');
	await expect(top).toHaveText(/Letzter Testaufruf:\s*(Zugestellt|Fehlgeschlagen)/);
	await expect(top.locator('time')).toHaveCount(1);
	await expect(top).not.toContainText('Noch kein Testaufruf');
	// Test button right next to "Adresse ersetzen": same row, active.
	const inline = page.getByTestId('wh-test-inline');
	await expect(inline).toBeEnabled();
	await expect(inline).toHaveText('Test senden');
	const save = await page.getByTestId('wh-url-save').boundingBox();
	const next = await inline.boundingBox();
	expect(Math.abs(save!.y - next!.y), 'test button is in the row of the save button').toBeLessThan(8);
	// The test area is active, directly below the address card and before signature and exclusions.
	await expect(page.getByTestId('wh-test')).toBeEnabled();
	await expect(page.getByTestId('wh-test-needs-url')).toHaveCount(0);
	expect(await page.getByTestId('wh-url-card').evaluate((el) => el.nextElementSibling?.getAttribute('data-testid'))).toBe('wh-test-card');
	const order = await page.evaluate(() => ['wh-test-card', 'wh-signing-card', 'wh-exclusions'].map((id) => document.querySelector(`[data-testid="${id}"]`)!.getBoundingClientRect().top));
	expect(order[0]).toBeLessThan(order[1]);
	expect(order[1]).toBeLessThan(order[2]);
	// The button of the address card works like the one of the test area (one handler): a result, or the 10-second answer.
	await inline.click();
	await expect(page.getByTestId('wh-test-result').filter({ hasText: /Testaufruf/ }).or(err())).toBeVisible({ timeout: 30_000 });
	await expectNoSecret('set up state');
	await noOverflow('set up');
	await shootState('eingerichtet', { dark320: true });
});

test('signing secret: set, shown only as set, replaced, removed; too short is refused', async () => {
	test.skip(!hasDNS, 'no DNS in this run: no address could be saved');
	await openPage();
	await expect(page.getByTestId('wh-signing-state')).toHaveText('Nicht gesetzt');
	const field = page.getByLabel('Signaturgeheimnis', { exact: true });
	await expect(field).toHaveAttribute('type', 'password');
	await expect(field).toHaveAttribute('autocomplete', 'new-password');
	await expect(field).toHaveAttribute('data-form-type', 'other');
	await field.fill('kurz');
	await page.getByTestId('wh-signing-save').click();
	await expect(err()).toContainText('16 bis 256');
	expect((await apiWebhook()).signingConfigured).toBe(false);
	await field.fill(SIGNING);
	await page.getByTestId('wh-signing-save').click();
	await expect(msg()).toContainText('Signaturgeheimnis gespeichert');
	await expect(page.getByTestId('wh-signing-state')).toHaveText('Gesetzt');
	await expect(field).toHaveValue('');
	expect((await apiWebhook()).signingConfigured).toBe(true);
	await expectNoSecret('signing set', SIGNING);
	await openPage();
	await expect(page.getByTestId('wh-signing-state')).toHaveText('Gesetzt');
	await expectNoSecret('signing reload', SIGNING);
	await page.getByTestId('wh-signing-remove').click();
	await expect(msg()).toContainText('Signaturgeheimnis entfernt');
	await expect(page.getByTestId('wh-signing-state')).toHaveText('Nicht gesetzt');
	expect((await apiWebhook()).signingConfigured).toBe(false);
	// Set again: the screenshots show the state "set".
	await field.fill(SIGNING);
	await page.getByTestId('wh-signing-save').click();
	await expect(page.getByTestId('wh-signing-state')).toHaveText('Gesetzt');
});

test('look: light, dark and 320 px wide without overflow (screenshots in docs/screenshots)', async () => {
	test.skip(!hasDNS, 'no DNS in this run: no address could be saved');
	for (const [mode, name] of [['light', 'webhook-einstellungen-hell'], ['dark', 'webhook-einstellungen-dunkel']] as const) {
		await page.setViewportSize({ width: 1280, height: 900 });
		await theme(mode);
		await expect(page.getByTestId('wh-masked')).toHaveText('https://example.com/…');
		await expect(page.getByTestId('wh-delivery')).not.toHaveCount(0);
		await noOverflow(`desktop ${mode}`);
		await expectNoSecret(`desktop ${mode}`);
		await shot(name);
	}
	for (const mode of ['dark', 'light'] as const) {
		await page.setViewportSize({ width: 320, height: 700 });
		await theme(mode);
		await expect(page.getByTestId('wh-masked')).toHaveText('https://example.com/…');
		await noOverflow(`320 px ${mode}`);
		// Every card stays inside the viewport (no clipped text on the right edge).
		const wide = await page.evaluate(() => [...document.querySelectorAll('[data-testid="webhook-page"] *')].filter((e) => e.getBoundingClientRect().right > window.innerWidth + 1).map((e) => e.tagName + '.' + String(e.className).slice(0, 40)));
		expect(wide, `elements wider than 320 px (${mode})`).toEqual([]);
		if (mode === 'light') await shot('webhook-einstellungen-320');
	}
	await page.setViewportSize({ width: 1280, height: 900 });
});

test('removing needs a confirmation and deletes address, exclusions and protocol', async () => {
	test.skip(!hasDNS, 'no DNS in this run: no address could be saved');
	await openPage();
	await page.getByTestId('wh-remove').click();
	const confirm = page.getByRole('alertdialog');
	await expect(confirm).toBeVisible();
	await expect(confirm).toBeFocused();
	// Escape cancels and puts the focus back on the button.
	await page.keyboard.press('Escape');
	await expect(confirm).toHaveCount(0);
	await expect(page.getByTestId('wh-remove')).toBeFocused();
	expect((await apiWebhook()).configured).toBe(true);
	await page.getByTestId('wh-remove').click();
	await page.getByTestId('wh-remove-go').click();
	await expect(msg()).toContainText('Webhook entfernt');
	await expect(page.getByTestId('wh-status')).toHaveText('Nicht eingerichtet');
	await expect(page.getByTestId('wh-masked')).toHaveCount(0);
	await expect(page.getByTestId('wh-exclusions')).toHaveCount(0);
	await expect(page.getByTestId('wh-delivery')).toHaveCount(0);
	await expect(page.getByTestId('wh-deliveries-empty')).toBeVisible();
	// Back to the state without an address: the test area stays, disabled, and no last test is shown.
	await expect(page.getByTestId('wh-test')).toBeDisabled();
	await expect(page.getByTestId('wh-test-needs-url')).toBeVisible();
	await expect(page.getByTestId('wh-last-test')).toHaveText(/Noch kein Testaufruf/);
	const state = await apiWebhook();
	expect(state).toMatchObject({ configured: false, signingConfigured: false, excludedProjectIDs: [] });
	const protocol = (await (await page.request.get('/v1/settings/webhook/deliveries')).json()) as { items: unknown[] };
	expect(protocol.items).toEqual([]);
	await expectNoSecret('after removal');
	await expectNoSecret('after removal (signing)', SIGNING);
});
